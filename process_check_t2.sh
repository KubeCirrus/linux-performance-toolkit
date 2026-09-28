#!/usr/bin/env bash

section() {
  printf '\n===== %s =====\n' "$1"
}

if [[ $EUID -ne 0 ]]; then
  echo "Please run as root: sudo $0" >&2
  exit 1
fi

missing=0
for pair in "ps:procps" "pidstat:sysstat" "ss:iproute2"; do
  cmd=${pair%%:*}
  pkg=${pair##*:}
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing command: $cmd (install package: $pkg)" >&2
    missing=1
  fi
done
if [[ $missing -eq 1 ]]; then
  exit 1
fi

section "System"
echo "CPU cores: $(nproc)"
uptime
free -h

section "CPU"
ps aux --sort=-%cpu | head -n 16

section "Memory"
ps aux --sort=-%mem | head -n 16

section "Stuck in D state"
ps -eo pid,state,comm,wchan:32 | awk 'NR == 1 || $2 == "D"'

section "Disk I/O"
pidstat -d 1 2

section "Network"
ss -tunap

