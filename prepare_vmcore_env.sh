#!/bin/bash

set -euo pipefail

SEARCH_ROOT="/var/crash"
WORKSPACE_DIR="${HOME}/vmcore_analysis"
VMCORE_OVERRIDE=""
PREPARE_ONLY="off"

log() {
    echo "$1"
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: prepare_vmcore_env.sh [options]

Options:
  --vmcore <path>        Use a specific vmcore file instead of auto-detecting.
  --search-root <path>   Search for the latest vmcore under this directory.
  --workspace <path>     Directory where vmcore/vmlinux/source will be prepared.
  --prepare-only         Prepare files and stop before starting crash.
  -h, --help             Show this help message.

Default behavior:
  1) Search the latest vmcore under /var/crash
  2) Prepare analysis files under ~/vmcore_analysis
  3) Download matching debuginfo RPM and kernel source SRPM
  4) Extract vmlinux and prepare a kernel source tree
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --vmcore)
            shift
            [ -n "${1:-}" ] || fail "--vmcore requires a path."
            VMCORE_OVERRIDE="$1"
            ;;
        --search-root)
            shift
            [ -n "${1:-}" ] || fail "--search-root requires a path."
            SEARCH_ROOT="$1"
            ;;
        --workspace)
            shift
            [ -n "${1:-}" ] || fail "--workspace requires a path."
            WORKSPACE_DIR="$1"
            ;;
        --prepare-only)
            PREPARE_ONLY="on"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
    shift
done

find_latest_vmcore() {
    local root="$1"

    find "$root" -type f -name "vmcore" -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | head -1 \
        | cut -d' ' -f2-
}

fetch_url() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    else
        wget -qO- "$url"
    fi
}

url_exists() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsI "$url" >/dev/null 2>&1
    else
        wget --spider -q "$url" >/dev/null 2>&1
    fi
}

download_file() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" -o "$output"
    else
        wget -O "$output" "$url"
    fi
}

detect_kernel_flavor() {
    local os_release="$1"

    if [[ "$os_release" == *uek* ]]; then
        echo "uek"
    else
        echo "rhck"
    fi
}

find_debuginfo_rpms() {
    local os_release="$1"
    local kernel_flavor="$2"
    local arch
    local base_release
    local candidates=()

    arch="${os_release##*.}"

    if [ "$kernel_flavor" = "uek" ]; then
        candidates+=("kernel-uek-debuginfo-${os_release}.rpm")
    else
        candidates+=("kernel-debuginfo-${os_release}.rpm")
        candidates+=("kernel-debuginfo-common-${arch}-${os_release}.rpm")

        base_release=$(echo "$os_release" | sed -E 's/\.el[0-9][^ ]*$//')
        candidates+=("kernel-debuginfo-${base_release}.rpm")
        candidates+=("kernel-debuginfo-common-${arch}-${base_release}.rpm")
        candidates+=("kernel-debuginfo-${base_release}"*.rpm)
        candidates+=("kernel-debuginfo-common-${arch}-${base_release}"*.rpm)
    fi

    printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
}

find_source_srpm_candidates() {
    local os_release="$1"
    local kernel_flavor="$2"
    local source_release
    local base_release
    local candidates=()

    source_release="${os_release%.*}"
    base_release=$(echo "$source_release" | sed -E 's/\.el[0-9][^ ]*$//')

    if [ "$kernel_flavor" = "uek" ]; then
        candidates+=("kernel-uek-${source_release}.src.rpm")
        candidates+=("kernel-uek-${base_release}.src.rpm")
        candidates+=("kernel-uek-${base_release}"*.src.rpm)
    else
        candidates+=("kernel-${source_release}.src.rpm")
        candidates+=("kernel-${base_release}.src.rpm")
        candidates+=("kernel-${base_release}"*.src.rpm)
    fi

    printf '%s\n' "${candidates[@]}" | awk '!seen[$0]++'
}

resolve_existing_rpms() {
    local base_url="$1"
    shift
    local candidate
    local html=""
    local resolved=()

    for candidate in "$@"; do
        if [[ "$candidate" == *"*"* ]]; then
            local regex
            local matched

            [ -n "$html" ] || html=$(fetch_url "$base_url")
            regex=$(printf '%s' "$candidate" | sed -e 's/[][(){}.^$+?|\\]/\\&/g' -e 's/\*/.*/g')
            matched=$(echo "$html" \
                | grep -oE 'href="[^"]+\.(rpm|src\.rpm)"' \
                | sed -E 's/^href="|"$//; s#.*/##' \
                | grep -E "^${regex}$" \
                | sort -uV \
                | tail -1 || true)
            if [ -n "$matched" ]; then
                resolved+=("$matched")
            fi
        elif url_exists "${base_url}${candidate}"; then
            resolved+=("$candidate")
        fi
    done

    printf '%s\n' "${resolved[@]}" | awk '!seen[$0]++'
}

