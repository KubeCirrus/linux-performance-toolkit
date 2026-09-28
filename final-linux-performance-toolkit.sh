#!/usr/bin/env bash

###############################################################################
# Linux Performance Diagnostic Tool
#
# Usage:
#
#   ./linux-perf-debug.sh
#   ./linux-perf-debug.sh --help
#
#   ./linux-perf-debug.sh --cpu
#   ./linux-perf-debug.sh --memory
#   ./linux-perf-debug.sh --disk
#   ./linux-perf-debug.sh --network
#   ./linux-perf-debug.sh --process
#   ./linux-perf-debug.sh --kernel
#
#   ./linux-perf-debug.sh --cpu --details
#   ./linux-perf-debug.sh --all --details
#
# Environment:
#
#   DEBUG_PID=1234 ./linux-perf-debug.sh --process
#
# Design:
#
#   - Read-only diagnostics
#   - No packages installed
#   - No configuration changes
#   - Compact terminal output by default
#   - Detailed evidence saved to files
#   - Detailed terminal output available with --details
#
###############################################################################

set -uo pipefail

VERSION="2.0"

HOSTNAME="$(hostname -s 2>/dev/null || echo unknown)"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"

OUT_DIR="${OUT_DIR:-./perf-debug-${HOSTNAME}-${TIMESTAMP}}"

DETAILS=false
DEBUG_PID="${DEBUG_PID:-}"

RUN_CPU=false
RUN_MEMORY=false
RUN_DISK=false
RUN_NETWORK=false
RUN_PROCESS=false
RUN_KERNEL=false
RUN_ALL=false

###############################################################################
# Colors
###############################################################################

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

###############################################################################
# Status symbols
###############################################################################

OK="${GREEN}[ OK ]${NC}"
WARN="${YELLOW}[WARN]${NC}"
CRIT="${RED}[CRIT]${NC}"
INFO="${CYAN}[INFO]${NC}"

###############################################################################
# Help
###############################################################################

usage() {

    cat <<EOF

${BOLD}Linux Performance Diagnostic Tool v${VERSION}${NC}

Collects read-only Linux performance information using commonly
available system tools.

${BOLD}USAGE${NC}

    $0 [OPTION]

${BOLD}OPTIONS${NC}

    --help              Show this help

    --cpu               CPU diagnostics
    --memory            Memory diagnostics
    --disk              Disk/filesystem diagnostics
    --network           Network diagnostics
    --process           Process diagnostics
    --kernel            Kernel/system diagnostics

    --all               Run all diagnostic modules

    --details           Show detailed diagnostic output in terminal

${BOLD}DEFAULT${NC}

    Running without an option performs a complete diagnostic but
    displays only a compact health summary.

${BOLD}EXAMPLES${NC}

    # Overall health
    $0

    # CPU only
    $0 --cpu

    # Memory details
    $0 --memory --details

    # Disk details
    $0 --disk --details

    # Network details
    $0 --network --details

    # All diagnostics
    $0 --all

    # Inspect a particular process
    DEBUG_PID=1234 $0 --process --details

${BOLD}OUTPUT${NC}

    Detailed diagnostic information is always saved under:

    ${OUT_DIR}

EOF
}

###############################################################################
# Logging
###############################################################################

info() {
    printf '%b\n' "$*"
}

section() {
    printf '\n%b%s%b\n' "$BOLD" "$*" "$NC"
    printf '%s\n' "────────────────────────────────────────────"
}

###############################################################################
# Command checks
###############################################################################

have() {
    command -v "$1" >/dev/null 2>&1
}

###############################################################################
# Safe command execution
###############################################################################

save_cmd() {

    local file="$1"
    shift

    {
        echo "Command: $*"
        echo "Date: $(date)"
        echo "--------------------------------------------"
        "$@"
    } > "$file" 2>&1 || true
}

save_shell() {

    local file="$1"
    local cmd="$2"

    {
        echo "Command: $cmd"
        echo "Date: $(date)"
        echo "--------------------------------------------"
        bash -c "$cmd"
    } > "$file" 2>&1 || true
}

###############################################################################
# Setup
###############################################################################

