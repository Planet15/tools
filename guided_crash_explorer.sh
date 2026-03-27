#!/bin/bash

set -euo pipefail

SEARCH_ROOT="/var/crash"
WORKSPACE_DIR="${HOME}/vmcore_analysis"
VMCORE_OVERRIDE=""
VMLINUX_OVERRIDE=""
SOURCE_DIR_OVERRIDE=""
PREPARE_ONLY="off"
FRAME_LIMIT=12

log() {
    echo "$1"
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat <<'EOF'
Usage: guided_crash_explorer.sh [options]

Options:
  --vmcore <path>        Use a specific vmcore file instead of auto-detecting.
  --vmlinux <path>       Use an already prepared vmlinux file.
  --source-dir <path>    Use an already prepared kernel source tree.
  --search-root <path>   Search for the latest vmcore under this directory.
  --workspace <path>     Directory where vmcore/vmlinux/source/report will be prepared.
  --frame-limit <num>    Limit the number of frames included in code_trace.md.
  --prepare-only         Prepare vmcore/vmlinux/source and stop before generating code trace.
  -h, --help             Show this help message.

Default behavior:
  1) Search the latest vmcore under /var/crash
  2) Prepare analysis files under ~/vmcore_analysis
  3) Download matching debuginfo RPM and kernel source SRPM when needed
  4) Run bt -f through crash and generate code_trace.md
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --vmcore)
            shift
            [ -n "${1:-}" ] || fail "--vmcore requires a path."
            VMCORE_OVERRIDE="$1"
            ;;
        --vmlinux)
            shift
            [ -n "${1:-}" ] || fail "--vmlinux requires a path."
            VMLINUX_OVERRIDE="$1"
            ;;
        --source-dir)
            shift
            [ -n "${1:-}" ] || fail "--source-dir requires a path."
            SOURCE_DIR_OVERRIDE="$1"
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
        --frame-limit)
            shift
            [ -n "${1:-}" ] || fail "--frame-limit requires a number."
            FRAME_LIMIT="$1"
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
            if [ "$shim_created" = "on" ]; then
                rm -f "$shim_path"
            fi
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
SOURCE_RPM_PATH="${SOURCE_RPM_ABS:-}"
KERNEL_SOURCE_DIR="${KERNEL_SOURCE_DIR}"
EOF
}

syscall_name_from_nr() {
    local nr="$1"

    case "$nr" in
        0) echo "read" ;;
        1) echo "write" ;;
        2) echo "open" ;;
        3) echo "close" ;;
        9) echo "mmap" ;;
        16) echo "ioctl" ;;
        19) echo "readv" ;;
        20) echo "writev" ;;
        39) echo "getpid" ;;
        59) echo "execve" ;;
        60) echo "exit" ;;
        61) echo "wait4" ;;
        62) echo "kill" ;;
        72) echo "fcntl" ;;
        202) echo "futex" ;;
        217) echo "getdents64" ;;
        257) echo "openat" ;;
        262) echo "newfstatat" ;;
        263) echo "unlinkat" ;;
        267) echo "readlinkat" ;;
        268) echo "fchmodat" ;;
        269) echo "faccessat" ;;
        291) echo "epoll_create1" ;;
        292) echo "dup3" ;;
        293) echo "pipe2" ;;
        294) echo "inotify_init1" ;;
        302) echo "prlimit64" ;;
        313) echo "finit_module" ;;
        *) echo "" ;;
    esac
}