prepare_source_tree() {
    local srpm_file="$1"
    local source_topdir="$2"
    local build_output_dir="$3"
    local spec_file
    local built_dir
    local prep_log
    local shim_path=""
    local shim_created="off"

    rm -rf "$source_topdir"
    mkdir -p "$source_topdir"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS,tmp_extract}

    (
        cd "$source_topdir/tmp_extract"
        rpm2cpio "$srpm_file" | cpio -idm >/dev/null 2>&1
    ) || fail "Failed to extract source SRPM: $srpm_file"

    spec_file=$(find "$source_topdir/tmp_extract" -maxdepth 1 -type f -name '*.spec' | head -1)
    [ -n "$spec_file" ] || fail "No spec file found in source SRPM: $srpm_file"

    find "$source_topdir/tmp_extract" -maxdepth 1 -type f ! -name '*.spec' -exec mv -f {} "$source_topdir/SOURCES/" \;
    mv -f "$spec_file" "$source_topdir/SPECS/"

    prep_log="${source_topdir}/prep.log"

    if ! rpmbuild --define "_topdir $source_topdir" -bp "$source_topdir/SPECS/$(basename "$spec_file")" --nodeps >"$prep_log" 2>&1; then
        shim_path=$(sed -nE 's#.*(\/opt\/rh\/[^[:space:]]+\/enable).*#\1#p' "$prep_log" | head -1)

        if [ -n "$shim_path" ] && [ ! -f "$shim_path" ]; then
            mkdir -p "$(dirname "$shim_path")"
            cat > "$shim_path" <<'EOF'
#!/bin/bash
# Temporary compatibility shim for %prep source-only extraction.
return 0 2>/dev/null || exit 0
EOF
            chmod 0755 "$shim_path"
            shim_created="on"
        fi

        if ! rpmbuild --define "_topdir $source_topdir" -bp "$source_topdir/SPECS/$(basename "$spec_file")" --nodeps >>"$prep_log" 2>&1; then
            [ "$shim_created" = "on" ] && rm -f "$shim_path"
            fail "rpmbuild -bp failed for source SRPM: $srpm_file (see $prep_log)"
        fi
    fi

    built_dir=$(find "$source_topdir/BUILD" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
    [ -n "$built_dir" ] || fail "No prepared source tree found under: $source_topdir/BUILD"

    mkdir -p "$(dirname "$build_output_dir")"
    rm -rf "$build_output_dir"
    cp -a "$built_dir" "$build_output_dir"

    if [ "$shim_created" = "on" ]; then
        rm -f "$shim_path"
    fi
}

find_vmlinux_relpath_in_rpm() {
    local rpm_file="$1"

    rpm2cpio "$rpm_file" | cpio -it 2>/dev/null \
        | grep -E '^(\./)?usr/lib/debug/lib/modules/.+/vmlinux$' \
        | sed 's#^\./##' \
        | head -1
}

extract_vmlinux_from_rpm() {
    local rpm_file="$1"
    local dest_dir="$2"

    (
        cd "$dest_dir"
        rpm2cpio "$rpm_file" | cpio -idm '*/vmlinux' >/dev/null 2>&1 || true
    )
}

write_analysis_env() {
    local env_file="$1"

    cat > "$env_file" <<EOF
OS_RELEASE="${OS_RELEASE}"
KERNEL_FLAVOR="${KERNEL_FLAVOR}"
VMCORE_PATH="${TARGET_VMCORE}"
VMLINUX_PATH="${VMLINUX_ABS}"
DEBUGINFO_DIR="${DEBUGINFO_EXTRACT_DIR}"
SOURCE_RPM_PATH="${SOURCE_RPM_ABS}"
KERNEL_SOURCE_DIR="${KERNEL_SOURCE_DIR}"
EOF
}

log "[0/8] Checking environment..."

for cmd in strings rpm2cpio cpio crash find sort grep sed awk cp mv rpmbuild; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    fail "Required command not found: curl or wget"
fi

mkdir -p "$WORKSPACE_DIR"
[ -w "$WORKSPACE_DIR" ] || fail "No write permission in workspace: $WORKSPACE_DIR"