setup() {

    mkdir -p "$OUT_DIR" 2>/dev/null || {

        echo "ERROR: Cannot create output directory:"
        echo "$OUT_DIR"
        exit 1
    }

    SUMMARY_FILE="$OUT_DIR/summary.txt"
    RECOMMENDATIONS_FILE="$OUT_DIR/recommendations.txt"

    : > "$SUMMARY_FILE"
    : > "$RECOMMENDATIONS_FILE"

    {
        echo "Linux Performance Diagnostic"
        echo "============================"
        echo "Hostname : $HOSTNAME"
        echo "Date     : $(date)"
        echo "Kernel   : $(uname -r 2>/dev/null || echo unknown)"
        echo "Output   : $OUT_DIR"
        echo
    } >> "$SUMMARY_FILE"
}

###############################################################################
# Recommendation engine
###############################################################################

recommend() {

    local message="$1"

    echo "→ $message" >> "$RECOMMENDATIONS_FILE"
}

###############################################################################
# CPU
###############################################################################

cpu_diagnostic() {

    local load cpu_count load_ratio
    local cpu_usage idle io_wait
    local status="${OK}"
    local reason=""

    cpu_count="$(nproc 2>/dev/null || echo 1)"

    load="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"

    if have vmstat; then

        read -r _ _ _ _ _ _ _ _ \
            cpu_user cpu_sys cpu_idle cpu_wait _ \
            < <(vmstat 1 2 | tail -1)

        cpu_usage=$((100 - ${cpu_idle:-0}))
        io_wait="${cpu_wait:-0}"

    else

        cpu_usage="?"
        io_wait="?"

    fi

    load_ratio="$(awk -v l="$load" -v c="$cpu_count" \
        'BEGIN {printf "%.2f", l/c}')"

    if [[ "$cpu_usage" != "?" ]]; then

        if (( cpu_usage >= 90 )); then
            status="${CRIT}"
            reason="CPU utilization is critically high"
            recommend "CPU utilization is above 90%. Identify CPU-heavy processes with: $0 --cpu --details"

        elif (( cpu_usage >= 80 )); then
            status="${WARN}"
            reason="CPU utilization is high"
            recommend "CPU utilization is above 80%. Check the top CPU consumers with: $0 --cpu --details"
        fi
    fi

    if [[ "$io_wait" =~ ^[0-9]+$ ]] && (( io_wait >= 20 )); then

        status="${WARN}"
        reason="High CPU I/O wait"
        recommend "CPU is spending significant time waiting for I/O. Investigate storage with: $0 --disk --details"
    fi

    save_shell "$OUT_DIR/cpu.txt" '
        echo "===== CPU ====="
        lscpu 2>/dev/null || true

        echo
        echo "===== LOAD ====="
        cat /proc/loadavg

        echo
        echo "===== VMSTAT ====="
        vmstat 1 10 2>/dev/null || true

        echo
        echo "===== TOP CPU PROCESSES ====="
        ps -eo pid,ppid,user,stat,%cpu,%mem,etime,cmd \
            --sort=-%cpu 2>/dev/null | head -50

        echo
        echo "===== THREADS ====="
        ps -eLf --sort=-pcpu 2>/dev/null | head -50
    '

    section "CPU"

    printf "%b  %s used    Load %s/%s CPUs    I/O wait %s%%%b\n" \
        "$status" \
        "$cpu_usage" \
        "$load" \
        "$cpu_count" \
        "$io_wait" \
        "$NC"

    [[ -n "$reason" ]] && printf "       %s\n" "$reason"

    {
        echo "CPU: $status"
        echo "CPU usage: ${cpu_usage}%"
        echo "Load: ${load}/${cpu_count}"
        echo "I/O wait: ${io_wait}%"
    } >> "$SUMMARY_FILE"

    if $DETAILS; then
        echo
        cat "$OUT_DIR/cpu.txt"
    fi
}

###############################################################################
# Memory
###############################################################################

