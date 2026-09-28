#!/usr/bin/env bash
#
# perf-diagnose.sh v2 - read-only Linux performance triage
#
# Default behavior
#   * Prints a short dashboard: one status row each for CPU, MEMORY, DISK, NETWORK
#     (and SYSTEM), followed by only the CRITICAL/WARNING issues with a suggested fix.
#   * Writes the full detail (every command's output, raw samples) to a report
#     directory so the terminal stays clean.
#
# Useful modes
#   -v          stream the full detail to the terminal as well
#   cpu disk    run only the named modules (cpu mem disk net sys)
#   -j          print machine-readable JSON instead of the dashboard
#   -w 10       watch mode: refresh the dashboard every 10 seconds
#   -H host     add a ping/DNS probe to the network module
#
# Safety: strictly read-only. The one intrusive option is -S (strace), opt-in.
#
# Exit codes: 0 = healthy, 1 = warnings, 2 = critical findings, 64 = bad usage.
#
# Note on `set -e`: deliberately NOT used. A diagnostic tool must keep going when
# one probe fails (missing tool, permission denied). Failures are handled
# explicitly and reported instead.

set -uo pipefail
export LC_ALL=C
umask 077

readonly VERSION="2.0.0"
readonly PROG="${0##*/}"
readonly ALL_MODULES="cpu mem disk net sys"

# ----------------------------------------------------------------------------
# Options (see -h)
# ----------------------------------------------------------------------------
DURATION=5
TOP_N=10
OUTDIR=""
VERBOSE=0
JSON=0
WATCH=0
MAKE_TAR=0
DO_STRACE=0
USE_COLOR=1
PROBE_HOST=""
MODULES=""
TARGET_PIDS=()
SAMPLE_PIDS=()

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
die() { echo "$PROG: $*" >&2; exit 64; }
have() { command -v "$1" >/dev/null 2>&1; }
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
fgt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }   # a > b (float)
ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }   # a >= b (float)
wants() { [[ " $MODULES " == *" $1 "* ]]; }
section() { printf '\n################ %s ################\n' "$*"; }

human_kb() { awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.1fG", k / 1048576; else printf "%.0fM", k / 1024 }'; }
human_bps() {   # bytes/sec -> human
    awk -v b="$1" 'BEGIN { if (b >= 1048576) printf "%.1f MB/s", b / 1048576; else printf "%.0f KB/s", b / 1024 }'
}

usage() {
    cat <<EOF
$PROG v$VERSION - read-only Linux performance triage

Usage: $PROG [options] [module ...]

By default: prints a short dashboard (CPU / MEMORY / DISK / NETWORK / SYSTEM)
with only critical and warning issues plus suggested fixes. Full detail goes to
a report file (path shown at the end).

Modules (positional, or comma-separated with -m):
  cpu    load, utilisation, iowait, steal, per-core hot spots, throttling
  mem    available memory, swap activity, OOM kills, top memory user
  disk   space, inodes, latency/utilisation, D-state tasks, read-only mounts
  net    throughput vs link speed, errors/drops, TCP retransmits, conntrack
  sys    processes, zombies, file handles, failed services, kernel warnings
  all    everything (default)

Options:
  -m LIST      Modules to run, e.g. -m cpu,disk (same as positional words)
  -v           Verbose: also stream the full details to the terminal
  -j           Print JSON summary to stdout instead of the dashboard
  -w SECONDS   Watch mode: rerun and refresh the dashboard until Ctrl-C
  -d SECONDS   Live sampling duration (default: $DURATION)
  -H HOST      Network probe: DNS lookup time + ping loss/latency to HOST
  -p PID       Deep-dive into this process (repeatable; goes to the report)
  -S           Also run 'strace -c' on each -p PID (adds overhead)
  -n N         Rows in top-process tables (default: $TOP_N)
  -o DIR       Report directory (default: ./perf-report-<host>-<timestamp>)
  -t           Also create a .tar.gz of the report directory
  -c           Disable colors (also honors NO_COLOR and non-TTY output)
  -h           Show this help
  -V           Show version

Examples:
  $PROG                       # dashboard for everything, detail in a file
  $PROG cpu mem               # only CPU and memory
  $PROG -v disk               # disk checks, full detail printed live
  sudo $PROG -d 30 -t         # 30s sample, run as root, make a tarball
  $PROG -H 8.8.8.8 net        # network checks plus a ping/DNS probe
  $PROG -w 10 cpu net         # live dashboard, refreshed every 10s
  $PROG -j | jq .overall      # use from scripts

Thresholds can be tuned with environment variables, e.g.
  T_CPU_WARN=60 T_MEM_WARN=30 $PROG
  Defaults: T_LOAD_WARN=$T_LOAD_WARN T_LOAD_CRIT=$T_LOAD_CRIT (x cores), T_CPU_WARN=$T_CPU_WARN T_CPU_CRIT=$T_CPU_CRIT,
  T_IOWAIT_WARN=$T_IOWAIT_WARN T_IOWAIT_CRIT=$T_IOWAIT_CRIT, T_STEAL_WARN=$T_STEAL_WARN T_STEAL_CRIT=$T_STEAL_CRIT,
  T_MEM_WARN=$T_MEM_WARN T_MEM_CRIT=$T_MEM_CRIT (% available below), T_SWAP_WARN=$T_SWAP_WARN,
  T_DISK_WARN=$T_DISK_WARN T_DISK_CRIT=$T_DISK_CRIT (% full), T_DISK_UTIL_WARN=$T_DISK_UTIL_WARN T_DISK_UTIL_CRIT=$T_DISK_UTIL_CRIT,
  T_AWAIT_WARN=$T_AWAIT_WARN T_AWAIT_CRIT=$T_AWAIT_CRIT (ms), T_NET_UTIL_WARN=$T_NET_UTIL_WARN T_NET_UTIL_CRIT=$T_NET_UTIL_CRIT,
  T_RETRANS_WARN=$T_RETRANS_WARN T_RETRANS_CRIT=$T_RETRANS_CRIT, T_PSI_WARN=$T_PSI_WARN T_PSI_CRIT=$T_PSI_CRIT

Run as root for complete data (dmesg, per-process I/O, kernel stacks).
Exit codes: 0 healthy, 1 warnings, 2 critical, 64 usage error.
EOF
}

# ----------------------------------------------------------------------------
# Thresholds (override via environment)
# ----------------------------------------------------------------------------
: "${T_LOAD_WARN:=1}" "${T_LOAD_CRIT:=2}"
: "${T_CPU_WARN:=75}" "${T_CPU_CRIT:=90}"
: "${T_IOWAIT_WARN:=10}" "${T_IOWAIT_CRIT:=20}"
: "${T_STEAL_WARN:=3}" "${T_STEAL_CRIT:=10}"
: "${T_MEM_WARN:=20}" "${T_MEM_CRIT:=10}" "${T_SWAP_WARN:=50}"
: "${T_DISK_WARN:=90}" "${T_DISK_CRIT:=95}"
: "${T_DISK_UTIL_WARN:=80}" "${T_DISK_UTIL_CRIT:=95}"
: "${T_AWAIT_WARN:=50}" "${T_AWAIT_CRIT:=200}"
: "${T_NET_UTIL_WARN:=70}" "${T_NET_UTIL_CRIT:=90}"
: "${T_RETRANS_WARN:=2}" "${T_RETRANS_CRIT:=5}"
: "${T_PSI_WARN:=10}" "${T_PSI_CRIT:=25}"
: "${T_PING_MS_WARN:=100}" "${T_DNS_MS_WARN:=500}"
for _v in T_LOAD_WARN T_LOAD_CRIT T_CPU_WARN T_CPU_CRIT T_IOWAIT_WARN T_IOWAIT_CRIT \
    T_STEAL_WARN T_STEAL_CRIT T_MEM_WARN T_MEM_CRIT T_SWAP_WARN T_DISK_WARN T_DISK_CRIT \
    T_DISK_UTIL_WARN T_DISK_UTIL_CRIT T_AWAIT_WARN T_AWAIT_CRIT T_NET_UTIL_WARN \
    T_NET_UTIL_CRIT T_RETRANS_WARN T_RETRANS_CRIT T_PSI_WARN T_PSI_CRIT T_PING_MS_WARN T_DNS_MS_WARN; do
    [[ ${!_v} =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "threshold $_v must be a number (got '${!_v}')"
done
unset _v

# ----------------------------------------------------------------------------
# Argument parsing (options and module words may be mixed in any order)
# ----------------------------------------------------------------------------
norm_module() {
    case "${1,,}" in
        cpu) echo cpu ;;
        mem | memory | ram) echo mem ;;
        disk | io | storage) echo disk ;;
        net | network) echo net ;;
        sys | system | proc | processes) echo sys ;;
        all) echo all ;;
        *) return 1 ;;
    esac
}