TARGET_VMCORE="${WORKSPACE_DIR}/vmcore"
SELECTED_VMCORE=""
VMLINUX_ABS=""
SOURCE_RPM_ABS=""
DOWNLOAD_DIR=""
DEBUGINFO_EXTRACT_DIR=""
SOURCE_TOPDIR=""
KERNEL_SOURCE_DIR=""
ANALYSIS_ENV_FILE="${WORKSPACE_DIR}/analysis.env"

log "[1/8] Preparing vmcore in workspace..."

if [ -n "$VMCORE_OVERRIDE" ]; then
    [ -f "$VMCORE_OVERRIDE" ] || fail "Specified vmcore does not exist: $VMCORE_OVERRIDE"
    SELECTED_VMCORE="$VMCORE_OVERRIDE"
    log "Using manually specified vmcore: $SELECTED_VMCORE"
    cp -f "$SELECTED_VMCORE" "$TARGET_VMCORE"
else
    [ -d "$SEARCH_ROOT" ] || fail "Search root does not exist: $SEARCH_ROOT"

    SELECTED_VMCORE=$(find_latest_vmcore "$SEARCH_ROOT")
    [ -n "$SELECTED_VMCORE" ] || fail "No vmcore found under: $SEARCH_ROOT"

    log "Detected latest vmcore: $SELECTED_VMCORE"
    cp -f "$SELECTED_VMCORE" "$TARGET_VMCORE"
fi

[ -s "$TARGET_VMCORE" ] || fail "Prepared vmcore is empty or missing: $TARGET_VMCORE"

cd "$WORKSPACE_DIR"

log "[2/8] Extracting OSRELEASE from vmcore..."
OS_RELEASE=$(strings vmcore | grep -m 1 -E "OSRELEASE=[0-9]" | cut -d'=' -f2 || true)
[ -n "$OS_RELEASE" ] || fail "Could not extract OSRELEASE from vmcore."

echo "Detected OSRELEASE: $OS_RELEASE"
KERNEL_FLAVOR=$(detect_kernel_flavor "$OS_RELEASE")
echo "Detected kernel flavor: $KERNEL_FLAVOR"

case "$OS_RELEASE" in
    *.el5*) OL_PATH="ol5" ;;
    *.el6*) OL_PATH="ol6" ;;
    *.el7*) OL_PATH="ol7" ;;
    *.el8*) OL_PATH="ol8" ;;
    *.el9*) OL_PATH="ol9" ;;
    *.el10*) OL_PATH="ol10" ;;
    *) fail "Unsupported OSRELEASE: $OS_RELEASE" ;;
esac

BASE_URL="https://oss.oracle.com"
DEBUGINFO_URL="${BASE_URL}/${OL_PATH}/debuginfo/"
SRPM_URL="${BASE_URL}/${OL_PATH}/SRPMS-updates/"
DOWNLOAD_DIR="${WORKSPACE_DIR}/downloads/${OS_RELEASE}"
DEBUGINFO_EXTRACT_DIR="${WORKSPACE_DIR}/debug/${OS_RELEASE}"
SOURCE_TOPDIR="${WORKSPACE_DIR}/source_rpmbuild/${OS_RELEASE}"
KERNEL_SOURCE_DIR="${WORKSPACE_DIR}/kernel-source/${OS_RELEASE}"

mkdir -p "$DOWNLOAD_DIR"

log "[3/8] Finding matching debuginfo RPM..."
mapfile -t DEBUGINFO_CANDIDATES < <(find_debuginfo_rpms "$OS_RELEASE" "$KERNEL_FLAVOR")
mapfile -t DEBUGINFO_RPMS < <(resolve_existing_rpms "$DEBUGINFO_URL" "${DEBUGINFO_CANDIDATES[@]}")

[ "${#DEBUGINFO_RPMS[@]}" -gt 0 ] || fail "No matching ${KERNEL_FLAVOR} debuginfo RPM found for ${OS_RELEASE} at ${DEBUGINFO_URL}"

for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
    echo "Matched debuginfo RPM: ${rpm_name}"
done

log "[4/8] Downloading debuginfo RPM..."
for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
    if [ ! -f "${DOWNLOAD_DIR}/${rpm_name}" ]; then
        download_file "${DEBUGINFO_URL}${rpm_name}" "${DOWNLOAD_DIR}/${rpm_name}" || fail "RPM download failed: ${rpm_name}"
    else
        log "Reusing downloaded RPM: ${DOWNLOAD_DIR}/${rpm_name}"
    fi
done

log "[5/8] Extracting vmlinux..."
VMLINUX_REL=""

