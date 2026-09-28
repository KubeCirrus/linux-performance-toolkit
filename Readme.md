# Linux Performance Diagnostic Tool

A lightweight, read-only Bash-based Linux performance diagnostic tool for quickly identifying common **CPU, memory, disk, network, process, and kernel** health issues.

The tool is designed for SREs, DevOps engineers, system administrators, and developers who need a quick performance snapshot without installing additional monitoring agents or packages.

---

## Features

* CPU utilization and load analysis
* CPU I/O wait detection
* Memory utilization analysis
* Swap usage detection
* Filesystem capacity checks
* Network packet error/drop detection
* Top CPU-consuming processes
* Top memory-consuming processes
* Detection of processes in `D` state
* Per-process diagnostic information
* Kernel and system information
* Recent kernel messages
* OOM detection
* Interrupt and softirq information
* Detailed diagnostic reports saved to disk
* Compact terminal output by default
* Optional detailed terminal output
* Target individual diagnostic modules
* Read-only operation
* No package installation
* No system configuration changes

---

## Requirements

The script is designed to work with standard Linux utilities.

Common commands used include:

```text
bash
awk
cat
date
df
free
hostname
ip
lsblk
lscpu
nproc
ps
ss
uname
vmstat
```

Some commands may not be available on minimal Linux installations. The script attempts to handle missing commands gracefully.

### Bash version

Recommended:

```bash
bash --version
```

Bash 4+ is recommended.

---

## Installation

Clone the repository:

```bash
git clone https://github.com/<your-user>/linux-performance-toolkit.git
cd linux-performance-toolkit
```

Make the script executable:

```bash
chmod +x linux-performance-toolkit.sh
```

Run it:

```bash
./linux-performance-toolkit.sh
```

You can also execute it directly through Bash:

```bash
bash linux-performance-toolkit.sh
```

---

# Basic Usage

Running the script without arguments performs a complete diagnostic:

```bash
./linux-performance-toolkit.sh
```

The default output is intentionally compact.

Example:

```text
LINUX PERFORMANCE HEALTH
────────────────────────────────────────────
Host    : cloud-badger
Time    : 2026-09-28 22:36:57
Kernel  : 6.18.33.2-microsoft-standard-WSL2
Output  : ./perf-debug-cloud-badger-20260928-223657

Modules:
  CPU       enabled
  Memory    enabled
  Disk      enabled
  Network   enabled
  Process   enabled
  Kernel    enabled

ISSUES
────────────────────────────────────────────
No major issues detected by the basic checks.

Detailed reports:
  ./perf-debug-cloud-badger-20260928-223657
```

Detailed information is written to the output directory instead of flooding the terminal.

---

# Diagnostic Modules

## CPU

Run CPU diagnostics:

```bash
./linux-performance-toolkit.sh --cpu
```

The CPU module checks:

* CPU utilization
* System load
* Number of CPUs
* I/O wait
* Top CPU-consuming processes
* CPU threads
* CPU information
* VM statistics

Detailed report:

```text
perf-debug-<hostname>-<timestamp>/cpu.txt
```

Show details directly in the terminal:

```bash
./linux-performance-toolkit.sh --cpu --details
```

### CPU recommendations

The tool reports warnings when CPU utilization reaches approximately:

```text
80%  → WARNING
90%  → CRITICAL
```

High I/O wait is also reported because high I/O wait can indicate storage or filesystem latency rather than CPU saturation.

---

# Memory

Run memory diagnostics:

```bash
./linux-performance-toolkit.sh --memory
```

The module checks:

* Total memory
* Available memory
* Memory utilization
* Swap usage
* `/proc/meminfo`
* Top memory-consuming processes
* VM statistics

Detailed report:

```text
perf-debug-<hostname>-<timestamp>/memory.txt
```

Show details:

```bash
./linux-performance-toolkit.sh --memory --details
```

### Memory thresholds

Approximate thresholds:

```text
85% → WARNING
95% → CRITICAL
```

Swap usage is also reported as a potential indicator of memory pressure.

> Note: Swap being used does not automatically mean the system is unhealthy. Check swap activity and memory pressure before concluding that memory is exhausted.

---

# Disk

Run disk diagnostics:

```bash
./linux-performance-toolkit.sh --disk
```

The disk module checks:

* Filesystem utilization
* Inode utilization
* Block devices
* `/proc/diskstats`
* VM statistics

Detailed report:

```text
perf-debug-<hostname>-<timestamp>/disk.txt
```

Show details:

```bash
./linux-performance-toolkit.sh --disk --details
```

### Filesystem thresholds

```text
85% → WARNING
95% → CRITICAL
```

Example:

```text
[WARN] Filesystem /var is above 85%
```

The detailed report can then be used to investigate disk usage.

---

# Network

Run network diagnostics:

```bash
./linux-performance-toolkit.sh --network
```

