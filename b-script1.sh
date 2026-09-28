#!/usr/bin/env bash

# Basic Linux performance diagnostic script
# Does not modify system state.

OUT="perf-debug-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

echo "Linux Performance Diagnostic"
echo "Output: $OUT"
echo

echo "===== SYSTEM =====" | tee "$OUT/system.txt"
date | tee -a "$OUT/system.txt"
hostname | tee -a "$OUT/system.txt"
uname -a | tee -a "$OUT/system.txt"
uptime | tee -a "$OUT/system.txt"
nproc | tee -a "$OUT/system.txt"

echo "===== CPU =====" | tee "$OUT/cpu.txt"
lscpu | tee -a "$OUT/cpu.txt"
echo | tee -a "$OUT/cpu.txt"
top -b -n 1 | head -40 | tee -a "$OUT/cpu.txt"

echo "===== TOP CPU PROCESSES =====" | tee "$OUT/processes.txt"
ps -eo pid,ppid,user,stat,%cpu,%mem,etime,cmd --sort=-%cpu \
    | head -30 | tee -a "$OUT/processes.txt"

echo "===== TOP MEMORY PROCESSES =====" | tee -a "$OUT/processes.txt"
ps -eo pid,ppid,user,stat,%cpu,%mem,etime,cmd --sort=-%mem \
    | head -30 | tee -a "$OUT/processes.txt"

echo "===== MEMORY =====" | tee "$OUT/memory.txt"
free -h | tee -a "$OUT/memory.txt"
echo | tee -a "$OUT/memory.txt"
cat /proc/meminfo | tee -a "$OUT/memory.txt"

echo "===== VMSTAT =====" | tee "$OUT/vmstat.txt"
vmstat 1 5 | tee -a "$OUT/vmstat.txt"

echo "===== DISK =====" | tee "$OUT/disk.txt"
df -h | tee -a "$OUT/disk.txt"
echo | tee -a "$OUT/disk.txt"
df -i | tee -a "$OUT/disk.txt"
echo | tee -a "$OUT/disk.txt"
lsblk | tee -a "$OUT/disk.txt"

echo "===== NETWORK =====" | tee "$OUT/network.txt"
ip -br addr | tee -a "$OUT/network.txt"
echo | tee -a "$OUT/network.txt"
ip route | tee -a "$OUT/network.txt"
echo | tee -a "$OUT/network.txt"
ip -s link | tee -a "$OUT/network.txt"
echo | tee -a "$OUT/network.txt"
ss -s | tee -a "$OUT/network.txt"

echo "===== D STATE PROCESSES =====" | tee "$OUT/blocked-processes.txt"
ps -eo pid,ppid,user,stat,wchan:32,cmd \
    | awk '$4 ~ /^D/ {print}' \
    | tee -a "$OUT/blocked-processes.txt"

echo "===== INTERRUPTS =====" | tee "$OUT/interrupts.txt"
cat /proc/interrupts | tee "$OUT/interrupts.txt"

echo "===== SOFTIRQS =====" | tee "$OUT/softirqs.txt"
cat /proc/softirqs | tee "$OUT/softirqs.txt"

echo "===== KERNEL MESSAGES =====" | tee "$OUT/kernel.txt"
dmesg -T 2>/dev/null \
    | tail -200 \
    | tee "$OUT/kernel.txt"

echo "===== OOM EVENTS =====" | tee "$OUT/oom.txt"
dmesg -T 2>/dev/null \
    | grep -iE 'oom|out of memory|killed process' \
    | tee "$OUT/oom.txt"

echo "===== SWAP =====" | tee "$OUT/swap.txt"
swapon --show | tee "$OUT/swap.txt"

echo "===== SYSTEMD FAILED SERVICES =====" | tee "$OUT/services.txt"
systemctl --failed 2>/dev/null | tee "$OUT/services.txt"

echo
echo "=========================================="
echo "Diagnostics completed."
echo "Results saved in: $OUT"
echo "=========================================="