memory_diagnostic() {

    local total available used_percent
    local swap_total swap_free swap_used
    local status="${OK}"

    total="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    available="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)"

    used_percent="$(
        awk -v t="$total" -v a="$available" \
            'BEGIN {printf "%.0f", ((t-a)/t)*100}'
    )"

    swap_total="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo)"
    swap_free="$(awk '/SwapFree:/ {print $2}' /proc/meminfo)"

    swap_used=$((swap_total - swap_free))

    if (( used_percent >= 95 )); then

        status="${CRIT}"

        recommend "Memory usage is above 95%. Investigate memory-heavy processes with: $0 --memory --details"

    elif (( used_percent >= 85 )); then

        status="${WARN}"

        recommend "Memory usage is above 85%. Review top memory consumers with: $0 --memory --details"
    fi

    if (( swap_used > 0 )); then

        recommend "Swap is in use. Check swap activity using vmstat and investigate memory pressure."
    fi

    save_shell "$OUT_DIR/memory.txt" '
        echo "===== MEMORY ====="
        free -h

        echo
        echo "===== MEMINFO ====="
        cat /proc/meminfo

        echo
        echo "===== TOP MEMORY PROCESSES ====="
        ps -eo pid,ppid,user,stat,%mem,%cpu,rss,vsz,etime,cmd \
            --sort=-%mem 2>/dev/null | head -50

        echo
        echo "===== VMSTAT ====="
        vmstat 1 10 2>/dev/null || true

        echo
        echo "===== SWAP ====="
        swapon --show 2>/dev/null || true
    '

    section "MEMORY"

    printf "%b  %s%% used    Available %s    Swap %s%b\n" \
        "$status" \
        "$used_percent" \
        "$(awk -v x="$available" 'BEGIN {printf "%.1fG", x/1024/1024}')" \
        "$(awk -v x="$swap_used" 'BEGIN {printf "%.1fG", x/1024/1024}')" \
        "$NC"

    {
        echo "MEMORY: $status"
        echo "Memory used: ${used_percent}%"
        echo "Available: $available kB"
        echo "Swap used: $swap_used kB"
    } >> "$SUMMARY_FILE"

    if $DETAILS; then
        echo
        cat "$OUT_DIR/memory.txt"
    fi
}

###############################################################################
# Disk
###############################################################################

disk_diagnostic() {

    local status="${OK}"
    local max_usage=0
    local max_mount=""

    while read -r filesystem size used avail percent mount; do

        [[ "$percent" =~ ^[0-9]+%$ ]] || continue

        usage="${percent%\%}"

        if (( usage > max_usage )); then
            max_usage="$usage"
            max_mount="$mount"
        fi

    done < <(df -P -x tmpfs -x devtmpfs 2>/dev/null | tail -n +2)

    if (( max_usage >= 95 )); then

        status="${CRIT}"

        recommend "Filesystem ${max_mount} is above 95%. Free space or investigate large files with: $0 --disk --details"

    elif (( max_usage >= 85 )); then

        status="${WARN}"

        recommend "Filesystem ${max_mount} is above 85%. Check disk usage with: $0 --disk --details"
    fi

    save_shell "$OUT_DIR/disk.txt" '
        echo "===== FILESYSTEMS ====="
        df -hP

        echo
        echo "===== INODES ====="
        df -iP

        echo
        echo "===== BLOCK DEVICES ====="
        lsblk -o NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS 2>/dev/null || true

        echo
        echo "===== DISK STATISTICS ====="
        cat /proc/diskstats

        echo
        echo "===== VMSTAT ====="
        vmstat 1 10 2>/dev/null || true
    '

    section "DISK"

    printf "%b  Max filesystem usage: %s%%    Mount: %s%b\n" \
        "$status" \
        "$max_usage" \
        "$max_mount" \
        "$NC"

    {
        echo "DISK: $status"
        echo "Maximum filesystem usage: ${max_usage}%"
        echo "Mount: $max_mount"
    } >> "$SUMMARY_FILE"

    if $DETAILS; then
        echo
        cat "$OUT_DIR/disk.txt"
    fi
}

###############################################################################
# Network
###############################################################################

