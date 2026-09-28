#!/usr/bin/env bash

section() {
  printf '\n===== %s =====\n' "$1"
}

section "CPU"
ps aux --sort=-%cpu | head -n 16

section "Memory"
ps aux --sort=-%mem | head -n 16

section "Disk I/O"
pidstat -d 1 2

section "Network"
ss -tunap
