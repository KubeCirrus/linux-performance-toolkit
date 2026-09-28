#!/usr/bin/env bash
#
# perf-check-basic.sh - quick, read-only Linux performance snapshot
#
# Usage:   ./perf-check-basic.sh                 # print to screen
#          ./perf-check-basic.sh > report.txt    # save to a file
#          sudo ./perf-check-basic.sh            # more detail (dmesg, per-process I/O)
#
# Uses only tools that ship with most distros. Anything missing is skipped.
# Takes about 15 seconds (a few commands sample for a few seconds).

section() { printf '\n===== %s =====\n' "$1"; }

# Run a command if it exists, otherwise say so and carry on.
cmd() {
    echo "\$ $*"
    if command -v "$1" >/dev/null 2>&1; then
        "$@" 2>&1
    else
        echo "(not installed: $1)"
    fi
}

echo "Performance snapshot: $(hostname) - $(date)"
echo "Kernel: $(uname -r)   Running as: $(id -un)"

section "1. LOAD (compare load average with CPU core count)"
cmd uptime
echo "CPU cores: $(nproc)"

section "2. CPU / MEMORY / IO OVERVIEW (5 samples, 1s apart)"
# r = runnable procs, b = blocked on IO, si/so = swap in/out (should be 0),
# us/sy/id/wa/st = user/system/idle/iowait/steal percent
cmd vmstat 1 5

section "3. PER-CORE CPU"
cmd mpstat -P ALL 1 3

section "4. MEMORY"
cmd free -h
# 'available' is the number that matters, not 'free'

section "5. DISK USAGE AND INODES"
cmd df -h
cmd df -i

section "6. DISK I/O LATENCY (look at await and %util)"
cmd iostat -xz 1 3

section "7. TOP 10 PROCESSES BY CPU"
ps aux --sort=-%cpu 2>&1 | head -n 11

section "8. TOP 10 PROCESSES BY MEMORY"
ps aux --sort=-%mem 2>&1 | head -n 11

section "9. PROCESSES STUCK IN DISK WAIT (state D)"
ps -eo state,pid,comm 2>&1 | awk '$1 == "D"'

section "10. NETWORK"
cmd ss -s
cmd ip -s link

section "11. RECENT KERNEL PROBLEMS (OOM kills, disk errors)"
dmesg -T 2>&1 | grep -iE 'oom|out of memory|killed process|i/o error|throttl|error' | tail -n 20

section "12. PRESSURE STALL INFO (percent of time tasks were stalled)"
for r in cpu memory io; do
    if [ -r "/proc/pressure/$r" ]; then
        echo "-- $r"
        cat "/proc/pressure/$r" 2>&1
    fi
done

cat <<'EOF'

===== QUICK GUIDE =====
- Load average >> cores          -> CPU saturated, or many procs blocked on IO
- wa (iowait) high in vmstat     -> disk is the bottleneck: check iostat, section 9
- si/so nonzero in vmstat        -> swapping: memory shortage, check section 4 and 8
- 'available' memory very low    -> memory pressure, OOM kills may follow (section 11)
- df 100% or inodes 100%         -> full disk: writes fail or stall
- st (steal) high                -> the hypervisor is starving this VM
- Nothing obvious?               -> run the robust script: perf-diagnose.sh
EOF
