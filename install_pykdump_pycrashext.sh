#!/bin/bash

set -euo pipefail

PYKDUMP_FILES_URL="https://sourceforge.net/projects/pykdump/files/mpykdump-x86_64/"
PYCRASHEXT_REPO_URL="https://github.com/sungju/pycrashext.git"

INSTALL_BASE="${HOME}/.local"
PYKDUMP_DIR="${INSTALL_BASE}/lib/pykdump"
PYCRASHEXT_DIR="${INSTALL_BASE}/src/pycrashext"
CRASHRC="${HOME}/.crashrc"
BASH_PROFILE="${HOME}/.bash_profile"
SERVER_ADDR="${CRASHEXT_SERVER:-}"

log() {
    echo "$1"
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --install-base <path>   Override install base directory (default: ${INSTALL_BASE})
  --server <url>          Set CRASHEXT_SERVER in ~/.bash_profile
  -h, --help              Show this help

This script will:
  1) Detect the installed crash major version
  2) Download the latest matching pykdump extension from SourceForge
  3) Clone or update pycrashext from GitHub
  4) Configure ~/.crashrc and ~/.bash_profile for both tools
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-base)
            shift
            [ -n "${1:-}" ] || fail "--install-base requires a path"
            INSTALL_BASE="$1"
            ;;
        --server)
            shift
            [ -n "${1:-}" ] || fail "--server requires a URL"
            SERVER_ADDR="$1"
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

PYKDUMP_DIR="${INSTALL_BASE}/lib/pykdump"
PYCRASHEXT_DIR="${INSTALL_BASE}/src/pycrashext"

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

for cmd in crash git python3 sed grep awk sort mkdir ln rm; do
    require_cmd "$cmd"
done

DOWNLOAD_TOOL=""
if command -v curl >/dev/null 2>&1; then
    DOWNLOAD_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
    DOWNLOAD_TOOL="wget"
else
    fail "curl or wget is required"
fi

fetch_url() {
    local url="$1"
    if [ "$DOWNLOAD_TOOL" = "curl" ]; then
        curl -fsSL "$url"
    else
        wget -qO- "$url"
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    if [ "$DOWNLOAD_TOOL" = "curl" ]; then
        curl -fL "$url" -o "$output"
    else
        wget -O "$output" "$url"
    fi
}

detect_crash_major() {
    crash --version 2>/dev/null | awk '
        /crash [0-9]/ {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^[0-9]+\./) {
                    split($i, parts, ".")
                    print parts[1]
                    exit
                }
            }
        }
    '
}

update_managed_block() {
    local file="$1"
    local tag="$2"
    local content="$3"
    local tmp

    tmp=$(mktemp)
    touch "$file"
    awk -v start="# >>> ${tag} >>>" -v end="# <<< ${tag} <<<" '
        $0 == start { skip=1; next }
        $0 == end   { skip=0; next }
        !skip { print }
    ' "$file" > "$tmp"

    {
        cat "$tmp"
        echo "$content"
    } > "$file"

    rm -f "$tmp"
}

log "[1/5] Detecting crash version..."
CRASH_MAJOR=$(detect_crash_major)
[ -n "$CRASH_MAJOR" ] || fail "Could not detect crash major version. Check 'crash --version'."
log "Detected crash major version: ${CRASH_MAJOR}"

log "[2/5] Finding latest matching pykdump extension..."
PYKDUMP_FILE=$(fetch_url "$PYKDUMP_FILES_URL" | grep -oE "mpykdump-[0-9][^\"']*-crash${CRASH_MAJOR}\.so" | sort -uV | tail -1)
[ -n "$PYKDUMP_FILE" ] || fail "No pykdump binary found for crash${CRASH_MAJOR} at ${PYKDUMP_FILES_URL}"

mkdir -p "$PYKDUMP_DIR"
PYKDUMP_TARGET="${PYKDUMP_DIR}/${PYKDUMP_FILE}"
PYKDUMP_LINK="${PYKDUMP_DIR}/mpykdump-current.so"

if [ ! -f "$PYKDUMP_TARGET" ]; then
    log "Downloading ${PYKDUMP_FILE}..."
    download_file "${PYKDUMP_FILES_URL}${PYKDUMP_FILE}/download" "$PYKDUMP_TARGET"
else
    log "Using existing file: ${PYKDUMP_TARGET}"
fi

ln -sfn "$PYKDUMP_TARGET" "$PYKDUMP_LINK"
log "Pykdump installed: ${PYKDUMP_TARGET}"

log "[3/5] Cloning or updating pycrashext..."
mkdir -p "$(dirname "$PYCRASHEXT_DIR")"
if [ -d "${PYCRASHEXT_DIR}/.git" ]; then
    git -C "$PYCRASHEXT_DIR" pull --ff-only
else
    rm -rf "$PYCRASHEXT_DIR"
    git clone "$PYCRASHEXT_REPO_URL" "$PYCRASHEXT_DIR"
fi

PYCRASHEXT_SOURCE_DIR="${PYCRASHEXT_DIR}/source"
[ -f "${PYCRASHEXT_SOURCE_DIR}/regext.py" ] || fail "pycrashext source not found: ${PYCRASHEXT_SOURCE_DIR}/regext.py"

log "[4/5] Updating ~/.crashrc..."
CRASHRC_BLOCK=$(cat <<EOF
# >>> tools-pykdump-pycrashext >>>
extend ${PYKDUMP_LINK}
epython ${PYCRASHEXT_SOURCE_DIR}/regext.py
# <<< tools-pykdump-pycrashext <<<
EOF
)
update_managed_block "$CRASHRC" "tools-pykdump-pycrashext" "$CRASHRC_BLOCK"

log "[5/5] Updating ~/.bash_profile..."
PYTHON_PATHS=$(python3 -c 'import sys; print(":".join(p for p in sys.path if p))')
BASH_PROFILE_BLOCK=$(cat <<EOF
# >>> tools-pykdump-pycrashext >>>
export PYKDUMPPATH="${PYCRASHEXT_SOURCE_DIR}:\${PYKDUMPPATH}:${PYTHON_PATHS}"
EOF
)

if [ -n "$SERVER_ADDR" ]; then
    BASH_PROFILE_BLOCK="${BASH_PROFILE_BLOCK}
export CRASHEXT_SERVER=\"${SERVER_ADDR}\""
fi

BASH_PROFILE_BLOCK="${BASH_PROFILE_BLOCK}
# <<< tools-pykdump-pycrashext <<<"

update_managed_block "$BASH_PROFILE" "tools-pykdump-pycrashext" "$BASH_PROFILE_BLOCK"

log ""
log "Installation complete."
log "pykdump    : ${PYKDUMP_LINK}"
log "pycrashext : ${PYCRASHEXT_DIR}"
log "crashrc    : ${CRASHRC}"
log "bash_prof  : ${BASH_PROFILE}"
log ""
log "Open a new shell or run:"
log "  source ${BASH_PROFILE}"
log ""
log "Then start crash as usual."