add_modules() {   # add_modules "cpu,mem"
    local IFS=',' item m
    for item in $1; do
        [[ -n $item ]] || continue
        m=$(norm_module "$item") || die "unknown module '$item' (valid: cpu mem disk net sys all)"
        if [[ $m == all ]]; then MODULES="$ALL_MODULES"; else MODULES+=" $m"; fi
    done
}

((BASH_VERSINFO[0] >= 4)) || die "bash 4 or newer is required"

OPTSTR=':d:o:p:n:m:H:w:vjStcqhV'
while (($#)); do
    OPTIND=1
    while getopts "$OPTSTR" opt; do
        case $opt in
            d) is_uint "$OPTARG" && ((10#$OPTARG >= 1)) || die "-d needs a positive integer"
               DURATION=$((10#$OPTARG)) ;;
            o) OUTDIR=$OPTARG ;;
            p) is_uint "$OPTARG" || die "-p needs a numeric PID"
               TARGET_PIDS+=("$((10#$OPTARG))") ;;
            n) is_uint "$OPTARG" && ((10#$OPTARG >= 1)) || die "-n needs a positive integer"
               TOP_N=$((10#$OPTARG)) ;;
            m) add_modules "$OPTARG" ;;
            H) [[ $OPTARG =~ ^[A-Za-z0-9._:-]+$ ]] || die "-H needs a hostname or IP"
               PROBE_HOST=$OPTARG ;;
            w) is_uint "$OPTARG" && ((10#$OPTARG >= 1)) || die "-w needs a positive integer"
               WATCH=$((10#$OPTARG)) ;;
            v) VERBOSE=1 ;;
            j) JSON=1 ;;
            S) DO_STRACE=1 ;;
            t) MAKE_TAR=1 ;;
            c) USE_COLOR=0 ;;
            q) ;;   # accepted for backward compatibility (quiet is now the default)
            h) usage; exit 0 ;;
            V) echo "$PROG $VERSION"; exit 0 ;;
            :) die "option -$OPTARG requires an argument" ;;
            \?) die "unknown option -$OPTARG (see -h)" ;;
        esac
    done
    shift $((OPTIND - 1))
    if (($#)); then
        add_modules "$1"
        shift
    fi
done

# Canonical, de-duplicated module order (default: all)
[[ -n ${MODULES// /} ]] || MODULES="$ALL_MODULES"
_sel=" $MODULES "
MODULES=""
for _m in $ALL_MODULES; do [[ $_sel == *" $_m "* ]] && MODULES+="$_m "; done
MODULES=${MODULES% }
unset _sel _m
((VERBOSE && JSON)) && die "-v and -j cannot be combined (JSON must be the only stdout)"

# ----------------------------------------------------------------------------
# Preflight and setup
# ----------------------------------------------------------------------------
[[ $(uname -s) == Linux ]] || die "this script supports Linux only"
[[ -r /proc/loadavg && -r /proc/meminfo && -r /proc/stat ]] || die "/proc is not available"
[[ -t 1 && -z ${NO_COLOR:-} ]] || USE_COLOR=0
((JSON)) && USE_COLOR=0

TERM_W=$(tput cols 2>/dev/null || echo 100)
is_uint "$TERM_W" || TERM_W=100
((TERM_W < 80)) && TERM_W=80
((TERM_W > 120)) && TERM_W=120

HOST=$(hostname 2>/dev/null || echo unknown)
TS=$(date +%Y%m%d-%H%M%S)
OUTDIR=${OUTDIR:-"./perf-report-${HOST}-${TS}"}
mkdir -p "$OUTDIR/raw" || die "cannot create output directory: $OUTDIR"
REPORT="$OUTDIR/report.txt"
FINDINGS="$OUTDIR/findings.tsv"
WORK="$OUTDIR/.work"
CORES=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
HZ=$(getconf CLK_TCK 2>/dev/null || echo 100)
KLOG_LOADED=0
[[ -w $OUTDIR ]] || die "output directory is not writable: $OUTDIR"

# ----------------------------------------------------------------------------
# Cleanup / signals
# ----------------------------------------------------------------------------
status_code() {
    [[ -r $FINDINGS ]] || { echo 0; return; }
    if grep -q '^CRIT'$'\t' "$FINDINGS"; then echo 2
    elif grep -q '^WARN'$'\t' "$FINDINGS"; then echo 1
    else echo 0; fi
}

cleanup() {
    local p
    for p in "${SAMPLE_PIDS[@]:-}"; do
        [[ -n $p ]] && kill "$p" 2>/dev/null
    done
    rm -rf "$WORK" 2>/dev/null
    return 0
}
trap cleanup EXIT
trap 'echo >&2; exit "$(status_code)"' INT TERM

# ----------------------------------------------------------------------------
# Recording results
#   finding SEV MODULE "what is wrong" "how to fix"      (SEV: CRIT|WARN|INFO)
#   metric  MODULE "one line shown on the dashboard"
# ----------------------------------------------------------------------------
finding() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$FINDINGS"; }
metric() { printf '%s\n' "$2" >>"$WORK/metrics.$1"; }

# run TIMEOUT cmd args... : run with timeout; never abort the script
run() {
    local t=$1 rc
    shift
    printf '\n$ %s\n' "$*"
    if ! have "$1"; then
        echo "[skip] '$1' not installed"
        return 0
    fi
    if have timeout; then timeout "$t" "$@" 2>&1; else "$@" 2>&1; fi
    rc=$?
    if ((rc == 124)); then echo "[warn] timed out after ${t}s"
    elif ((rc != 0)); then echo "[warn] exit status $rc"; fi
    return 0
}

# run_sh TIMEOUT "pipeline" : same, for shell pipelines (first word must be a command)
run_sh() {
    local t=$1 s=$2 rc
    printf '\n$ %s\n' "$s"
    if ! have "${s%% *}"; then
        echo "[skip] '${s%% *}' not installed"
        return 0
    fi
    if have timeout; then timeout "$t" bash -c "$s" 2>&1; else bash -c "$s" 2>&1; fi
    rc=$?
    ((rc == 124)) && echo "[warn] timed out after ${t}s"
    return 0
}

# ----------------------------------------------------------------------------
# Sampling: take counter snapshots before/after a window; run tool samplers
# ----------------------------------------------------------------------------
bg_sample() {   # bg_sample NAME cmd args...
    local name=$1
    shift
    if ! have "$1"; then
        echo "[skip] $1 not installed" >"$OUTDIR/raw/$name.txt"
        return 0
    fi
    "$@" >"$OUTDIR/raw/$name.txt" 2>&1 &
    SAMPLE_PIDS+=("$!")
}

show_raw() {   # print a raw sampler file once per run
    local f="$OUTDIR/raw/$1.txt"
    [[ -r $f && ! -e $WORK/shown.$1 ]] || return 0
    : >"$WORK/shown.$1"
    printf '\n--- %s (%ss sample) ---\n' "$1" "$DURATION"
    cat "$f"
}

snap_pcpu() {   # "pid cpu_ticks" for every process
    grep -H '' /proc/[0-9]*/stat 2>/dev/null | awk '{
        line = $0; pid = $0
        sub(/^\/proc\/[0-9]+\/stat:/, "", line)
        sub(/^\/proc\//, "", pid); sub(/\/.*/, "", pid)
        sub(/^[0-9]+ \(.*\) /, "", line)
        if (split(line, f, " ") >= 13) print pid, f[12] + f[13]
    }'
}

take_snapshot() {
    local n=$1
    grep '^cpu' /proc/stat >"$WORK/stat.$n" 2>/dev/null
    grep -E '^(pswpin|pswpout|pgmajfault) ' /proc/vmstat >"$WORK/vmstat.$n" 2>/dev/null
    awk '{ print $3, $4, $7, $8, $11, $13 }' /proc/diskstats >"$WORK/disk.$n" 2>/dev/null
    sed 's/:/ /' /proc/net/dev 2>/dev/null | tail -n +3 >"$WORK/netdev.$n"
    cat /proc/net/snmp >"$WORK/snmp.$n" 2>/dev/null
    cat /proc/net/netstat >"$WORK/netstat.$n" 2>/dev/null
    local r
    for r in cpu memory io; do
        [[ -r /proc/pressure/$r ]] && awk '/^some/ { split($5, a, "="); print a[2] }' "/proc/pressure/$r" >"$WORK/psi-$r.$n" 2>/dev/null
    done
    wants cpu && snap_pcpu >"$WORK/pcpu.$n"
    wants disk && grep -HE '^(read|write)_bytes:' /proc/[0-9]*/io >"$WORK/pio.$n" 2>/dev/null
    return 0
}

collect_samples() {
    section "LIVE SAMPLING (${DURATION}s)"
    if ((!VERBOSE)) && [[ -t 2 ]]; then
        printf 'Sampling for %ss ... ' "$DURATION" >&2
    fi
    if wants cpu || wants mem; then bg_sample vmstat vmstat 1 "$DURATION"; fi
    wants cpu && bg_sample mpstat mpstat -P ALL 1 "$DURATION"
    wants disk && bg_sample iostat iostat -xz 1 "$DURATION"
    if wants cpu || wants mem || wants disk; then bg_sample pidstat pidstat -u -r -d 1 "$DURATION"; fi
    wants net && bg_sample sar-net sar -n DEV 1 "$DURATION"

    take_snapshot 1
    sleep "$DURATION"
    take_snapshot 2

    if ((${#SAMPLE_PIDS[@]})); then wait "${SAMPLE_PIDS[@]}" 2>/dev/null; fi
    SAMPLE_PIDS=()
    echo "Sampling finished. Raw tool output is saved in $OUTDIR/raw/"
    if ((!VERBOSE)) && [[ -t 2 ]]; then printf '\r\033[K' >&2; fi
}

snap_delta() {   # snap_delta PREFIX KEY : delta of "KEY value" between snapshots 1 and 2
    local a b
    a=$(awk -v k="$2" '$1 == k { print $2 }' "$WORK/$1.1" 2>/dev/null)
    b=$(awk -v k="$2" '$1 == k { print $2 }' "$WORK/$1.2" 2>/dev/null)
    echo $((${b:-0} - ${a:-0}))
}

proc_net_counter() {   # proc_net_counter FILE PROTO FIELD  (snmp/netstat header+value pairs)
    awk -v p="$2:" -v f="$3" '$1 == p {
        if (!seen) { for (i = 2; i <= NF; i++) n[$i] = i; seen = 1 }
        else { if (n[f]) print $(n[f]); exit }
    }' "$1" 2>/dev/null
}

net_delta() {   # net_delta snmp|netstat PROTO FIELD
    local a b
    a=$(proc_net_counter "$WORK/$1.1" "$2" "$3")
    b=$(proc_net_counter "$WORK/$1.2" "$2" "$3")
    echo $((${b:-0} - ${a:-0}))
}

proc_name() { cat "/proc/$1/comm" 2>/dev/null || echo "?"; }

top_cpu_proc() {   # prints: "name (pid N) P%"
    [[ -s $WORK/pcpu.1 && -s $WORK/pcpu.2 ]] || return 0
    local res pid pct
    res=$(awk -v hz="$HZ" -v d="$DURATION" '
        NR == FNR { a[$1] = $2; next }
        ($1 in a) { dt = $2 - a[$1]; if (dt > best) { best = dt; bp = $1 } }
        END { if (bp != "") printf "%s %.0f\n", bp, 100 * best / hz / d }' "$WORK/pcpu.1" "$WORK/pcpu.2")
    [[ -n $res ]] || return 0
    read -r pid pct <<<"$res"
    ((pct >= 1)) && echo "$(proc_name "$pid") (pid $pid) ${pct}%"
    return 0
}

top_io_proc() {    # prints: "name (pid N) X MB/s"  (needs root for other users' processes)
    [[ -s $WORK/pio.1 && -s $WORK/pio.2 ]] || return 0
    local res pid bps
    res=$(awk -v f1="$WORK/pio.1" -v d="$DURATION" '
        { pid = $0; sub(/^\/proc\//, "", pid); sub(/\/.*/, "", pid); v = $NF + 0
          if (FILENAME == f1) a[pid] += v; else b[pid] += v }
        END { for (p in b) if (p in a) { x = b[p] - a[p]; if (x > best) { best = x; bp = p } }
              if (bp != "") printf "%s %.0f\n", bp, best / d }' "$WORK/pio.1" "$WORK/pio.2")
    [[ -n $res ]] || return 0
    read -r pid bps <<<"$res"
    ((bps >= 10240)) && echo "$(proc_name "$pid") (pid $pid) $(human_bps "$bps")"
    return 0
}

load_klog() {   # dump kernel log once per run to $WORK/kernel.log
    ((KLOG_LOADED)) && return 0
    KLOG_LOADED=1
    KLOG="$WORK/kernel.log"
    if dmesg -T >"$KLOG" 2>/dev/null && [[ -s $KLOG ]]; then
        :
    elif have journalctl && journalctl -k --no-pager -q >"$KLOG" 2>/dev/null && [[ -s $KLOG ]]; then
        :
    else
        : >"$KLOG"
        finding INFO sys "Kernel log is not readable, so OOM/disk-error checks were skipped" "Re-run with sudo (dmesg is restricted on many systems)"
    fi
}

psi_check() {   # psi_check RESOURCE MODULE "fix text"
    # Uses the stall-time counter delta over the sample window when available
    # (precise), otherwise falls back to the kernel's 10-second average.
    local r=$1 m=$2 fix=$3 f=/proc/pressure/$1 v when
    [[ -r $f ]] || return 0
    if [[ -s $WORK/psi-$r.1 && -s $WORK/psi-$r.2 ]]; then
        v=$(awk -v d="$DURATION" 'NR == FNR { a = $1; next } { printf "%.1f", 100 * ($1 - a) / (d * 1000000) }' \
            "$WORK/psi-$r.1" "$WORK/psi-$r.2")
        when="during the ${DURATION}s sample"
    else
        v=$(awk '/^some/ { split($2, a, "="); print a[2] }' "$f" 2>/dev/null)
        when="over the last 10s"
    fi
    [[ -n $v ]] || return 0
    printf 'PSI %s: %s (stalled %s%% %s)\n' "$r" "$(tr '\n' ' ' <"$f" 2>/dev/null)" "$v" "$when"
    if ge "$v" "$T_PSI_CRIT"; then
        finding CRIT "$m" "Pressure stall ($r): tasks were stalled ${v}% of the time $when, so this resource is a bottleneck" "$fix"
    elif ge "$v" "$T_PSI_WARN"; then
        finding WARN "$m" "Pressure stall ($r): tasks were stalled ${v}% of the time $when" "$fix"
    fi
}

# ----------------------------------------------------------------------------
# Module: system overview (always in the report)
# ----------------------------------------------------------------------------
section_system() {
    section "SYSTEM OVERVIEW"
    run 5 uname -a
    run_sh 5 "cat /etc/os-release"
    run 5 uptime
    run 5 systemd-detect-virt
    echo "Logical CPUs: $CORES   Modules run: $MODULES   Sample: ${DURATION}s"
    ((EUID == 0)) || finding INFO sys "Not running as root: some data (dmesg, per-process I/O, kernel stacks) is limited" "Re-run with sudo for complete results"
}

# ----------------------------------------------------------------------------
# Module: CPU
# ----------------------------------------------------------------------------
cpu_delta() {   # per-CPU percentages: name usr sys idle iowait irq steal
    awk '
        NR == FNR { for (i = 2; i <= 9; i++) p[$1, i] = $i; next }
        {
            tot = 0
            for (i = 2; i <= 9; i++) { dd[i] = $i - p[$1, i]; tot += dd[i] }
            if (tot <= 0) next
            printf "%s %.0f %.0f %.0f %.0f %.0f %.0f\n", $1,
                100 * (dd[2] + dd[3]) / tot, 100 * dd[4] / tot, 100 * dd[5] / tot,
                100 * dd[6] / tot, 100 * (dd[7] + dd[8]) / tot, 100 * dd[9] / tot
        }' "$WORK/stat.1" "$WORK/stat.2"
}

mod_cpu() {
    section "CPU"
    local l1 l5 l15
    read -r l1 l5 l15 _ </proc/loadavg
    echo "Load average: $l1 $l5 $l15 (logical CPUs: $CORES)"
    echo "Governor(cpu0): $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    run_sh 5 "lscpu"
    show_raw vmstat
    show_raw mpstat
    show_pidstat
    run_sh 10 "top -b -n 1 -w 200 | head -n $((TOP_N + 7))"

    # Load
    if fgt "$l1" "$(awk -v c="$CORES" -v m="$T_LOAD_CRIT" 'BEGIN { print c * m }')"; then
        finding CRIT cpu "Load average $l1 is more than ${T_LOAD_CRIT}x the CPU count ($CORES): tasks are queueing" \
            "Find what is running: 'top' then press 1 for per-core view, or 'pidstat -u 1 5'. Also check for blocked I/O: 'ps -eo state,pid,comm | grep ^D'. Kill/renice the offender or add capacity."
    elif fgt "$l1" "$(awk -v c="$CORES" -v m="$T_LOAD_WARN" 'BEGIN { print c * m }')"; then
        finding WARN cpu "Load average $l1 exceeds the CPU count ($CORES)" \
            "Check 'top' and 'pidstat -u 1 5'. If load is high but CPU is idle, tasks are blocked on I/O (see DISK)."
    fi

    [[ -s $WORK/stat.1 && -s $WORK/stat.2 ]] || return 0
    local name usr=0 sys=0 idle=100 iow=0 irq=0 st=0 u s i w q t hot=0 ncpu=0 busy bc
    while read -r name u s i w q t; do
        if [[ $name == cpu ]]; then
            usr=$u sys=$s idle=$i iow=$w irq=$q st=$t
        else
            ncpu=$((ncpu + 1))
            bc=$((100 - i - w))
            ((bc >= 95)) && hot=$((hot + 1))
        fi
    done < <(cpu_delta)
    busy=$((100 - idle - iow))
    printf '\nCPU over sample window: user=%s%% sys=%s%% iowait=%s%% irq/softirq=%s%% steal=%s%% idle=%s%%\n' \
        "$usr" "$sys" "$iow" "$irq" "$st" "$idle"

    local top
    top=$(top_cpu_proc)
    metric cpu "busy ${busy}%  (user ${usr}%  sys ${sys}%)  iowait ${iow}%  steal ${st}%"
    metric cpu "load ${l1} / ${l5} / ${l15} on ${CORES} CPUs${top:+   top process: $top}"

    if ge "$busy" "$T_CPU_CRIT"; then
        finding CRIT cpu "CPU is ${busy}% busy (user ${usr}%, system ${sys}%)${top:+; heaviest process: $top}" \
            "Identify it with 'top -o %CPU' or 'pidstat -u 1 5'. If expected, add cores or move the work; otherwise profile ('perf top -p PID') or limit it ('renice +10 PID', or systemd CPUQuota=)."
    elif ge "$busy" "$T_CPU_WARN"; then
        finding WARN cpu "CPU is ${busy}% busy${top:+; heaviest process: $top}" \
            "Watch it with 'pidstat -u 1 5'. Consider renice/CPU limits for background jobs."
    fi
    if ge "$iow" "$T_IOWAIT_CRIT"; then
        finding CRIT cpu "iowait is ${iow}%: CPUs sit idle waiting for storage" \
            "Find the I/O hog: 'pidstat -d 1 5' or 'iotop -o'; check latency with 'iostat -xz 1'. Move heavy I/O off this disk, use 'ionice -c3' for batch jobs, or faster storage."
    elif ge "$iow" "$T_IOWAIT_WARN"; then
        finding WARN cpu "iowait is ${iow}%" "Run 'iostat -xz 1' and 'pidstat -d 1 5' to see which disk and process."
    fi
    if ge "$st" "$T_STEAL_CRIT"; then
        finding CRIT cpu "CPU steal is ${st}%: the hypervisor is starving this VM" \
            "Move the VM to a less loaded host or resize it; ask your provider about noisy neighbors. Confirm with 'top' (%st column)."
    elif ge "$st" "$T_STEAL_WARN"; then
        finding WARN cpu "CPU steal is ${st}%: some hypervisor contention" "Track it with 'vmstat 1' (st column); consider a larger or dedicated instance."
    fi
    if ((sys >= 30 && sys > usr)); then
        finding WARN cpu "High kernel time (system ${sys}% > user ${usr}%): syscall storm or lock contention" \
            "Summarize syscalls: 'strace -c -f -p PID' (brief!); profile with 'perf top'. Look for excessive small I/O or context switching ('pidstat -w 1')."
    fi
    if ((irq >= 15)); then
        finding WARN cpu "Interrupt/softirq time is ${irq}%: often network or storage interrupts" \
            "Inspect 'cat /proc/interrupts' and '/proc/softirqs'; ensure irqbalance runs and NIC queues (RSS) are spread across cores."
    fi
    if ((hot > 0 && ncpu > 1 && busy < 60)); then
        finding INFO cpu "$hot core(s) pegged at 95%+ while overall CPU is only ${busy}%: a single-threaded bottleneck" \
            "Find the thread with 'top -H' or 'pidstat -t 1'. Parallelize it or pin/scale differently."
    fi

    psi_check cpu cpu "Same as above: find the runnable-task hog with 'top' / 'pidstat -u 1 5'."

    # cgroup CPU throttling (containers / systemd slices)
    local cg=/sys/fs/cgroup thr
    if [[ -r $cg/cpu.stat ]]; then
        run_sh 5 "cat $cg/cpu.max $cg/cpu.stat 2>/dev/null"
        thr=$(awk '$1 == "nr_throttled" { print $2 }' "$cg/cpu.stat" 2>/dev/null)
        if [[ -n $thr ]] && ((thr > 0)); then
            finding WARN cpu "This cgroup has been CPU-throttled $thr times: its quota is too low" \
                "Raise the limit (docker --cpus, k8s limits.cpu, or systemd CPUQuota=) and re-check 'cat $cg/cpu.stat'."
        fi
    fi
    # Thermal throttling counters (Intel)
    local t=0 f
    for f in /sys/devices/system/cpu/cpu*/thermal_throttle/core_throttle_count; do
        [[ -r $f ]] && t=$((t + $(cat "$f" 2>/dev/null || echo 0)))
    done
    echo "Thermal throttle events (all cores): $t"
    if ((t > 0)); then
        finding INFO cpu "CPU thermal throttling was recorded ($t events since boot)" "Check temperatures with 'sensors' and cooling/dust; verify the power profile."
    fi
}

show_pidstat() { show_raw pidstat; }

# ----------------------------------------------------------------------------
# Module: memory
# ----------------------------------------------------------------------------
meminfo() { awk -v k="$1:" '$1 == k { print $2 }' /proc/meminfo; }

mod_mem() {
    section "MEMORY"
    run 5 free -h
    run_sh 5 "grep -E 'MemTotal|MemFree|MemAvailable|Buffers|^Cached|SwapTotal|SwapFree|Dirty|Writeback|Slab|HugePages_Total' /proc/meminfo"
    run_sh 5 "swapon --show"
    show_raw vmstat
    show_pidstat
    run_sh 10 "ps -eo pid,user,rss,vsz,pmem,comm --sort=-rss | head -n $((TOP_N + 1))"

    local total avail stotal sfree
    total=$(meminfo MemTotal)
    avail=$(meminfo MemAvailable)
    stotal=$(meminfo SwapTotal)
    sfree=$(meminfo SwapFree)
    avail=${avail:-$(($(meminfo MemFree) + $(meminfo Cached)))}
    [[ -n $total ]] && ((total > 0)) || return 0

    local apct=$((100 * avail / total)) spct=0 stxt="no swap configured"
    if [[ -n $stotal ]] && ((stotal > 0)); then
        spct=$((100 * (stotal - sfree) / stotal))
        stxt="swap used ${spct}%"
    fi
    local top
    top=$(ps -eo rss=,comm= --sort=-rss 2>/dev/null | head -n 1 | awk '{ printf "%s %.0fM\n", $2, $1 / 1024 }')
    metric mem "available $(human_kb "$avail") of $(human_kb "$total") (${apct}%)   ${stxt}"

    local pin pout mf rate=0 mfr=0
    if [[ -s $WORK/vmstat.1 && -s $WORK/vmstat.2 ]]; then
        pin=$(snap_delta vmstat pswpin)
        pout=$(snap_delta vmstat pswpout)
        mf=$(snap_delta vmstat pgmajfault)
        rate=$(((pin + pout) / DURATION))
        mfr=$((mf / DURATION))
        printf '\nSwap activity: %s pages/s, major page faults: %s/s\n' "$rate" "$mfr"
    fi
    metric mem "swap activity ${rate} pages/s   major faults ${mfr}/s${top:+   top process: $top}"

    if ((apct < T_MEM_CRIT)); then
        finding CRIT mem "Only ${apct}% of memory is available ($(human_kb "$avail")): OOM kills are likely${top:+; largest process: $top}" \
            "Find the hog with 'ps aux --sort=-rss | head'. Restart or fix a leaking service, cap it (systemd MemoryMax=), or add RAM. Note: 'buff/cache' is reclaimable and is not the problem."
    elif ((apct < T_MEM_WARN)); then
        finding WARN mem "Only ${apct}% of memory is available${top:+; largest process: $top}" \
            "Check 'ps aux --sort=-rss | head' and 'smem -tk' (if installed) for growth over time."
    fi
    if ((spct >= T_SWAP_WARN)); then
        finding WARN mem "Swap is ${spct}% used: memory has been under pressure" \
            "Free memory first, then 'sudo swapoff -a && sudo swapon -a' to flush swap. Consider 'sysctl vm.swappiness=10' for latency-sensitive hosts."
    fi
    if ((rate >= 100)); then
        finding CRIT mem "Active swapping (${rate} pages/s): memory shortage is slowing the system" \
            "Find the consumer with 'ps aux --sort=-rss | head' and reduce its footprint or add RAM. Watch 'vmstat 1' (si/so columns)."
    elif ((rate > 0)); then
        finding WARN mem "Some swap activity during sampling (${rate} pages/s)" "Watch 'vmstat 1' (si/so); investigate if it persists."
    fi
    if ((mfr >= 100)); then
        finding WARN mem "High major page-fault rate (${mfr}/s): data is being read from disk into memory" \
            "Usually memory pressure or a huge working set. Check 'free -h' and the top process's RSS."
    fi

    psi_check memory mem "Look for memory hogs ('ps aux --sort=-rss | head') and swapping ('vmstat 1')."

    load_klog
    local oom
    oom=$(grep -ciE 'out of memory|oom-kill|killed process' "$KLOG" || true)
    run_sh 10 "grep -iE 'out of memory|oom-kill|killed process' $KLOG | tail -n 10"
    if ((oom > 0)); then
        finding CRIT mem "The kernel log contains $oom OOM-killer message(s)" \
            "See victims: 'dmesg -T | grep -i \"killed process\"'. Add RAM, set per-service memory limits, or fix the leak. In containers, raise the memory limit."
    fi
}

# ----------------------------------------------------------------------------
# Module: disk
# ----------------------------------------------------------------------------
disk_delta() {   # dev util% await_ms iops
    awk -v d="$DURATION" '
        NR == FNR { r[$1] = $2; rm[$1] = $3; w[$1] = $4; wm[$1] = $5; t[$1] = $6; next }
        ($1 in r) {
            dio = ($2 - r[$1]) + ($4 - w[$1]); dms = ($3 - rm[$1]) + ($5 - wm[$1])
            util = 100 * ($6 - t[$1]) / (d * 1000); if (util > 100) util = 100
            printf "%s %.0f %.1f %.0f\n", $1, util, (dio > 0 ? dms / dio : 0), dio / d
        }' "$WORK/disk.1" "$WORK/disk.2"
}

mod_disk() {
    section "DISK"
    local excl=(-x tmpfs -x devtmpfs -x squashfs -x overlay)
    run 10 df -PhT "${excl[@]}"
    run 10 df -PiT "${excl[@]}"
    run_sh 5 "lsblk -o NAME,SIZE,TYPE,ROTA,MOUNTPOINT"
    show_raw iostat
    show_pidstat

    # Space and inodes
    local pct mp worst_pct=0 worst_mp="-" iworst_pct=0 iworst_mp="-"
    while read -r pct mp; do
        ((pct > worst_pct)) && { worst_pct=$pct; worst_mp=$mp; }
        if ge "$pct" "$T_DISK_CRIT"; then
            finding CRIT disk "Filesystem $mp is ${pct}% full" \
                "Find space hogs: 'du -xh --max-depth=2 $mp | sort -h | tail'. Quick wins: 'journalctl --vacuum-size=200M', rotate/compress logs, 'apt clean' or 'docker system prune'."
        elif ge "$pct" "$T_DISK_WARN"; then
            finding WARN disk "Filesystem $mp is ${pct}% full" "Plan cleanup or expansion; start with 'du -xh --max-depth=2 $mp | sort -h | tail'."
        fi
    done < <(df -P "${excl[@]}" 2>/dev/null | awk 'NR > 1 { gsub("%", "", $5); print $5 + 0, $6 }')
    while read -r pct mp; do
        ((pct > iworst_pct)) && { iworst_pct=$pct; iworst_mp=$mp; }
        if ge "$pct" "$T_DISK_CRIT"; then
            finding CRIT disk "Inodes on $mp are ${pct}% used: new files will fail even with free space" \
                "Find dirs with many files: 'find $mp -xdev -type f | cut -d/ -f1-4 | sort | uniq -c | sort -n | tail'. Delete stale small files (sessions, mail queues, caches)."
        elif ge "$pct" "$T_DISK_WARN"; then
            finding WARN disk "Inodes on $mp are ${pct}% used" "Locate file-heavy dirs: 'find $mp -xdev -type f | cut -d/ -f1-4 | sort | uniq -c | sort -n | tail'."
        fi
    done < <(df -Pi "${excl[@]}" 2>/dev/null | awk 'NR > 1 { gsub("%", "", $5); print $5 + 0, $6 }')
    metric disk "fullest filesystem: ${worst_mp} at ${worst_pct}%   worst inode use: ${iworst_mp} at ${iworst_pct}%"

    # Latency and utilisation (computed from /proc/diskstats)
    local dev util aw iops best="" bu=-1 rota
    if [[ -s $WORK/disk.1 && -s $WORK/disk.2 ]]; then
        printf '\nDisk activity over sample window:\n%-10s %6s %10s %8s\n' device util% await_ms iops
        while read -r dev util aw iops; do
            [[ $dev =~ ^(loop|ram|zram|sr|fd|nbd) ]] && continue
            [[ -d /sys/block/$dev ]] || continue
            printf '%-10s %6s %10s %8s\n' "$dev" "$util" "$aw" "$iops"
            if ((util > bu)); then bu=$util best="$dev util ${util}%  await ${aw}ms  ${iops} IOPS"; fi
            rota=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null || echo 0)
            if ge "$util" "$T_DISK_UTIL_CRIT" && ge "$aw" "$T_AWAIT_WARN"; then
                finding CRIT disk "Disk $dev is saturated: ${util}% busy with ${aw}ms average latency" \
                    "Find the I/O hog: 'pidstat -d 1 5' or 'iotop -o'. Reduce sync writes, spread I/O, use 'ionice -c3' for batch jobs, or move to faster storage. Check health: 'smartctl -a /dev/$dev'."
            elif ge "$util" "$T_DISK_UTIL_WARN" && ge "$aw" 20; then
                finding WARN disk "Disk $dev is busy: ${util}% utilisation, ${aw}ms latency" "Watch 'iostat -xz 1' and find the writer/reader with 'pidstat -d 1 5'."
            elif ge "$aw" "$T_AWAIT_CRIT" && ((util >= 30)); then
                finding CRIT disk "Disk $dev has very high latency: ${aw}ms per I/O (${util}% busy)" \
                    "Check the device: 'smartctl -a /dev/$dev', 'dmesg -T | tail', RAID/controller status. A failing disk or a saturated network volume is likely."
            elif ge "$aw" "$T_AWAIT_WARN" && ((util >= 30)) && ((rota == 0)); then
                finding WARN disk "Disk $dev latency is ${aw}ms (${util}% busy): high for solid-state storage" \
                    "Compare with 'iostat -xz 1'; check for noisy neighbors on shared storage or a queue-depth/scheduler issue."
            fi
        done < <(disk_delta)
    fi
    local tio
    tio=$(top_io_proc)
    metric disk "busiest disk: ${best:-n/a}${tio:+   top I/O: $tio}"

    # Tasks stuck in uninterruptible sleep (usually waiting on storage / NFS)
    printf '\nProcesses in D state (uninterruptible sleep):\n'
    local d cnt
    d=$(ps -eo state=,pid=,comm=,wchan:24= 2>/dev/null | awk '$1 == "D"')
    if [[ -n $d ]]; then
        head -n "$TOP_N" <<<"$d"
        cnt=$(wc -l <<<"$d")
        if ((cnt >= 5)); then
            finding CRIT disk "$cnt processes are stuck in D state: storage or NFS is stalling" \
                "Inspect one: 'cat /proc/<pid>/stack'. Check NFS ('mount | grep nfs', 'nfsstat -c'), dmesg, and 'iostat -xz 1'. Hung network storage often needs the server fixed."
        else
            finding WARN disk "$cnt process(es) in D state (waiting on I/O)" "Check 'cat /proc/<pid>/stack' and 'dmesg -T | tail'; transient D states are normal, persistent ones are not."
        fi
    else
        echo "(none)"
    fi

    # Read-only remounts (typical symptom after filesystem errors)
    local ro
    ro=$(awk '$3 ~ /^(ext[234]|xfs|btrfs|f2fs)$/ && $4 ~ /(^|,)ro(,|$)/ { print $2 }' /proc/mounts 2>/dev/null | tr '\n' ' ')
    if [[ -n ${ro// /} ]]; then
        finding WARN disk "Filesystem(s) mounted read-only: $ro" \
            "If unintended, the kernel remounted after errors: check 'dmesg -T | grep -i error', then fsck from rescue/reboot before remounting rw."
    fi

    psi_check io disk "Find the I/O consumer with 'pidstat -d 1 5' / 'iotop -o' and check 'iostat -xz 1'."

    load_klog
    local io
    io=$(grep -ciE 'i/o error|blk_update_request|ata[0-9.]+: .*(error|failed)|nvme.*timeout|EXT4-fs error|XFS.*(error|corrupt)' "$KLOG" || true)
    if ((io > 0)); then
        finding CRIT disk "The kernel log shows $io disk/filesystem error message(s)" \
            "Check hardware: 'smartctl -a /dev/<disk>', cables/controller/RAID state, and back up important data now. Details: 'dmesg -T | grep -iE \"i/o error|ata|nvme\"'."
    fi
}

# ----------------------------------------------------------------------------
# Module: network
# ----------------------------------------------------------------------------
net_delta_ifaces() {   # iface rx_mbit tx_mbit errors drops
    awk -v d="$DURATION" '
        NR == FNR { rx[$1] = $2; re[$1] = $4; rd[$1] = $5; tx[$1] = $10; te[$1] = $12; td[$1] = $13; next }
        ($1 in rx) && $1 != "lo" {
            printf "%s %.2f %.2f %d %d\n", $1, 8 * ($2 - rx[$1]) / 1e6 / d, 8 * ($10 - tx[$1]) / 1e6 / d,
                ($4 - re[$1]) + ($12 - te[$1]), ($5 - rd[$1]) + ($13 - td[$1])
        }' "$WORK/netdev.1" "$WORK/netdev.2"
}

probe_host() {
    local h=$1 t0 t1 ms rc out loss avg
    printf '\nNetwork probe target: %s\n' "$h"
    if have getent && ! [[ $h =~ ^[0-9.:]+$ ]]; then
        t0=$(date +%s%N)
        getent hosts "$h" >/dev/null 2>&1
        rc=$?
        t1=$(date +%s%N)
        ms=$(((t1 - t0) / 1000000))
        echo "DNS lookup: ${ms}ms (exit $rc)"
        if ((rc != 0)); then
            finding WARN net "DNS lookup for $h failed" "Check 'cat /etc/resolv.conf', 'resolvectl status', and that the resolver is reachable ('ping <resolver-ip>')."
        elif ((ms >= T_DNS_MS_WARN)); then
            finding WARN net "DNS lookup for $h took ${ms}ms" "Try another resolver, or check resolver load/latency: 'dig $h' (look at 'Query time')."
        fi
        metric net "DNS ${h}: ${ms}ms"
    fi
    if have ping; then
        out=$(ping -c 4 -q -W 2 "$h" 2>&1)
        echo "$out"
        loss=$(grep -oE '[0-9.]+% packet loss' <<<"$out" | grep -oE '^[0-9.]+')
        avg=$(awk -F'/' '/^(rtt|round-trip)/ { print $5 }' <<<"$out")
        if [[ -z $loss ]]; then
            finding WARN net "Ping to $h failed (no reply or ping blocked)" "Check routing ('ip route', 'traceroute $h') and firewalls; ICMP may simply be filtered."
        else
            metric net "ping ${h}: loss ${loss}%  avg ${avg:-n/a}ms"
            if ge "$loss" 20; then
                finding CRIT net "Ping to $h shows ${loss}% packet loss" "Locate the lossy hop with 'mtr -rw $h'; check local NIC errors ('ip -s link') and Wi-Fi/cable quality."
            elif ge "$loss" 1; then
                finding WARN net "Ping to $h shows ${loss}% packet loss" "Run 'mtr -rw $h' for a longer test to find where loss starts."
            fi
            if [[ -n $avg ]] && ge "$avg" "$T_PING_MS_WARN"; then
                finding WARN net "Ping latency to $h is high (${avg}ms average)" "Trace the path: 'mtr -rw $h'; check for congestion/bufferbloat on the local link."
            fi
        fi
    else
        echo "[skip] ping not installed"
    fi
}

mod_net() {
    section "NETWORK"
    run 5 ip -s link
    run 5 ip route
    run 5 ss -s
    run_sh 10 "ss -lnt | head -n $((TOP_N + 1))"
    show_raw sar-net

    local iface rx tx err drp speed util shown=0
    if [[ -s $WORK/netdev.1 && -s $WORK/netdev.2 ]]; then
        printf '\nInterface activity over sample window:\n'
        while read -r iface rx tx err drp; do
            printf '%-12s rx %8s Mbit/s  tx %8s Mbit/s  errors %s  drops %s\n' "$iface" "$rx" "$tx" "$err" "$drp"
            speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo -1)
            is_uint "$speed" || speed=-1
            if fgt "$(awk -v a="$rx" -v b="$tx" 'BEGIN { print a + b }')" 0.01 && ((shown < 3)); then
                shown=$((shown + 1))
                metric net "$(printf '%-8s rx %s Mbit/s  tx %s Mbit/s' "$iface" "$rx" "$tx")$( ((speed > 0)) && echo "  (link ${speed} Mbit/s)")"
            fi
            if ((speed > 0)); then
                util=$(awk -v a="$rx" -v b="$tx" -v s="$speed" 'BEGIN { m = (a > b) ? a : b; printf "%.0f", 100 * m / s }')
                if ((util >= T_NET_UTIL_CRIT)); then
                    finding CRIT net "Interface $iface is ${util}% saturated (link ${speed} Mbit/s)" \
                        "Find the heavy talker: 'ss -tin', 'iftop' or 'nload' if installed. Rate-limit, move traffic, or upgrade the link."
                elif ((util >= T_NET_UTIL_WARN)); then
                    finding WARN net "Interface $iface is ${util}% utilised (link ${speed} Mbit/s)" "Watch it with 'sar -n DEV 1' and identify top flows with 'ss -tin'."
                fi
            fi
            if ((err + drp >= 100)); then
                finding CRIT net "Interface $iface had $err errors and $drp drops in ${DURATION}s" \
                    "Check 'ethtool -S $iface' and 'ethtool $iface' (duplex/speed), cable/switch port, and ring buffers ('ethtool -G'). Verify MTU matches the path."
            elif ((err + drp > 0)); then
                finding WARN net "Interface $iface had $err errors and $drp drops in ${DURATION}s" "Check 'ip -s link show $iface' and 'ethtool -S $iface' for the counter that is rising."
            fi
        done < <(net_delta_ifaces)
        ((shown == 0)) && metric net "no significant traffic during the sample (<0.01 Mbit/s)"
    fi

    # TCP health over the window
    local out re ratio="n/a" lo ld
    out=$(net_delta snmp Tcp OutSegs)
    re=$(net_delta snmp Tcp RetransSegs)
    if ((out >= 100)); then
        ratio=$(awk -v r="$re" -v o="$out" 'BEGIN { printf "%.2f", 100 * r / o }')
        if ge "$ratio" "$T_RETRANS_CRIT"; then
            finding CRIT net "TCP retransmit ratio is ${ratio}% (packet loss or congestion)" \
                "Find the affected path: 'ss -ti' (retrans column), 'mtr -rw <host>'. Check NIC errors, MTU mismatch, and switch/link congestion."
        elif ge "$ratio" "$T_RETRANS_WARN"; then
            finding WARN net "TCP retransmit ratio is ${ratio}%" "Investigate with 'ss -ti' and 'mtr -rw <host>'; look for packet loss on the path."
        fi
        ratio="${ratio}%"
    fi
    lo=$(net_delta netstat TcpExt ListenOverflows)
    ld=$(net_delta netstat TcpExt ListenDrops)
    if ((lo > 0 || ld > 0)); then
        finding WARN net "TCP accept queue overflowed ($lo overflows, $ld drops): a server is not accepting connections fast enough" \
            "Raise backlog: 'sysctl net.core.somaxconn=4096' plus the app's listen backlog; check the app is not blocked ('ss -lnt' Recv-Q)."
    fi
    local inuse tw
    read -r inuse tw < <(awk '$1 == "TCP:" { for (i = 2; i < NF; i += 2) v[$i] = $(i + 1) } END { print v["inuse"] + 0, v["tw"] + 0 }' /proc/net/sockstat 2>/dev/null)
    metric net "TCP in use ${inuse:-0}   TIME_WAIT ${tw:-0}   retransmits ${ratio}"

    local cc cm
    cc=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    cm=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    if [[ -n $cc && -n $cm ]] && ((cm > 0)); then
        echo "Conntrack: $cc / $cm"
        if ((100 * cc / cm >= 80)); then
            finding WARN net "Connection tracking table is $((100 * cc / cm))% full ($cc/$cm): new connections will be dropped when full" \
                "Raise 'sysctl net.netfilter.nf_conntrack_max', shorten timeouts, or reduce short-lived connection churn."
        fi
    fi

    [[ -n $PROBE_HOST ]] && probe_host "$PROBE_HOST"
}

# ----------------------------------------------------------------------------
# Module: system (processes, handles, services, kernel warnings)
# ----------------------------------------------------------------------------
mod_sys() {
    section "SYSTEM: PROCESSES, HANDLES, SERVICES"
    echo "(ps %CPU is a lifetime average; see CPU section for the live sample.)"
    run_sh 10 "ps -eo pid,ppid,user,stat,pcpu,pmem,rss,nlwp,etime,comm --sort=-pcpu | head -n $((TOP_N + 1))"

    local ent nproc_total z
    read -r _ _ _ ent _ </proc/loadavg
    nproc_total=$(ps -e --no-headers 2>/dev/null | wc -l)
    z=$(ps -eo stat= 2>/dev/null | grep -c '^Z')
    echo "Processes: $nproc_total   Threads (running/total): $ent   Zombies: $z"
    if ((z >= 20)); then
        finding WARN sys "$z zombie processes: a parent is not reaping its children" \
            "Find the parent: 'ps -eo stat,ppid,pid,comm | grep ^Z'; restart or fix that parent process."
    fi

    local fd="n/a" alloc max
    if [[ -r /proc/sys/fs/file-nr ]]; then
        read -r alloc _ max </proc/sys/fs/file-nr
        if [[ -n ${max:-} ]] && ((max > 0)); then
            fd="$((100 * alloc / max))% of limit"
            echo "System file handles: $alloc / $max"
            if ((100 * alloc / max >= 80)); then
                finding WARN sys "File handle usage is $((100 * alloc / max))% of the system limit" \
                    "Find the leaker: 'ls /proc/*/fd 2>/dev/null | ... ' or 'lsof | awk \"{print \\\$1}\" | sort | uniq -c | sort -n | tail'. Raise 'fs.file-max' only after fixing leaks."
            fi
        fi
    fi

    local failed="n/a" nf
    if have systemctl; then
        run 10 systemctl --failed --no-pager
        nf=$(systemctl --failed --no-legend --plain 2>/dev/null | grep -c .)
        failed=$nf
        if ((nf > 0)); then
            finding WARN sys "$nf systemd unit(s) in failed state" \
                "List: 'systemctl --failed'; inspect: 'systemctl status <unit>' and 'journalctl -u <unit> -e'."
        fi
        run_sh 15 "journalctl -p err -b --no-pager -n 30"
    fi
    metric sys "processes ${nproc_total}   threads ${ent#*/}   zombies ${z}   file handles ${fd}"
    metric sys "failed services: ${failed}"

    load_klog
    local hung
    hung=$(grep -ciE 'blocked for more than [0-9]+ seconds|soft lockup|hard lockup|hung_task' "$KLOG" || true)
    run_sh 10 "grep -iE 'error|warn|fail|throttl' $KLOG | tail -n 30"
    if ((hung > 0)); then
        finding CRIT sys "The kernel log reports $hung hung-task / lockup message(s)" \
            "See 'dmesg -T | grep -iE \"blocked for more|lockup\"' for the stuck task and stack; usually storage, NFS or driver problems."
    fi
}

# ----------------------------------------------------------------------------
# Optional per-process deep dive (report only)
# ----------------------------------------------------------------------------
inspect_pid() {
    local pid=$1
    section "PROCESS DETAIL: PID $pid"
    if [[ ! -d /proc/$pid ]]; then
        echo "PID $pid does not exist"
        finding WARN sys "Requested PID $pid does not exist (already exited?)" "Check the PID with 'pgrep -a <name>'."
        return 0
    fi
    run 5 ps -o pid,ppid,user,stat,pcpu,pmem,rss,vsz,nlwp,etime,wchan:24,cmd -p "$pid"
    run_sh 5 "grep -E '^(Name|State|Threads|VmRSS|VmSwap|voluntary_ctxt_switches|nonvoluntary_ctxt_switches)' /proc/$pid/status"
    run_sh 5 "cat /proc/$pid/io"
    run_sh 5 "grep -E 'Max open files|Max processes' /proc/$pid/limits"
    echo "Open file descriptors: $(find /proc/"$pid"/fd -mindepth 1 2>/dev/null | wc -l)"
    run_sh 10 "top -H -b -n 1 -p $pid | head -n $((TOP_N + 7))"
    run_sh 5 "cat /proc/$pid/stack"
    run 20 pidstat -t -p "$pid" 1 3
    run_sh 10 "lsof -p $pid | head -n 40"
    if ((DO_STRACE)); then
        if have strace && have timeout; then
            printf '\n$ strace -c -f -p %s   (for %ss)\n' "$pid" "$DURATION"
            timeout -s INT "$DURATION" strace -c -f -p "$pid" 2>&1 | tail -n 30
        else
            echo "[skip] strace or timeout not installed"
        fi
    fi
}

# ----------------------------------------------------------------------------
# Dashboard / summary
# ----------------------------------------------------------------------------
mod_label() {
    case $1 in cpu) echo CPU ;; mem) echo MEMORY ;; disk) echo DISK ;; net) echo NETWORK ;; sys) echo SYSTEM ;; esac
}

mod_status() {   # OK | WARN | CRIT for one module
    awk -F'\t' -v m="$1" '
        $2 == m && $1 == "CRIT" { c = 1 }
        $2 == m && $1 == "WARN" { w = 1 }
        END { print c ? "CRIT" : (w ? "WARN" : "OK") }' "$FINDINGS"
}

overall_status() {
    case $(status_code) in 2) echo CRITICAL ;; 1) echo WARNING ;; *) echo HEALTHY ;; esac
}

print_wrapped() {   # print_wrapped FIRST_PREFIX CONT_PREFIX TEXT
    local width=$((TERM_W - ${#2})) line first=1
    while IFS= read -r line; do
        if ((first)); then printf '%s%s\n' "$1" "$line"; first=0; else printf '%s%s\n' "$2" "$line"; fi
    done < <(printf '%s\n' "$3" | fold -s -w "$width")
}

print_summary() {   # print_summary COLOR(0|1)
    local color=$1 g="" y="" r="" c="" b="" z=""
    if ((color)); then
        g=$'\033[1;32m' y=$'\033[1;33m' r=$'\033[1;31m' c=$'\033[0;36m' b=$'\033[1m' z=$'\033[0m'
    fi
    local bar ov ovc
    bar=$(printf '%*s' "$TERM_W" '' | tr ' ' '=')
    ov=$(overall_status)
    case $ov in CRITICAL) ovc=$r ;; WARNING) ovc=$y ;; *) ovc=$g ;; esac

    echo
    echo "$bar"
    printf ' %sPERFORMANCE SUMMARY%s   host: %s   cpus: %s   sample: %ss   %s\n' "$b" "$z" "$HOST" "$CORES" "$DURATION" "$(date '+%F %T')"
    printf ' Overall: %s%s%s\n' "$ovc" "$ov" "$z"
    echo "$bar"

    local m st tag line first
    for m in $MODULES; do
        st=$(mod_status "$m")
        case $st in
            CRIT) tag="${r}[CRIT]${z}" ;;
            WARN) tag="${y}[WARN]${z}" ;;
            *) tag="${g}[ OK ]${z}" ;;
        esac
        first=1
        if [[ -r $WORK/metrics.$m ]]; then
            while IFS= read -r line; do
                if ((first)); then
                    printf ' %s%-8s%s %s  %s\n' "$b" "$(mod_label "$m")" "$z" "$tag" "$line"
                    first=0
                else
                    printf ' %-8s        %s\n' "" "$line"
                fi
            done <"$WORK/metrics.$m"
        fi
        ((first)) && printf ' %s%-8s%s %s  %s\n' "$b" "$(mod_label "$m")" "$z" "$tag" "(no metrics collected)"
    done

    echo "$bar"
    local sev n_issue=0 s mod msg fix col
    for sev in CRIT WARN; do
        [[ $sev == CRIT ]] && col=$r || col=$y
        while IFS=$'\t' read -r s mod msg fix; do
            if ((n_issue == 0)); then printf ' %sISSUES AND FIXES%s\n' "$b" "$z"; echo; fi
            n_issue=$((n_issue + 1))
            print_wrapped "$(printf ' %s[%s]%s %-8s ' "$col" "$sev" "$z" "$(mod_label "$mod")")" "                   " "$msg"
            [[ -n $fix ]] && print_wrapped "                   ${b}Fix:${z} " "                        " "$fix"
            echo
        done < <(awk -F'\t' -v s="$sev" '$1 == s' "$FINDINGS")
    done
    if ((n_issue == 0)); then
        echo " No critical or warning issues found by the built-in checks."
        echo
    fi
    local notes
    notes=$(awk -F'\t' '$1 == "INFO"' "$FINDINGS")
    if [[ -n $notes ]]; then
        printf ' %sNOTES%s\n' "$b" "$z"
        while IFS=$'\t' read -r s mod msg fix; do
            print_wrapped "$(printf ' %s[INFO]%s %-8s ' "$c" "$z" "$(mod_label "$mod")")" "                   " "$msg${fix:+  ->  $fix}"
        done <<<"$notes"
        echo
    fi
    echo "$bar"
    echo " Full details : $REPORT"
    ((!VERBOSE)) && echo " Tip          : add -v to print details here, or name modules (e.g. '$PROG cpu disk') to focus"
    echo "$bar"
}

