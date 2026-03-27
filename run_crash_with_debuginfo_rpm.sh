#!/bin/bash

set -euo pipefail

DEBUGINFO_RPM=""
VMCORE_PATH=""
WORK_DIR="${HOME}/vmcore_debug"
PREPARE_ONLY="off"

usage() {
    cat <<'EOF'
Usage: run_crash_with_debuginfo_rpm.sh --debuginfo-rpm /path/to/kernel-debuginfo.rpm --vmcore /path/to/vmcore [options]

Options:
  --debuginfo-rpm <path>   Path to kernel debuginfo RPM
  --vmcore <path>          Path to vmcore file
  --workdir <path>         Directory for extracted files (default: ~/vmcore_debug)
  --prepare-only           Extract vmlinux and stop before running crash
  -h, --help              Show this help
EOF
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --debuginfo-rpm)
            shift
            [ -n "${1:-}" ] || fail "--debuginfo-rpm requires a path"
            DEBUGINFO_RPM="$1"
            ;;
        --vmcore)
            shift
            [ -n "${1:-}" ] || fail "--vmcore requires a path"
            VMCORE_PATH="$1"
            ;;
        --workdir)
            shift
            [ -n "${1:-}" ] || fail "--workdir requires a path"
            WORK_DIR="$1"
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

[ -n "$DEBUGINFO_RPM" ] || fail "--debuginfo-rpm is required"
[ -f "$DEBUGINFO_RPM" ] || fail "debuginfo RPM does not exist: $DEBUGINFO_RPM"
[ -n "$VMCORE_PATH" ] || fail "--vmcore is required"
[ -f "$VMCORE_PATH" ] || fail "vmcore does not exist: $VMCORE_PATH"

for cmd in rpm2cpio cpio find crash mkdir cp; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

mkdir -p "$WORK_DIR"
EXTRACT_DIR="${WORK_DIR}/debug"
TARGET_VMCORE="${WORK_DIR}/$(basename "$VMCORE_PATH")"

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
    local relpath

    relpath=$(find_vmlinux_relpath_in_rpm "$rpm_file")
    [ -n "$relpath" ] || fail "Could not find vmlinux path inside RPM: $rpm_file"

    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"

    (
        cd "$dest_dir"
        rpm2cpio "$rpm_file" | cpio -idm "./${relpath}" "${relpath}" >/dev/null 2>&1 || true
        rpm2cpio "$rpm_file" | cpio -idm '*/vmlinux' >/dev/null 2>&1 || true
    )

    if [ -f "${dest_dir}/${relpath}" ]; then
        echo "${dest_dir}/${relpath}"
        return 0
    fi

    find "$dest_dir" -type f -path '*/usr/lib/debug/lib/modules/*/vmlinux' | head -1
}

VMLINUX_PATH=$(extract_vmlinux_from_rpm "$DEBUGINFO_RPM" "$EXTRACT_DIR")
[ -n "$VMLINUX_PATH" ] && [ -f "$VMLINUX_PATH" ] || fail "Failed to extract vmlinux from: $DEBUGINFO_RPM"

cp -f "$VMCORE_PATH" "$TARGET_VMCORE"

echo "Prepared inputs"
echo "==============="
echo "debuginfo rpm : $DEBUGINFO_RPM"
echo "vmlinux       : $VMLINUX_PATH"
echo "vmcore        : $TARGET_VMCORE"
echo ""
echo "crash cmd:"
echo "  crash \"$VMLINUX_PATH\" \"$TARGET_VMCORE\""

if [ "$PREPARE_ONLY" = "on" ]; then
    exit 0
fi

exec crash "$VMLINUX_PATH" "$TARGET_VMCORE"
