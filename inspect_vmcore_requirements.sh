#!/bin/bash

set -euo pipefail

VMCORE_PATH=""
SHOW_RAW="off"

usage() {
    cat <<'EOF'
Usage: inspect_vmcore_requirements.sh --vmcore /path/to/vmcore [--show-raw]

This script inspects a Linux vmcore and prints:
  - extracted OSRELEASE
  - probable distro/vendor
  - architecture
  - kernel flavor hint
  - recommended debugger and debuginfo/vmlinux requirements

Options:
  --vmcore <path>   Path to vmcore file
  --show-raw        Show raw clues extracted from the vmcore
  -h, --help        Show this help
EOF
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --vmcore)
            shift
            [ -n "${1:-}" ] || fail "--vmcore requires a path"
            VMCORE_PATH="$1"
            ;;
        --show-raw)
            SHOW_RAW="on"
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

[ -n "$VMCORE_PATH" ] || fail "--vmcore is required"
[ -f "$VMCORE_PATH" ] || fail "vmcore does not exist: $VMCORE_PATH"

for cmd in strings grep sed awk tr file; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
done

TMP_STRINGS=$(mktemp)
trap 'rm -f "$TMP_STRINGS"' EXIT

strings "$VMCORE_PATH" > "$TMP_STRINGS"

extract_first_value() {
    local pattern="$1"
    local strip_prefix="$2"

    grep -m 1 -E "$pattern" "$TMP_STRINGS" 2>/dev/null | sed -E "s/^${strip_prefix}//" || true
}

extract_osrelease() {
    local value

    value=$(extract_first_value '^OSRELEASE=' 'OSRELEASE=')
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    value=$(grep -m 1 -E 'Linux version [^ ]+' "$TMP_STRINGS" 2>/dev/null | awk '{print $3}' || true)
    echo "$value"
}

extract_arch() {
    local osrelease="$1"
    local value

    value=$(printf '%s\n' "$osrelease" | sed -nE 's/.*\.(x86_64|aarch64|arm64|ppc64le|s390x|i686|i386)$/\1/p')
    if [ -n "$value" ]; then
        echo "$value"
        return 0
    fi

    value=$(extract_first_value '^UTS_MACHINE=' 'UTS_MACHINE=')
    echo "$value"
}

detect_kernel_flavor() {
    local osrelease="$1"

    case "$osrelease" in
        *uek*) echo "uek" ;;
        *aws*|*amzn*) echo "aws" ;;
        *azure*) echo "azure" ;;
        *gcp*) echo "gcp" ;;
        *) echo "generic" ;;
    esac
}

detect_distro() {
    local osrelease="$1"

    if grep -qi 'Oracle Linux' "$TMP_STRINGS" || [[ "$osrelease" == *uek* ]]; then
        echo "Oracle Linux"
    elif grep -qi 'Red Hat Enterprise Linux' "$TMP_STRINGS"; then
        echo "Red Hat Enterprise Linux"
    elif grep -qi 'CentOS' "$TMP_STRINGS"; then
        echo "CentOS"
    elif grep -qi 'Rocky Linux' "$TMP_STRINGS"; then
        echo "Rocky Linux"
    elif grep -qi 'AlmaLinux' "$TMP_STRINGS"; then
        echo "AlmaLinux"
    elif grep -qi 'Fedora' "$TMP_STRINGS"; then
        echo "Fedora"
    elif grep -qi 'Ubuntu' "$TMP_STRINGS"; then
        echo "Ubuntu"
    elif grep -qi 'Debian' "$TMP_STRINGS"; then
        echo "Debian"
    elif grep -qi 'Amazon Linux' "$TMP_STRINGS" || [[ "$osrelease" == *amzn* ]]; then
        echo "Amazon Linux"
    elif grep -qi 'SUSE Linux Enterprise' "$TMP_STRINGS"; then
        echo "SUSE Linux Enterprise"
    elif grep -qi 'openSUSE' "$TMP_STRINGS"; then
        echo "openSUSE"
    else
        echo "Unknown"
    fi
}