network_diagnostic() {

    local status="${OK}"
    local drops errors
    local total_drops=0
    local total_errors=0

    if [[ -r /proc/net/dev ]]; then

        while read -r iface rxbytes rxpackets rxerr rxdrop \
            rxfifo rxframe rxcompressed rxmulticast \
            txbytes txpackets txerr txdrop \
            txfifo txcolls txcarrier txcompressed rest; do

            [[ "$iface" == "Inter-" ]] && continue
            [[ "$iface" == "face" ]] && continue

            total_drops=$((total_drops + ${rxdrop:-0} + ${txdrop:-0}))
            total_errors=$((total_errors + ${rxerr:-0} + ${txerr:-0}))

        done < <(
            awk 'NR > 2 {
                gsub(":", "", $1)
                print
            }' /proc/net/dev
        )
    fi

    if (( total_errors > 0 )); then

        status="${CRIT}"

        recommend "Network interface errors detected. Inspect interfaces with: $0 --network --details"

    elif (( total_drops > 0 )); then

        status="${WARN}"

        recommend "Network packet drops detected. Investigate NIC, driver, queue and network congestion with: $0 --network --details"
    fi

    save_shell "$OUT_DIR/network.txt" '
        echo "===== INTERFACES ====="
        ip -br addr 2>/dev/null || true

        echo
        echo "===== LINK STATISTICS ====="
        ip -s link 2>/dev/null || true

        echo
        echo "===== ROUTES ====="
        ip route 2>/dev/null || true

        echo
        echo "===== SOCKET SUMMARY ====="
        ss -s 2>/dev/null || true

        echo
        echo "===== LISTENING SOCKETS ====="
        ss -lntup 2>/dev/null || true

        echo
        echo "===== TCP ====="
        ss -tan 2>/dev/null || true

        echo
        echo "===== TCP/NETWORK STATISTICS ====="
        cat /proc/net/snmp
        cat /proc/net/netstat
    '

    section "NETWORK"

    printf "%b  Errors: %s    Drops: %s%b\n" \
        "$status" \
        "$total_errors" \
        "$total_drops" \
        "$NC"

    {
        echo "NETWORK: $status"
        echo "Errors: $total_errors"
        echo "Drops: $total_drops"
    } >> "$SUMMARY_FILE"

    if $DETAILS; then
        echo
        cat "$OUT_DIR/network.txt"
    fi
}

###############################################################################
# Process
###############################################################################

process_diagnostic() {

    section "PROCESS"

    save_shell "$OUT_DIR/process.txt" '
        echo "===== TOP CPU ====="
        ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,cmd \
            --sort=-%cpu 2>/dev/null | head -30

        echo
        echo "===== TOP MEMORY ====="
        ps -eo pid,ppid,user,stat,%cpu,%mem,rss,etime,cmd \
            --sort=-%mem 2>/dev/null | head -30

        echo
        echo "===== D STATE ====="
        ps -eo pid,ppid,user,stat,wchan:32,cmd 2>/dev/null |
            awk '\''$4 ~ /^D/'\''
    '

    ps -eo pid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null |
        head -6 |
        tail -5

    if [[ -n "$DEBUG_PID" ]] && [[ -d "/proc/$DEBUG_PID" ]]; then

        section "PROCESS PID $DEBUG_PID"

        {
            echo "===== STATUS ====="
            cat "/proc/$DEBUG_PID/status"

            echo
            echo "===== IO ====="
            cat "/proc/$DEBUG_PID/io"

            echo
            echo "===== SCHEDULER ====="
            cat "/proc/$DEBUG_PID/sched"

            echo
            echo "===== WAIT CHANNEL ====="
            cat "/proc/$DEBUG_PID/wchan"

            echo
            echo "===== LIMITS ====="
            cat "/proc/$DEBUG_PID/limits"

        } > "$OUT_DIR/pid-${DEBUG_PID}.txt" 2>&1 || true

        if $DETAILS; then
            cat "$OUT_DIR/pid-${DEBUG_PID}.txt"
        else
            echo
            echo "Detailed PID information:"
            echo "  $OUT_DIR/pid-${DEBUG_PID}.txt"
        fi
    fi
}

###############################################################################
# Kernel
###############################################################################

kernel_diagnostic() {

    section "KERNEL"

    save_shell "$OUT_DIR/kernel.txt" '
        echo "===== KERNEL ====="
        uname -a

        echo
        echo "===== RECENT DMESG ====="
        dmesg -T 2>/dev/null | tail -300

        echo
        echo "===== INTERRUPTS ====="
        cat /proc/interrupts

        echo
        echo "===== SOFTIRQS ====="
        cat /proc/softirqs

        echo
        echo "===== OOM ====="
        dmesg -T 2>/dev/null |
            grep -iE "oom|out of memory|killed process" || true
    '

    if $DETAILS; then
        cat "$OUT_DIR/kernel.txt"
    else
        echo "Kernel details: $OUT_DIR/kernel.txt"
    fi
}

