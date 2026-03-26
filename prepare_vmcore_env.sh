#!/bin/bash

set -euo pipefail

# Usage:
#   ./prepare_vmcore_env.sh
#   ./prepare_vmcore_env.sh --vmcore /path/to/vmcore
#   ./prepare_vmcore_env.sh --search-root /var/crash
#   ./prepare_vmcore_env.sh --workspace /home/user/vmcore_analysis

SEARCH_ROOT="/var/crash"
WORKSPACE_DIR="${HOME}/vmcore_analysis"
VMCORE_OVERRIDE=""

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
  --workspace <path>     Directory where vmcore/vmlinux will be prepared.
  -h, --help             Show this help message.

Default behavior:
  1) Search the latest vmcore under /var/crash
  2) Prepare analysis files under ~/vmcore_analysis
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
    local os_release="$2"
    local kernel_flavor="$3"
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

resolve_existing_debuginfo_rpms() {
    local debuginfo_url="$1"
    shift
    local candidate
    local resolved=()

    for candidate in "$@"; do
        if [[ "$candidate" == *"*"* ]]; then
            local html
            local matched

            html=$(fetch_url "$debuginfo_url")
            matched=$(echo "$html" | grep -oE 'kernel(-uek)?-debuginfo[^"'"'"' >]*\.rpm|kernel-debuginfo-common[^"'"'"' >]*\.rpm' | grep -E "^${candidate//./\\.}$" | sort -uV | tail -1 || true)
            if [ -n "$matched" ]; then
                resolved+=("$matched")
            fi
        elif url_exists "${debuginfo_url}${candidate}"; then
            resolved+=("$candidate")
        fi
    done

    printf '%s\n' "${resolved[@]}" | awk '!seen[$0]++'
}

log "[0/6] Checking environment..."

for cmd in strings rpm2cpio cpio crash find sort grep; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    fail "Required command not found: curl or wget"
fi

mkdir -p "$WORKSPACE_DIR"
[ -w "$WORKSPACE_DIR" ] || fail "No write permission in workspace: $WORKSPACE_DIR"

TARGET_VMCORE="${WORKSPACE_DIR}/vmcore"
SELECTED_VMCORE=""

log "[1/6] Preparing vmcore in workspace..."

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

log "[2/6] Extracting OSRELEASE from vmcore..."
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

log "[3/6] Finding matching debuginfo RPM..."
BASE_URL="https://oss.oracle.com"
DEBUGINFO_URL="${BASE_URL}/${OL_PATH}/debuginfo/"
mapfile -t DEBUGINFO_CANDIDATES < <(find_debuginfo_rpms "$DEBUGINFO_URL" "$OS_RELEASE" "$KERNEL_FLAVOR")
mapfile -t DEBUGINFO_RPMS < <(resolve_existing_debuginfo_rpms "$DEBUGINFO_URL" "${DEBUGINFO_CANDIDATES[@]}")

[ "${#DEBUGINFO_RPMS[@]}" -gt 0 ] || fail "No matching ${KERNEL_FLAVOR} debuginfo RPM found for ${OS_RELEASE} at ${DEBUGINFO_URL}"

for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
    echo "Matched debuginfo RPM: ${rpm_name}"
done

log "[4/6] Downloading debuginfo RPM..."
for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
    if [ ! -f "$rpm_name" ]; then
        download_file "${DEBUGINFO_URL}${rpm_name}" "$rpm_name" || fail "RPM download failed: ${rpm_name}"
    fi
done

log "[5/6] Extracting vmlinux..."
VMLINUX_PATH="./usr/lib/debug/lib/modules/${OS_RELEASE}/vmlinux"

for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
    rpm2cpio "$rpm_name" | cpio -idm "$VMLINUX_PATH" >/dev/null 2>&1 || true
done

[ -f "$VMLINUX_PATH" ] || fail "vmlinux extraction failed or path is incorrect: $VMLINUX_PATH"

echo "vmlinux: $VMLINUX_PATH"
echo "vmcore : $(pwd)/vmcore"

log "[6/6] Starting crash..."
exec crash "$VMLINUX_PATH" vmcore