json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/ /g'; }

build_json() {
    local m msep="" sep line sev mod msg fix
    printf '{"host":"%s","timestamp":"%s","sample_seconds":%s,"overall":"%s","modules":{' \
        "$(json_str "$HOST")" "$(date -Is)" "$DURATION" "$(overall_status)"
    for m in $MODULES; do
        printf '%s"%s":{"status":"%s","metrics":[' "$msep" "$m" "$(mod_status "$m")"
        sep=""
        if [[ -r $WORK/metrics.$m ]]; then
            while IFS= read -r line; do
                printf '%s"%s"' "$sep" "$(json_str "$line")"
                sep=","
            done <"$WORK/metrics.$m"
        fi
        printf ']}'
        msep=","
    done
    printf '},"findings":['
    sep=""
    while IFS=$'\t' read -r sev mod msg fix; do
        printf '%s{"severity":"%s","module":"%s","message":"%s","fix":"%s"}' \
            "$sep" "$sev" "$mod" "$(json_str "$msg")" "$(json_str "${fix:-}")"
        sep=","
    done <"$FINDINGS"
    printf ']}\n'
}

# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------
run_all() {
    echo "$PROG v$VERSION | host=$HOST | $(date -Is) | modules=[$MODULES] | sample=${DURATION}s | euid=$EUID"
    section_system
    if wants cpu || wants mem || wants disk || wants net; then collect_samples; fi
    wants cpu && mod_cpu
    wants mem && mod_mem
    wants disk && mod_disk
    wants net && mod_net
    wants sys && mod_sys
    local p
    for p in "${TARGET_PIDS[@]:-}"; do
        [[ -n $p ]] && inspect_pid "$p"
    done
    return 0
}