append_register_analysis() {
    local bt_file="$1"
    local out_file="$2"
    local orig_rax
    local syscall_name
    local rax rdi rsi rdx r10 r8 r9 rip rsp

    orig_rax=$(sed -nE 's/^[[:space:]]*ORIG_RAX:[[:space:]]*([0-9a-fx]+).*/\1/p' "$bt_file" | head -1)
    rip=$(sed -nE 's/^[[:space:]]*RIP:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    rsp=$(sed -nE 's/^[[:space:]]*RIP:.*RSP:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    rax=$(sed -nE 's/^[[:space:]]*RAX:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    rdi=$(sed -nE 's/^[[:space:]]*RAX:.*RDI:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    rsi=$(sed -nE 's/^[[:space:]]*RDX:.*RSI:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    rdx=$(sed -nE 's/^[[:space:]]*RDX:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    r10=$(sed -nE 's/^[[:space:]]*R10:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    r8=$(sed -nE 's/^[[:space:]]*RBP:.*R8:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)
    r9=$(sed -nE 's/^[[:space:]]*R8:.*R9:[[:space:]]*([^[:space:]]+).*/\1/p' "$bt_file" | head -1)

    syscall_name=""
    if [[ "$orig_rax" =~ ^[0-9]+$ ]]; then
        syscall_name=$(syscall_name_from_nr "$orig_rax")
    elif [[ "$orig_rax" =~ ^0x[0-9a-fA-F]+$ ]]; then
        syscall_name=$(syscall_name_from_nr "$((orig_rax))")
    fi

    {
        echo "## Register Context"
        echo ""
        [ -n "$rip" ] && echo "- user RIP: ${rip}"
        [ -n "$rsp" ] && echo "- user RSP: ${rsp}"
        [ -n "$rax" ] && echo "- current RAX: ${rax}"
        if [ -n "$orig_rax" ]; then
            if [ -n "$syscall_name" ]; then
                echo "- ORIG_RAX: ${orig_rax} (${syscall_name} syscall)"
            else
                echo "- ORIG_RAX: ${orig_rax}"
            fi
        fi
        echo ""
        echo "### Register Interpretation"
        echo ""
        [ -n "$rdi" ] && echo "- RDI: first syscall argument = ${rdi}"
        [ -n "$rsi" ] && echo "- RSI: second syscall argument = ${rsi}"
        [ -n "$rdx" ] && echo "- RDX: third syscall argument = ${rdx}"
        [ -n "$r10" ] && echo "- R10: fourth syscall argument = ${r10}"
        [ -n "$r8" ] && echo "- R8: fifth syscall argument = ${r8}"
        [ -n "$r9" ] && echo "- R9: sixth syscall argument = ${r9}"
        echo ""
        echo "### Recommended Follow-up"
        echo ""
        if [ -n "$orig_rax" ] && [ -n "$syscall_name" ]; then
            echo "- Treat this frame as a ${syscall_name} syscall entry context first, then confirm the kernel-side call path."
        fi
        [ -n "$rsi" ] && echo "- Inspect the user buffer candidate with: \`rd -a ${rsi}\` and \`rd -8 ${rsi} 16\`"
        [ -n "$rsp" ] && echo "- Inspect the user stack vicinity with: \`rd -8 ${rsp} 32\`"
        [ -n "$rip" ] && echo "- Keep the user-space instruction pointer in mind when correlating this with process mappings: \`${rip}\`"
        echo "- Prefer ORIG_RAX over current RAX when inferring the original syscall number."
        echo ""
    } >> "$out_file"
}

extract_function_source() {
    local func_name="$1"
    local instr_addr="$2"
    local out_file="$3"
    local gdb_output
    local source_file
    local source_line
    local local_source
    local start_line
    local end_line
    local source_label

    if [ -n "$instr_addr" ]; then
        gdb_output=$(gdb -batch "$VMLINUX_ABS" -ex "directory $KERNEL_SOURCE_DIR" -ex "info line *${instr_addr}" 2>/dev/null || true)
    else
        gdb_output=""
    fi

    if [ -z "$gdb_output" ]; then
        gdb_output=$(gdb -batch "$VMLINUX_ABS" -ex "directory $KERNEL_SOURCE_DIR" -ex "info line ${func_name}" 2>/dev/null || true)
    fi

    if [ -z "$gdb_output" ]; then
        return 0
    fi

    source_file=$(printf '%s\n' "$gdb_output" | sed -nE 's/^Line [0-9]+ of "([^"]+)".*/\1/p' | head -1)
    source_line=$(printf '%s\n' "$gdb_output" | sed -nE 's/^Line ([0-9]+) of "([^"]+)".*/\1/p' | head -1)

    if [ -z "$source_file" ] || [ -z "$source_line" ]; then
        return 0
    fi

    if [ -f "$source_file" ]; then
        local_source="$source_file"
    elif [ -f "${KERNEL_SOURCE_DIR}/${source_file}" ]; then
        local_source="${KERNEL_SOURCE_DIR}/${source_file}"
    else
        local_source=$(find "$KERNEL_SOURCE_DIR" -type f -path "*${source_file}" 2>/dev/null | head -1)
    fi

    if [ -z "$local_source" ] || [ ! -f "$local_source" ]; then
        return 0
    fi

    start_line=$((source_line - 5))
    end_line=$((source_line + 5))
    [ "$start_line" -lt 1 ] && start_line=1

    if [ -n "$instr_addr" ]; then
        source_label="${source_file}:${source_line} (resolved from ${instr_addr})"
    else
        source_label="${source_file}:${source_line}"
    fi

    {
        echo "Source: ${source_label}"
        echo ""
        echo '```c'
        nl -ba "$local_source" | sed -n "${start_line},${end_line}p"
        echo '```'
    } >> "$out_file"
}

generate_bt_trace() {
    local cmd_file="${WORKSPACE_DIR}/bt_trace.cmd"
    local out_file="${WORKSPACE_DIR}/bt_full.txt"

    cat > "$cmd_file" <<'EOF'
set scroll off
bt -f
quit
EOF

    crash -i "$cmd_file" "$VMLINUX_ABS" "$TARGET_VMCORE" > "$out_file" 2>&1 \
        || fail "Failed to generate bt -f output with crash"
}

generate_code_trace() {
    local bt_file="${WORKSPACE_DIR}/bt_full.txt"
    local trace_file="${WORKSPACE_DIR}/code_trace.md"
    local trigger_header
    local trigger_pid
    local trigger_cmd
    local frame_count=0
    local line
    local frame_no
    local func_name
    local frame_addr
    local instr_addr
    local module_name
    local trailing_bracket
    local exception_site

    trigger_header=$(grep -m 1 '^PID:' "$bt_file" || true)
    trigger_pid=$(printf '%s\n' "$trigger_header" | sed -nE 's/^PID:[[:space:]]*([0-9]+).*/\1/p')
    trigger_cmd=$(printf '%s\n' "$trigger_header" | sed -nE 's/^PID:.*COMMAND:[[:space:]]*"([^"]+)".*/\1/p')
    exception_site=$(sed -nE 's/^[[:space:]]*\[exception RIP:[[:space:]]*([^]]+)\].*/\1/p' "$bt_file" | head -1)

    {
        echo "# Code Trace"
        echo ""
        echo "- vmcore: ${TARGET_VMCORE}"
        echo "- vmlinux: ${VMLINUX_ABS}"
        echo "- source: ${KERNEL_SOURCE_DIR}"
        [ -n "$trigger_pid" ] && echo "- trigger pid: ${trigger_pid}"
        [ -n "$trigger_cmd" ] && echo "- trigger command: ${trigger_cmd}"
        [ -n "$exception_site" ] && echo "- exception RIP: ${exception_site}"
        echo ""
        echo "## Raw Trace Source"
        echo ""
        echo "- bt -f output: bt_full.txt"
        echo ""
    } > "$trace_file"

    append_register_analysis "$bt_file" "$trace_file"

    while IFS= read -r line; do
        case "$line" in
            [[:space:]]\#*|\#*)
                frame_no=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*#([0-9]+).*/\1/p')
                func_name=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*#[0-9]+ \[[^]]+\] ([^[:space:]]+).*/\1/p')
                frame_addr=$(printf '%s\n' "$line" | sed -nE 's/^[[:space:]]*#[0-9]+ \[([^]]+)\].*/\1/p')
                instr_addr=$(printf '%s\n' "$line" | sed -nE 's/.* at ([[:xdigit:]]{8,}|0x[[:xdigit:]]+).*/\1/p')
                trailing_bracket=$(printf '%s\n' "$line" | grep -oE '\[[^]]+\]$' | tr -d '[]' || true)
                module_name=""
                if [ -n "$trailing_bracket" ] && [ "$trailing_bracket" != "$frame_addr" ]; then
                    module_name="$trailing_bracket"
                fi

                [ -n "$func_name" ] || continue

                frame_count=$((frame_count + 1))
                [ "$frame_count" -gt "$FRAME_LIMIT" ] && break

                {
                    echo "## Frame ${frame_no}: ${func_name}"
                    echo ""
                    [ -n "$frame_addr" ] && echo "- stack frame: ${frame_addr}"
                    [ -n "$instr_addr" ] && echo "- instruction address: ${instr_addr}"
                    if [ -n "$module_name" ] && [ "$module_name" != "$func_name" ]; then
                        echo "- module: ${module_name}"
                    fi
                    echo "- recommended crash commands:"
                    echo "  - \`dis ${func_name}\`"
                    [ -n "$instr_addr" ] && echo "  - \`dis -l ${instr_addr}\`"
                    if [ -n "$trigger_pid" ]; then
                        echo "  - \`bt -f ${trigger_pid}\`"
                    fi
                    if [ -n "$module_name" ] && [ "$module_name" != "$func_name" ]; then
                        echo "  - \`mod ${module_name}\`"
                        echo "  - \`sym ${module_name}\`"
                    fi
                    echo ""
                } >> "$trace_file"

                extract_function_source "$func_name" "$instr_addr" "$trace_file" || true
                echo "" >> "$trace_file"
                ;;
        esac
    done < "$bt_file"
}

log "[0/9] Checking environment..."

for cmd in strings rpm2cpio cpio crash find sort grep sed awk cp mv rpmbuild gdb nl; do
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

log "[1/9] Preparing vmcore in workspace..."

if [ -n "$VMCORE_OVERRIDE" ]; then
    [ -f "$VMCORE_OVERRIDE" ] || fail "Specified vmcore does not exist: $VMCORE_OVERRIDE"
    SELECTED_VMCORE="$VMCORE_OVERRIDE"
    cp -f "$SELECTED_VMCORE" "$TARGET_VMCORE"
else
    [ -d "$SEARCH_ROOT" ] || fail "Search root does not exist: $SEARCH_ROOT"
    SELECTED_VMCORE=$(find_latest_vmcore "$SEARCH_ROOT")
    [ -n "$SELECTED_VMCORE" ] || fail "No vmcore found under: $SEARCH_ROOT"
    cp -f "$SELECTED_VMCORE" "$TARGET_VMCORE"
fi

[ -s "$TARGET_VMCORE" ] || fail "Prepared vmcore is empty or missing: $TARGET_VMCORE"

log "[2/9] Extracting OSRELEASE from vmcore..."
cd "$WORKSPACE_DIR"
OS_RELEASE=$(strings "$TARGET_VMCORE" | grep -m 1 -E "OSRELEASE=[0-9]" | cut -d'=' -f2 || true)
[ -n "$OS_RELEASE" ] || fail "Could not extract OSRELEASE from vmcore."
KERNEL_FLAVOR=$(detect_kernel_flavor "$OS_RELEASE")

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

log "[3/9] Preparing vmlinux..."
if [ -n "$VMLINUX_OVERRIDE" ]; then
    [ -f "$VMLINUX_OVERRIDE" ] || fail "Specified vmlinux does not exist: $VMLINUX_OVERRIDE"
    VMLINUX_ABS="$VMLINUX_OVERRIDE"
else
    mapfile -t DEBUGINFO_CANDIDATES < <(find_debuginfo_rpms "$OS_RELEASE" "$KERNEL_FLAVOR")
    mapfile -t DEBUGINFO_RPMS < <(resolve_existing_rpms "$DEBUGINFO_URL" "${DEBUGINFO_CANDIDATES[@]}")
    [ "${#DEBUGINFO_RPMS[@]}" -gt 0 ] || fail "No matching debuginfo RPM found for ${OS_RELEASE}"

    for rpm_name in "${DEBUGINFO_RPMS[@]}"; do
        if [ ! -f "${DOWNLOAD_DIR}/${rpm_name}" ]; then
            download_file "${DEBUGINFO_URL}${rpm_name}" "${DOWNLOAD_DIR}/${rpm_name}" || fail "RPM download failed: ${rpm_name}"
        else
            log "Reusing downloaded RPM: ${DOWNLOAD_DIR}/${rpm_name}"
        fi
    done

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
fi

log "[4/9] Preparing kernel source tree..."
if [ -n "$SOURCE_DIR_OVERRIDE" ]; then
    [ -d "$SOURCE_DIR_OVERRIDE" ] || fail "Specified source dir does not exist: $SOURCE_DIR_OVERRIDE"
    KERNEL_SOURCE_DIR="$SOURCE_DIR_OVERRIDE"
else
    mapfile -t SOURCE_CANDIDATES < <(find_source_srpm_candidates "$OS_RELEASE" "$KERNEL_FLAVOR")
    mapfile -t SOURCE_SRPMS < <(resolve_existing_rpms "$SRPM_URL" "${SOURCE_CANDIDATES[@]}")
    [ "${#SOURCE_SRPMS[@]}" -gt 0 ] || fail "No matching source SRPM found for ${OS_RELEASE}"

    SOURCE_SRPM_FILE="${SOURCE_SRPMS[0]}"
    if [ ! -f "${DOWNLOAD_DIR}/${SOURCE_SRPM_FILE}" ]; then
        download_file "${SRPM_URL}${SOURCE_SRPM_FILE}" "${DOWNLOAD_DIR}/${SOURCE_SRPM_FILE}" || fail "Source SRPM download failed: ${SOURCE_SRPM_FILE}"
    else
        log "Reusing downloaded source SRPM: ${DOWNLOAD_DIR}/${SOURCE_SRPM_FILE}"
    fi

    SOURCE_RPM_ABS="${DOWNLOAD_DIR}/${SOURCE_SRPM_FILE}"
    if [ -d "$KERNEL_SOURCE_DIR" ] && [ -n "$(find "$KERNEL_SOURCE_DIR" -mindepth 1 -maxdepth 1 2>/dev/null | head -1)" ]; then
        log "Reusing prepared kernel source tree: $KERNEL_SOURCE_DIR"
    else
        prepare_source_tree "$SOURCE_RPM_ABS" "$SOURCE_TOPDIR" "$KERNEL_SOURCE_DIR"
    fi
fi

write_analysis_env "$ANALYSIS_ENV_FILE"

log "[5/9] Prepared analysis inputs..."
echo "OSRELEASE: $OS_RELEASE"
echo "vmcore   : $TARGET_VMCORE"
echo "vmlinux  : $VMLINUX_ABS"
echo "source   : $KERNEL_SOURCE_DIR"
echo "env      : $ANALYSIS_ENV_FILE"

if [ "$PREPARE_ONLY" = "on" ]; then
    log ""
    log "Preparation complete."
    log "Run crash manually with:"
    log "  crash \"$VMLINUX_ABS\" \"$TARGET_VMCORE\""
    exit 0
fi

log "[6/9] Generating bt -f output..."
generate_bt_trace

log "[7/9] Generating code_trace.md..."
generate_code_trace

log "[8/9] Generated outputs..."
echo "bt trace : ${WORKSPACE_DIR}/bt_full.txt"
echo "report   : ${WORKSPACE_DIR}/code_trace.md"
echo "crash cmd: crash \"$VMLINUX_ABS\" \"$TARGET_VMCORE\""

log "[9/9] Done."