print_package_guidance() {
    local distro="$1"
    local osrelease="$2"
    local arch="$3"
    local flavor="$4"

    echo "Recommended debugger:"
    echo "  - crash"
    echo ""
    echo "Required symbols:"
    echo "  - exact uncompressed vmlinux matching OSRELEASE"
    echo "  - matching debuginfo/debug symbol package for the same kernel build"
    echo ""
    echo "Package guidance:"

    case "$distro" in
        "Oracle Linux")
            if [ "$flavor" = "uek" ]; then
                echo "  - kernel-uek-debuginfo-${osrelease}"
                echo "  - source SRPM usually starts with kernel-uek-"
            else
                echo "  - kernel-debuginfo-${osrelease}"
                [ -n "$arch" ] && echo "  - kernel-debuginfo-common-${arch}-${osrelease}"
                echo "  - source SRPM usually starts with kernel-"
            fi
            ;;
        "Red Hat Enterprise Linux"|"CentOS"|"Rocky Linux"|"AlmaLinux")
            echo "  - kernel-debuginfo-${osrelease}"
            [ -n "$arch" ] && echo "  - kernel-debuginfo-common-${arch}-${osrelease}"
            echo "  - source SRPM usually starts with kernel-"
            ;;
        "Fedora")
            echo "  - kernel-debuginfo-${osrelease}"
            echo "  - source SRPM usually starts with kernel-"
            ;;
        "Ubuntu"|"Debian")
            echo "  - install the matching dbgsym/debug package for the exact kernel build"
            echo "  - common patterns: linux-image-<version>-dbgsym or linux-image-unsigned-<version>-dbgsym"
            echo "  - matching vmlinux may come from dbgsym packages rather than a plain kernel-debuginfo RPM"
            ;;
        "Amazon Linux")
            echo "  - use the exact debug symbol package from the Amazon Linux debuginfo/debug-symbol repository"
            echo "  - package naming varies by major release; start from the exact kernel release string"
            ;;
        "SUSE Linux Enterprise"|"openSUSE")
            echo "  - use the matching kernel debuginfo package for the exact kernel flavor"
            echo "  - common patterns include kernel-default-debuginfo or kernel-debuginfo"
            ;;
        *)
            echo "  - locate an exact vmlinux for ${osrelease}"
            echo "  - install the matching debuginfo/debug symbol package from the original distro/vendor"
            ;;
    esac
}

print_repo_guidance() {
    local distro="$1"

    echo ""
    echo "Repository/source guidance:"
    case "$distro" in
        "Oracle Linux")
            echo "  - Oracle Linux debuginfo and source repositories"
            ;;
        "Red Hat Enterprise Linux")
            echo "  - RHEL BaseOS/AppStream debuginfo channels via subscription"
            ;;
        "CentOS")
            echo "  - CentOS vault/debuginfo repositories matching the original release"
            ;;
        "Rocky Linux")
            echo "  - Rocky Linux debuginfo repositories matching the original release"
            ;;
        "AlmaLinux")
            echo "  - AlmaLinux debuginfo repositories matching the original release"
            ;;
        "Fedora")
            echo "  - Fedora updates/debug repositories"
            ;;
        "Ubuntu"|"Debian")
            echo "  - distro debug symbol repositories (ddebs/dbgsym or debug symbol archives)"
            ;;
        "Amazon Linux")
            echo "  - Amazon Linux debug symbol/debuginfo repositories"
            ;;
        "SUSE Linux Enterprise"|"openSUSE")
            echo "  - SUSE/openSUSE debug repositories matching the exact kernel flavor"
            ;;
        *)
            echo "  - the original vendor's debug symbol repository for the exact kernel build"
            ;;
    esac
}

OSRELEASE=$(extract_osrelease)
[ -n "$OSRELEASE" ] || fail "Could not extract OSRELEASE from vmcore"

ARCH=$(extract_arch "$OSRELEASE")
KERNEL_FLAVOR=$(detect_kernel_flavor "$OSRELEASE")
DISTRO=$(detect_distro "$OSRELEASE")
FILE_INFO=$(file "$VMCORE_PATH" 2>/dev/null || true)

echo "VMcore requirements"
echo "==================="
echo "vmcore      : $VMCORE_PATH"
echo "file        : $FILE_INFO"
echo "osrelease   : $OSRELEASE"
[ -n "$ARCH" ] && echo "arch        : $ARCH"
echo "kernel type : $KERNEL_FLAVOR"
echo "probable os : $DISTRO"

echo ""
print_package_guidance "$DISTRO" "$OSRELEASE" "$ARCH" "$KERNEL_FLAVOR"
print_repo_guidance "$DISTRO"

echo ""
echo "Recommended analysis command:"
echo "  crash /path/to/vmlinux \"$VMCORE_PATH\""

echo ""
echo "Suggested next checks:"
echo "  - confirm the distro/vendor with strings output"
echo "  - obtain exact vmlinux and matching debuginfo for $OSRELEASE"
echo "  - avoid mixing Oracle UEK, RHCK, RHEL, Ubuntu, or SUSE symbols"

if [ "$SHOW_RAW" = "on" ]; then
    echo ""
    echo "Raw clues"
    echo "========="
    echo "-- OSRELEASE --"
    grep -m 1 '^OSRELEASE=' "$TMP_STRINGS" || true
    echo ""
    echo "-- Linux version --"
    grep -m 1 -E 'Linux version [^ ]+' "$TMP_STRINGS" || true
    echo ""
    echo "-- Vendor hints --"
    grep -i -m 5 -E 'Oracle Linux|Red Hat Enterprise Linux|CentOS|Rocky Linux|AlmaLinux|Fedora|Ubuntu|Debian|Amazon Linux|SUSE Linux Enterprise|openSUSE' "$TMP_STRINGS" || true
fi