reset_state() {
    rm -rf "$WORK"
    mkdir -p "$WORK" "$OUTDIR/raw"
    : >"$FINDINGS"
    KLOG_LOADED=0
}

present() {
    if ((WATCH > 0)) && [[ -t 1 ]] && ((!JSON)); then printf '\033[H\033[2J'; fi
    if ((JSON)); then cat "$OUTDIR/summary.json"; else print_summary "$USE_COLOR"; fi
}

do_run() {
    reset_state
    if ((VERBOSE)); then
        run_all 2>&1 | tee "$REPORT"
    else
        run_all >"$REPORT" 2>&1
    fi
    print_summary 0 >"$OUTDIR/summary.txt"
    cat "$OUTDIR/summary.txt" >>"$REPORT"
    build_json >"$OUTDIR/summary.json"
    present
    rm -rf "$WORK"
}

main() {
    if ((WATCH > 0)); then
        while :; do
            do_run
            sleep "$WATCH"
        done
    else
        do_run
    fi

    if ((MAKE_TAR)); then
        local tarball="${OUTDIR%/}.tar.gz"
        if tar -czf "$tarball" -C "$(dirname "$OUTDIR")" "$(basename "$OUTDIR")" 2>/dev/null; then
            echo "Archive: $tarball" >&2
        else
            echo "$PROG: failed to create archive" >&2
        fi
    fi
    return "$(status_code)"
}

main
exit $?