###############################################################################
# Summary
###############################################################################

overall_summary() {

    section "LINUX PERFORMANCE HEALTH"

    echo "Host    : $HOSTNAME"
    echo "Time    : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "Kernel  : $(uname -r 2>/dev/null || echo unknown)"
    echo "Output  : $OUT_DIR"

    echo

    echo "Modules:"
    echo "  CPU       $([ "$RUN_CPU" = true ] && echo enabled || echo skipped)"
    echo "  Memory    $([ "$RUN_MEMORY" = true ] && echo enabled || echo skipped)"
    echo "  Disk      $([ "$RUN_DISK" = true ] && echo enabled || echo skipped)"
    echo "  Network   $([ "$RUN_NETWORK" = true ] && echo enabled || echo skipped)"

    echo

    if [[ -s "$RECOMMENDATIONS_FILE" ]]; then

        section "ISSUES / RECOMMENDATIONS"

        while IFS= read -r line; do
            printf "%b%s%b\n" "$YELLOW" "$line" "$NC"
        done < "$RECOMMENDATIONS_FILE"

    else

        section "ISSUES"

        printf "%bNo major issues detected by the basic checks.%b\n" \
            "$GREEN" "$NC"
    fi

    echo
    echo "Detailed reports:"
    echo "  $OUT_DIR"

    if [[ -s "$RECOMMENDATIONS_FILE" ]]; then
        echo
        echo "Recommendations:"
        echo "  $RECOMMENDATIONS_FILE"
    fi
}

###############################################################################
# Parse arguments
###############################################################################

parse_args() {

    local module_selected=false

    while (( $# > 0 )); do

        case "$1" in

            --help|-h)
                usage
                exit 0
                ;;

            --cpu)
                RUN_CPU=true
                module_selected=true
                ;;

            --memory|--mem)
                RUN_MEMORY=true
                module_selected=true
                ;;

            --disk|--storage)
                RUN_DISK=true
                module_selected=true
                ;;

            --network|--net)
                RUN_NETWORK=true
                module_selected=true
                ;;

            --process|--processes)
                RUN_PROCESS=true
                module_selected=true
                ;;

            --kernel)
                RUN_KERNEL=true
                module_selected=true
                ;;

            --all)
                RUN_ALL=true
                module_selected=true
                ;;

            --details|-d)
                DETAILS=true
                ;;

            *)
                echo "Unknown option: $1"
                echo
                usage
                exit 1
                ;;

        esac

        shift
    done

    ###########################################################################
    # No module specified = run everything
    ###########################################################################

    if [[ "$module_selected" == false ]]; then
        RUN_ALL=true
    fi

    ###########################################################################
    # --all = enable everything
    ###########################################################################

    if $RUN_ALL; then
        RUN_CPU=true
        RUN_MEMORY=true
        RUN_DISK=true
        RUN_NETWORK=true
        RUN_PROCESS=true
        RUN_KERNEL=true
    fi
}


###############################################################################
# Main
###############################################################################

main() {

    parse_args "$@"
    setup

    # Always gather selected diagnostics.

    $RUN_CPU     && cpu_diagnostic
    $RUN_MEMORY  && memory_diagnostic
    $RUN_DISK    && disk_diagnostic
    $RUN_NETWORK && network_diagnostic
    $RUN_PROCESS && process_diagnostic
    $RUN_KERNEL  && kernel_diagnostic

    # Default overall summary.

    if $RUN_ALL; then
        overall_summary
    fi

    echo
    printf "%bReport saved:%b %s\n" "$GREEN" "$NC" "$OUT_DIR"

    if [[ -f "$OUT_DIR/recommendations.txt" ]] &&
       [[ -s "$OUT_DIR/recommendations.txt" ]]; then

        echo
        printf "%bIssues found. See:%b %s\n" \
            "$YELLOW" "$NC" \
            "$OUT_DIR/recommendations.txt"
    fi
}

main "$@"
