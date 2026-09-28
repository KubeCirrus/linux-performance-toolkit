#!/usr/bin/env bash

set -u

INTERVAL="${INTERVAL:-1}"
COUNT="${COUNT:-2}"
TOP_N="${TOP_N:-15}"
TIMEOUT="${TIMEOUT:-10}"

HOSTNAME=$(hostname -f 2>/dev/null || hostname)
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
REPORT_DIR="${REPORT_DIR:-/tmp/linux-health}"
REPORT_FILE="${REPORT_DIR}/${HOSTNAME}_${TIMESTAMP}.log"

mkdir -p "$REPORT_DIR"

section() {
    printf '\n===== %s =====\n' "$1"
}

run_cmd() {
    local description="$1"
    shift

    if ! timeout "$TIMEOUT" "$@"; then
        echo "[WARN] Command failed or timed out: $description" >&2
    fi
}

check_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "[ERROR] Required command not found: $1" >&2
        return 1
    fi
}

main() {

    local missing=0

    for cmd in ps pidstat ss free uptime nproc df timeout; do
        if ! check_command "$cmd"; then
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        echo "Install the missing utilities before running this script." >&2
        exit 1
    fi

    exec > >(tee "$REPORT_FILE") 2>&1

    section "Report Information"
    echo "Hostname : $HOSTNAME"
    echo "Timestamp: $(date --iso-8601=seconds)"
    echo "Kernel   : $(uname -r)"
    echo "Uptime   : $(uptime -p 2>/dev/null || true)"

    section "System"
    echo "CPU cores: $(nproc)"
    uptime
    free -h

    section "Filesystem"
    df -hT

    section "CPU - Top Processes"

    ps -eo pid,ppid,user,state,%cpu,%mem,etime,comm \
        --sort=-%cpu |
        head -n $((TOP_N + 1))

    section "Memory - Top Processes"

    ps -eo pid,ppid,user,state,%cpu,%mem,rss,vsz,etime,comm \
        --sort=-%mem |
        head -n $((TOP_N + 1))

    section "Processes Stuck in D State"

    ps -eo pid,ppid,user,state,etime,comm,wchan:32 |
        awk 'NR == 1 || $4 == "D"'

    section "Disk I/O"

    run_cmd "pidstat disk statistics" \
        pidstat -d "$INTERVAL" "$COUNT"

    section "Network"

    if [[ $EUID -eq 0 ]]; then
        run_cmd "network sockets" ss -tunap
    else
        echo "[INFO] Running without root. Process information may be limited."
        run_cmd "network sockets" ss -tuna
    fi

    section "Summary"

    echo "Report completed."
    echo "Report saved to: $REPORT_FILE"
}

main "$@"