for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
    if [ -z "$VMLINUX_REL" ]; then
        VMLINUX_REL=$(find_vmlinux_relpath_in_rpm "${DOWNLOAD_DIR}/${rpm_name}" || true)
    fi
done

if [ -n "$VMLINUX_REL" ] && [ -f "${DEBUGINFO_EXTRACT_DIR}/${VMLINUX_REL}" ]; then
    log "Reusing extracted vmlinux: ${DEBUGINFO_EXTRACT_DIR}/${VMLINUX_REL}"
    VMLINUX_ABS="${DEBUGINFO_EXTRACT_DIR}/${VMLINUX_REL}"
else
    rm -rf "$DEBUGINFO_EXTRACT_DIR"
    mkdir -p "$DEBUGINFO_EXTRACT_DIR"

    for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
        (
            cd "$DEBUGINFO_EXTRACT_DIR"
            if [ -n "$VMLINUX_REL" ]; then
                rpm2cpio "${DOWNLOAD_DIR}/${rpm_name}" | cpio -idm "./${VMLINUX_REL}" "${VMLINUX_REL}" >/dev/null 2>&1 || true
            fi
        )
        extract_vmlinux_from_rpm "${DOWNLOAD_DIR}/${rpm_name}" "$DEBUGINFO_EXTRACT_DIR"
    done

    if [ -n "$VMLINUX_REL" ] && [ -f "${DEBUGINFO_EXTRACT_DIR}/${VMLINUX_REL}" ]; then
        VMLINUX_ABS="${DEBUGINFO_EXTRACT_DIR}/${VMLINUX_REL}"
    else
        VMLINUX_ABS=$(find "$DEBUGINFO_EXTRACT_DIR" -type f -path '*/usr/lib/debug/lib/modules/*/vmlinux' | head -1)
    fi
fi

[ -n "$VMLINUX_ABS" ] && [ -f "$VMLINUX_ABS" ] || fail "vmlinux extraction failed under: $DEBUGINFO_EXTRACT_DIR"

echo "vmlinux: $VMLINUX_ABS"
echo "vmcore : $TARGET_VMCORE"

log "[6/8] Finding matching source SRPM..."
mapfile -t SOURCE_CANDIDATES < <(find_source_srpm_candidates "$OS_RELEASE" "$KERNEL_FLAVOR")
mapfile -t SOURCE_SRPMS < <(resolve_existing_rpms "$SRPM_URL" "${SOURCE_CANDIDATES[@]}")

[ "${#SOURCE_SRPMS[@]}" -gt 0 ] || fail "No matching ${KERNEL_FLAVOR} source SRPM found for ${OS_RELEASE} at ${SRPM_URL}"

SOURCE_SRPM_FILE="${SOURCE_SRPMS[0]}"
echo "Matched source SRPM: ${SOURCE_SRPM_FILE}"

if [ ! -f "$SOURCE_SRPM_FILE" ]; then
    download_file "${SRPM_URL}${SOURCE_SRPM_FILE}" "${DOWNLOAD_DIR}/${SOURCE_SRPM_FILE}" || fail "Source SRPM download failed: ${SOURCE_SRPM_FILE}"
else
    log "Reusing downloaded source SRPM: ${DOWNLOAD_DIR}/${SOURCE_SRPM_FILE}"
fi

SOURCE_RPM_ABS="${DOWNLOAD_DIR}/${SOURCE_SRPM_FILE}"

log "[7/8] Preparing kernel source tree from SRPM..."
if [ -d "$KERNEL_SOURCE_DIR" ] && [ -n "$(find "$KERNEL_SOURCE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]; then
    log "Reusing prepared kernel source tree: $KERNEL_SOURCE_DIR"
else
    prepare_source_tree "$SOURCE_RPM_ABS" "$SOURCE_TOPDIR" "$KERNEL_SOURCE_DIR"
fi
[ -d "$KERNEL_SOURCE_DIR" ] || fail "Kernel source tree was not prepared: $KERNEL_SOURCE_DIR"

log "[8/8] Writing analysis metadata..."
write_analysis_env "$ANALYSIS_ENV_FILE"

echo "source : $KERNEL_SOURCE_DIR"
echo "env    : $ANALYSIS_ENV_FILE"

if [ "$PREPARE_ONLY" = "on" ]; then
    log ""
    log "Preparation complete."
    log "Run crash manually with:"
    log "  crash \"$VMLINUX_ABS\" \"$TARGET_VMCORE\""
    exit 0
fi

log ""
log "Starting crash..."
exec crash "$VMLINUX_ABS" "$TARGET_VMCORE"
