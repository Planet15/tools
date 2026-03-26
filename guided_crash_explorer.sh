#!/bin/bash

set -euo pipefail

VMLINUX=""
VMCORE=""
OUTPUT_DIR=""
MODE="all"

usage() {
    cat <<'EOF'
Usage: guided_crash_explorer.sh --vmlinux <path> --vmcore <path> [options]

Options:
  --vmlinux <path>     Path to vmlinux with symbols
  --vmcore <path>      Path to vmcore
  --output-dir <path>  Output directory for generated reports
  --mode <name>        all | summary | tasks | memory | locks | modules | files | network
  -h, --help           Show this help

Default output directory:
  ~/vmcore_analysis/explorer-YYYYmmdd-HHMMSS
EOF
}

log() {
    echo "$1"
}

fail() {
    echo "Error: $1" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --vmlinux)
            shift
            [ -n "${1:-}" ] || fail "--vmlinux requires a path"
            VMLINUX="$1"
            ;;
        --vmcore)
            shift
            [ -n "${1:-}" ] || fail "--vmcore requires a path"
            VMCORE="$1"
            ;;
        --output-dir)
            shift
            [ -n "${1:-}" ] || fail "--output-dir requires a path"
            OUTPUT_DIR="$1"
            ;;
        --mode)
            shift
            [ -n "${1:-}" ] || fail "--mode requires a value"
            MODE="$1"
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

[ -n "$VMLINUX" ] || fail "--vmlinux is required"
[ -n "$VMCORE" ] || fail "--vmcore is required"
[ -f "$VMLINUX" ] || fail "vmlinux not found: $VMLINUX"
[ -f "$VMCORE" ] || fail "vmcore not found: $VMCORE"
command -v crash >/dev/null 2>&1 || fail "Required command not found: crash"

if [ -z "$OUTPUT_DIR" ]; then
    OUTPUT_DIR="${HOME}/vmcore_analysis/explorer-$(date +%Y%m%d-%H%M%S)"
fi

mkdir -p "$OUTPUT_DIR"

run_section() {
    local name="$1"
    local title="$2"
    local commands="$3"
    local cmd_file="${OUTPUT_DIR}/${name}.cmd"
    local out_file="${OUTPUT_DIR}/${name}.txt"

    cat > "$cmd_file" <<EOF
set scroll off
$commands
quit
EOF

    log "Generating ${name}..."
    crash -i "$cmd_file" "$VMLINUX" "$VMCORE" > "$out_file" 2>&1 || true

    {
        echo "# ${title}"
        echo ""
        echo "Output file: ${out_file}"
        echo ""
        echo "Key questions:"
        case "$name" in
            summary)
                echo "- Did the dump come from panic, watchdog, or manual crash?"
                echo "- What kernel, uptime, and machine profile are we looking at?"
                ;;
            tasks)
                echo "- Which tasks were blocked, running, or in uninterruptible sleep?"
                echo "- Which stack traces repeat across multiple tasks?"
                ;;
            memory)
                echo "- Was there memory pressure, OOM, fragmentation, or slab growth?"
                echo "- Do the memory counters match the failure symptoms?"
                ;;
            locks)
                echo "- Is there a deadlock or a long-held lock signature?"
                echo "- Are multiple tasks stuck behind the same resource?"
                ;;
            modules)
                echo "- Which modules were loaded at crash time?"
                echo "- Do the stack traces point into a third-party or out-of-tree module?"
                ;;
            files)
                echo "- Are file tables, mounts, or inode-related operations visible in stacks?"
                echo "- Is the issue likely storage or filesystem related?"
                ;;
            network)
                echo "- Do stacks or device state suggest a networking issue?"
                echo "- Are softirq or driver paths recurring in the trace?"
                ;;
        esac
        echo ""
    } > "${OUTPUT_DIR}/${name}.md"
}

generate_index() {
    local index_file="${OUTPUT_DIR}/index.md"

    {
        echo "# Guided Crash Explorer"
        echo ""
        echo "- vmlinux: ${VMLINUX}"
        echo "- vmcore: ${VMCORE}"
        echo "- generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo ""
        echo "## Suggested reading order"
        echo ""
        echo "1. summary"
        echo "2. tasks"
        echo "3. memory"
        echo "4. locks"
        echo "5. modules"
        echo "6. files"
        echo "7. network"
        echo ""
        echo "## Output files"
        echo ""
        for name in summary tasks memory locks modules files network; do
            if [ -f "${OUTPUT_DIR}/${name}.txt" ]; then
                echo "- ${name}: ${name}.txt"
            fi
        done
        echo ""
        echo "## Notes"
        echo ""
        echo "- This is not a replay engine. It is a guided postmortem explorer."
        echo "- Each section runs a curated set of crash commands against the same snapshot."
    } > "$index_file"
}

case "$MODE" in
    all|summary)
        run_section "summary" "System Summary" $'sys\nlog\nmach\nbt'
        ;;
esac

case "$MODE" in
    all|tasks)
        run_section "tasks" "Task and Stack Survey" $'ps -m\nps -k\nrunq\nforeach bt'
        ;;
esac

case "$MODE" in
    all|memory)
        run_section "memory" "Memory View" $'kmem -i\nvm\nkmem -V'
        ;;
esac

case "$MODE" in
    all|locks)
        run_section "locks" "Lock and Wait Analysis" $'ps -m\nbt -a'
        ;;
esac

case "$MODE" in
    all|modules)
        run_section "modules" "Module Survey" $'mod\nsym -m'
        ;;
esac

case "$MODE" in
    all|files)
        run_section "files" "Filesystem and Mount Survey" $'mount\nfiles'
        ;;
esac

case "$MODE" in
    all|network)
        run_section "network" "Network Survey" $'net\ndev -d'
        ;;
esac

generate_index

log ""
log "Guided crash explorer output: ${OUTPUT_DIR}"
log "Start with: ${OUTPUT_DIR}/index.md"