The network module checks:

* Network interfaces
* RX/TX statistics
* Packet errors
* Packet drops
* Routing table
* Socket statistics
* Listening sockets
* TCP connections
* `/proc/net/snmp`
* `/proc/net/netstat`

Detailed report:

```text
perf-debug-<hostname>-<timestamp>/network.txt
```

Show details:

```bash
./linux-performance-toolkit.sh --network --details
```

Example:

```text
NETWORK
────────────────────────────────────────────
[WARN] Errors: 0    Drops: 34
```

Network drops can have many causes, including:

* NIC/driver problems
* Network congestion
* Queue overflow
* Host resource pressure
* Virtual networking issues
* Hypervisor/network configuration

The tool reports the symptom; further investigation is required to determine the root cause.

---

# Process Diagnostics

Run process diagnostics:

```bash
./linux-performance-toolkit.sh --process
```

The module collects:

* Top CPU processes
* Top memory processes
* Process state
* Processes in `D` state
* Process runtime information

Detailed report:

```text
perf-debug-<hostname>-<timestamp>/process.txt
```

---

# Inspect a Specific Process

A specific process can be investigated using `DEBUG_PID`.

For example:

```bash
DEBUG_PID=1234 ./linux-performance-toolkit.sh --process
```

The tool collects information from:

```text
/proc/<PID>/status
/proc/<PID>/io
/proc/<PID>/sched
/proc/<PID>/wchan
/proc/<PID>/limits
```

The output is saved as:

```text
perf-debug-<hostname>-<timestamp>/pid-1234.txt
```

For terminal output:

```bash
DEBUG_PID=1234 ./linux-performance-toolkit.sh --process --details
```

---

# Kernel Diagnostics

Run kernel diagnostics:

```bash
./linux-performance-toolkit.sh --kernel
```

The module collects:

* Kernel version
* `uname` information
* Recent `dmesg` output
* Interrupt information
* SoftIRQ information
* OOM-related kernel messages

Detailed report:

```text
perf-debug-<hostname>-<timestamp>/kernel.txt
```

Show directly:

```bash
./linux-performance-toolkit.sh --kernel --details
```

> Some kernel information may require root privileges depending on the Linux distribution and security configuration.

---

# Run Everything

Explicitly run all modules:

```bash
./linux-performance-toolkit.sh --all
```

With detailed terminal output:

```bash
./linux-performance-toolkit.sh --all --details
```

---

# Combine Modules

Multiple modules can be selected together.

For example:

```bash
./linux-performance-toolkit.sh --cpu --memory
```

CPU + disk:

```bash
./linux-performance-toolkit.sh --cpu --disk
```

Network + process:

```bash
./linux-performance-toolkit.sh --network --process
```

CPU + memory + network:

```bash
./linux-performance-toolkit.sh --cpu --memory --network
```

---

# Command Reference

| Command           | Description                 |
| ----------------- | --------------------------- |
| `./linux-performance-toolkit.sh`  | Run complete diagnostic     |
| `--help`          | Display help                |
| `--cpu`           | CPU diagnostics             |
| `--memory`        | Memory diagnostics          |
| `--disk`          | Disk/filesystem diagnostics |
| `--network`       | Network diagnostics         |
| `--process`       | Process diagnostics         |
| `--kernel`        | Kernel diagnostics          |
| `--all`           | Run all modules             |
| `--details`       | Display detailed output     |
| `DEBUG_PID=<PID>` | Inspect a specific process  |

---

# Output Structure

Every execution creates a timestamped directory.

Example:

```text
perf-debug-cloud-badger-20260928-223657/
├── summary.txt
├── recommendations.txt
├── cpu.txt
├── memory.txt
├── disk.txt
├── network.txt
├── process.txt
├── kernel.txt
└── pid-<PID>.txt
```

Not every file will necessarily be present. Files are generated according to the modules executed.

---

# Recommendations

The tool includes a basic recommendation engine.

For example, if CPU usage is high:

```text
→ CPU utilization is above 80%.
  Check the top CPU consumers with:
  ./linux-performance-toolkit.sh --cpu --details
```

If memory usage is high:

```text
→ Memory usage is above 85%.
  Review top memory consumers with:
  ./linux-performance-toolkit.sh --memory --details
```

If filesystem usage is high:

```text
→ Filesystem /var is above 85%.
  Check disk usage with:
  ./linux-performance-toolkit.sh --disk --details
```

Recommendations are intended as troubleshooting starting points, not automatic root-cause analysis.

---

# Read-Only Design

The diagnostic tool is intentionally designed to be non-invasive.

It:

* Does not install packages
* Does not modify system configuration
* Does not restart services
* Does not kill processes
* Does not modify network configuration
* Does not modify filesystem contents
* Does not change kernel parameters

The tool primarily reads information from:

```text
/proc
/sys
```

and uses standard Linux diagnostic utilities.

---

# Running on Production Systems

The tool is designed primarily for read-only troubleshooting.

Nevertheless, some commands can generate significant output, particularly:

```bash
ps
ss
dmesg
/proc/interrupts
/proc/softirqs
/proc/net/*
```

For large production systems, prefer:

```bash
./linux-performance-toolkit.sh
```

instead of:

```bash
./linux-performance-toolkit.sh --all --details
```

The default mode keeps terminal output compact while saving detailed evidence to disk.

---

# Troubleshooting

## Permission denied

Try:

```bash
chmod +x linux-performance-toolkit.sh
```

or:

```bash
bash linux-performance-toolkit.sh
```

Some kernel information may require:

```bash
sudo ./linux-performance-toolkit.sh --kernel
```

---

## Command not found

Check whether a command exists:

```bash
command -v vmstat
command -v ss
command -v ip
command -v lscpu
```

Minimal Linux distributions may not include every utility used by the script.

---

## Check Bash syntax

Before running changes to the script:

```bash
bash -n linux-performance-toolkit.sh
```

This performs a syntax check without executing the script.

---

## ShellCheck

If ShellCheck is installed:

```bash
shellcheck linux-performance-toolkit.sh
```

ShellCheck is highly recommended when modifying the script.

---

# Development Workflow

Recommended workflow when modifying the script:

```bash
# Edit
code linux-performance-toolkit.sh

# Syntax check
bash -n linux-performance-toolkit.sh

# Static analysis
shellcheck linux-performance-toolkit.sh

# Run
./linux-performance-toolkit.sh

# Review changes
git diff

# Check Git status
git status

# Stage
git add linux-performance-toolkit.sh

# Commit
git commit -m "Improve CPU diagnostics"

# Push
git push
```

---

# Example Troubleshooting Workflow

A useful workflow when investigating a server problem is:

### 1. Get an overall snapshot

```bash
./linux-performance-toolkit.sh
```

### 2. If CPU is reported as high

```bash
./linux-performance-toolkit.sh --cpu --details
```

### 3. If memory is reported as high

```bash
./linux-performance-toolkit.sh --memory --details
```

### 4. If disk is reported as high

```bash
./linux-performance-toolkit.sh --disk --details
```

### 5. If network drops/errors are detected

```bash
./linux-performance-toolkit.sh --network --details
```

### 6. Find a suspicious process

```bash
ps aux --sort=-%cpu | head
```

Then:

```bash
DEBUG_PID=<PID> ./linux-performance-toolkit.sh --process --details
```

### 7. Check kernel-level problems

```bash
./linux-performance-toolkit.sh --kernel --details
```

This creates a troubleshooting trail under the timestamped report directory.

---

# Roadmap

Potential future improvements include:

* [ ] Live `--watch` mode
* [ ] CPU usage sampling from `/proc/stat`
* [ ] Network RX/TX throughput
* [ ] Disk I/O throughput
* [ ] TCP retransmission detection
* [ ] Context-switch monitoring
* [ ] Interrupt-rate monitoring
* [ ] CPU steal-time detection
* [ ] cgroup CPU throttling detection
* [ ] cgroup memory pressure detection
* [ ] OOM event detection improvements
* [ ] Per-process I/O monitoring
* [ ] Per-process thread monitoring
* [ ] JSON output
* [ ] CSV output
* [ ] Machine-readable exit codes
* [ ] Configurable warning thresholds
* [ ] Historical comparison/baseline mode
* [ ] Kubernetes/container-aware diagnostics

---

# Why This Tool?

Traditional troubleshooting often requires running several commands:

```bash
top
free -h
vmstat
df -h
iostat
ss -s
ps
dmesg
```

This tool provides a single entry point:

```bash
./linux-performance-toolkit.sh
```

It gives a compact health summary first and preserves detailed evidence separately for deeper investigation.

The goal is not to replace tools such as `top`, `vmstat`, `iostat`, `sar`, `perf`, or full observability platforms.

Instead, it provides a lightweight **first-response diagnostic layer** for Linux performance troubleshooting.

---

# License

Choose a license appropriate for your repository.

For an open-source project, MIT is a simple option.

Example:

```text
MIT License
Copyright (c) 2026 Bala Vighnesh R
```

---

# Author

**Bala Vighnesh R**

Cloud / Site Reliability Engineering
Kubernetes | Linux | Cloud Infrastructure | Observability | Automation

---

## Contributing

Contributions, bug fixes, and improvements are welcome.

Before submitting changes:

```bash
bash -n linux-performance-toolkit.sh
```

and, if available:

```bash
shellcheck linux-performance-toolkit.sh
```

Please include a clear commit message describing the change.

Example:

```text
Add network packet drop diagnostics
```

or:

```text
Improve memory pressure detection
```
