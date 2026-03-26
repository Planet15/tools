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

log "[0/5] Checking environment..."

for cmd in strings wget rpm2cpio cpio crash find sort; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

mkdir -p "$WORKSPACE_DIR"
[ -w "$WORKSPACE_DIR" ] || fail "No write permission in workspace: $WORKSPACE_DIR"

TARGET_VMCORE="${WORKSPACE_DIR}/vmcore"
SELECTED_VMCORE=""

log "[1/5] Preparing vmcore in workspace..."

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

log "[2/5] Extracting OSRELEASE from vmcore..."
OS_RELEASE=$(strings vmcore | grep -m 1 -E "OSRELEASE=[0-9]" | cut -d'=' -f2 || true)
[ -n "$OS_RELEASE" ] || fail "Could not extract OSRELEASE from vmcore."

echo "Detected OSRELEASE: $OS_RELEASE"

case "$OS_RELEASE" in
    *.el5*) OL_PATH="ol5" ;;
    *.el6*) OL_PATH="ol6" ;;
    *.el7*) OL_PATH="ol7" ;;
    *.el8*) OL_PATH="ol8" ;;
    *.el9*) OL_PATH="ol9" ;;
    *.el10*) OL_PATH="ol10" ;;
    *) fail "Unsupported OSRELEASE: $OS_RELEASE" ;;
esac

log "[3/5] Downloading debuginfo RPM..."
RPM_NAME="kernel-uek-debuginfo-${OS_RELEASE}.rpm"
BASE_URL="https://oss.oracle.com"
FULL_URL="${BASE_URL}/${OL_PATH}/debuginfo/${RPM_NAME}"

echo "Download URL: ${FULL_URL}"
wget -nc "$FULL_URL" || fail "RPM download failed."

log "[4/5] Extracting vmlinux..."
VMLINUX_PATH="./usr/lib/debug/lib/modules/${OS_RELEASE}/vmlinux"
rpm2cpio "$RPM_NAME" | cpio -idm "$VMLINUX_PATH" >/dev/null 2>&1 || true

[ -f "$VMLINUX_PATH" ] || fail "vmlinux extraction failed or path is incorrect: $VMLINUX_PATH"

echo "vmlinux: $VMLINUX_PATH"
echo "vmcore : $(pwd)/vmcore"

log "[5/5] Starting crash..."
exec crash "$VMLINUX_PATH" vmcore
