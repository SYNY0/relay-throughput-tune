#!/usr/bin/env bash
# TCP throughput tuning for Debian/Ubuntu application-layer relay hosts.
# Suitable for Xray, sing-box, HAProxy, Nginx stream, Shadowsocks and Trojan.
# It does not make BBR control pure routed/NAT TCP flows.
#
# Optional environment variables:
#   PROFILE=throughput|balanced|concurrency   (default: throughput)
#   AGGRESSIVE_SOFTIRQ=1                      (only after measured softnet pressure)
#   ALLOW_LATE_CONFLICTS=1                    (override a fatal later config conflict)
set -Eeuo pipefail
umask 022

TARGET=/etc/sysctl.d/zz-relay-throughput.conf
MODULES_FILE=/etc/modules-load.d/zz-relay-throughput.conf
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR=/root/relay-tune-backup-${STAMP}
MIB=1048576
PROFILE=${PROFILE:-throughput}
AGGRESSIVE_SOFTIRQ=${AGGRESSIVE_SOFTIRQ:-0}
ALLOW_LATE_CONFLICTS=${ALLOW_LATE_CONFLICTS:-0}
CHANGES_STARTED=0
COMMITTED=0
RESTORED=0
tmp=''
modules_tmp=''

info() { printf '\033[1;34m[i]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[!!]\033[0m %s\n' "$*" >&2; exit 1; }

restore_previous_state() {
  (( CHANGES_STARTED && ! RESTORED )) || return 0
  RESTORED=1
  trap - ERR
  warn 'Restoring the previous files and captured runtime sysctl values.'
  if [[ -f "$BACKUP_DIR/original-sysctl.conf" ]]; then
    cp -a "$BACKUP_DIR/original-sysctl.conf" "$TARGET" || true
  else
    rm -f "$TARGET" || true
  fi
  if [[ -f "$BACKUP_DIR/original-modules.conf" ]]; then
    cp -a "$BACKUP_DIR/original-modules.conf" "$MODULES_FILE" || true
  else
    rm -f "$MODULES_FILE" || true
  fi
  [[ -f "$BACKUP_DIR/runtime-before.conf" ]] && sysctl -p "$BACKUP_DIR/runtime-before.conf" >/dev/null 2>&1 || true
}

on_error() {
  local line=$1 rc=$2
  restore_previous_state
  printf '\033[1;31m[!!]\033[0m failed at line %s (exit %s); backup directory: %s\n' \
    "$line" "$rc" "$BACKUP_DIR" >&2
  exit "$rc"
}
on_signal() {
  local rc=$1
  restore_previous_state
  exit "$rc"
}
on_exit() {
  local rc=$1
  if (( rc != 0 && ! COMMITTED )); then restore_previous_state; fi
  [[ -n $tmp ]] && rm -f "$tmp" || true
  [[ -n $modules_tmp ]] && rm -f "$modules_tmp" || true
  return "$rc"
}
trap 'on_error "$LINENO" "$?"' ERR
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_exit "$?"' EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die 'Run this script as root.'
for cmd in awk grep sysctl install nproc ip; do
  command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
done
[[ $AGGRESSIVE_SOFTIRQ == 0 || $AGGRESSIVE_SOFTIRQ == 1 ]] || die 'AGGRESSIVE_SOFTIRQ must be 0 or 1.'
[[ $ALLOW_LATE_CONFLICTS == 0 || $ALLOW_LATE_CONFLICTS == 1 ]] || die 'ALLOW_LATE_CONFLICTS must be 0 or 1.'
case "$PROFILE" in
  throughput)  RAM_FRACTION=0.08; ABS_CAP_BYTES=$((512 * MIB)) ;;
  balanced)    RAM_FRACTION=0.04; ABS_CAP_BYTES=$((256 * MIB)) ;;
  concurrency) RAM_FRACTION=0.02; ABS_CAP_BYTES=$((128 * MIB)) ;;
  *) die 'PROFILE must be throughput, balanced, or concurrency.' ;;
esac

is_uint() { [[ ${1:-} =~ ^[0-9]+$ ]] && (( 10#${1} > 0 )); }
read -r -p 'Peak usable bandwidth in Mbps [1000]: ' BW_INPUT
read -r -p 'High but common relay-path RTT in ms [150]: ' RTT_INPUT
BW_MBPS=${BW_INPUT:-1000}
RTT_MS=${RTT_INPUT:-150}
is_uint "$BW_MBPS" || die 'Bandwidth must be a positive integer in Mbps.'
is_uint "$RTT_MS" || die 'RTT must be a positive integer in milliseconds.'

MEM_BYTES=$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo)
[[ -n "$MEM_BYTES" ]] || die 'Unable to read physical memory.'
CPU_COUNT=$(nproc)
DEFAULT_IFACE=$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')

# BDP(bytes) = Mbps * 125 * RTT(ms). 2*BDP is an empirical throughput target.
BDP_BYTES=$(awk -v bw="$BW_MBPS" -v rtt="$RTT_MS" 'BEGIN {printf "%.0f", bw * 125 * rtt}')
TWO_BDP_BYTES=$(awk -v b="$BDP_BYTES" 'BEGIN {printf "%.0f", b * 2}')
RAM_CAP_BYTES=$(awk -v m="$MEM_BYTES" -v f="$RAM_FRACTION" 'BEGIN {printf "%.0f", m * f}')
HARD_CAP_BYTES=$(( RAM_CAP_BYTES < ABS_CAP_BYTES ? RAM_CAP_BYTES : ABS_CAP_BYTES ))
(( HARD_CAP_BYTES >= 4 * MIB )) || die 'TCP buffer cap would be below 4 MiB; this host is too small for this profile.'
MAX_BYTES=$(awk -v raw="$TWO_BDP_BYTES" -v cap="$HARD_CAP_BYTES" -v mib="$MIB" '
BEGIN {
  floor = 16 * mib;
  value = (raw > floor ? raw : floor);
  if (value > cap) value = cap;
  value = int((value + mib - 1) / mib) * mib;
  if (value > cap) value = int(cap / mib) * mib;
  if (value < 4 * mib) value = 4 * mib;
  printf "%.0f", value;
}')
MAX_MB=$((MAX_BYTES / MIB))

read -r TCP_RMEM_MIN TCP_RMEM_DEF TCP_RMEM_OLD_MAX < <(sysctl -n net.ipv4.tcp_rmem)
read -r TCP_WMEM_MIN TCP_WMEM_DEF TCP_WMEM_OLD_MAX < <(sysctl -n net.ipv4.tcp_wmem)
(( MAX_BYTES >= TCP_RMEM_DEF && MAX_BYTES >= TCP_WMEM_DEF )) || die 'Calculated ceiling is below a current TCP default; refusing an invalid triplet.'

# Default values favour user-space relay latency. Enable the higher values only
# after observing sustained softnet drops/time_squeeze growth under real load.
NETDEV_BACKLOG=32768
NETDEV_BUDGET=600
NETDEV_BUDGET_USECS=4000
if (( AGGRESSIVE_SOFTIRQ == 1 )); then
  if (( BW_MBPS >= 10000 && CPU_COUNT >= 4 )); then
    NETDEV_BACKLOG=65536; NETDEV_BUDGET=1200; NETDEV_BUDGET_USECS=10000
  elif (( BW_MBPS >= 2500 && CPU_COUNT >= 2 )); then
    NETDEV_BACKLOG=32768; NETDEV_BUDGET=600; NETDEV_BUDGET_USECS=8000
  fi
fi

info 'Checking BBR and FQ availability'
if command -v modprobe >/dev/null 2>&1; then
  modprobe tcp_bbr 2>/dev/null || true
  modprobe sch_fq 2>/dev/null || true
fi
AVAILABLE_CC=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
grep -qw bbr <<<"$AVAILABLE_CC" || die "BBR is unavailable in this kernel (available: ${AVAILABLE_CC:-unknown})."

# systemd-sysctl processes sysctl.d files in lexical filename order; a normal
# 50-* or 99-* file is therefore overridden by this zz-* profile. /etc/sysctl.conf
# is only a possible later override on systems that run procps 'sysctl --system'.
KEY_PATTERN='net\.core\.(default_qdisc|rmem_max|wmem_max|netdev_max_backlog|netdev_budget|netdev_budget_usecs|somaxconn)|net\.ipv4\.tcp_(congestion_control|rmem|wmem|moderate_rcvbuf|window_scaling|sack|timestamps|mtu_probing|max_syn_backlog)'
CRITICAL_PATTERN='net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control'
TARGET_NAME=$(basename "$TARGET")
CONFLICTS=()
LATE_CRITICAL_CONFLICTS=()
for path in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf; do
  [[ -f "$path" && "$path" != "$TARGET" ]] || continue
  matches=$(grep -nE "^[[:space:]]*-?[[:space:]]*(${KEY_PATTERN})[[:space:]]*=" "$path" 2>/dev/null || true)
  [[ -z "$matches" ]] || CONFLICTS+=("$path:$matches")
  base=$(basename "$path")
  if [[ $path != /etc/sysctl.conf && $base > $TARGET_NAME ]] && grep -qE "^[[:space:]]*-?[[:space:]]*(${CRITICAL_PATTERN})[[:space:]]*=" "$path"; then
    LATE_CRITICAL_CONFLICTS+=("$path")
  fi
done
if ((${#CONFLICTS[@]})); then
  warn 'Related sysctl settings found; no existing files will be deleted:'
  printf '%s\n' "${CONFLICTS[@]}"
fi
if ((${#LATE_CRITICAL_CONFLICTS[@]})); then
  warn 'A lexically later sysctl.d file can override BBR or FQ after reboot:'
  printf '%s\n' "${LATE_CRITICAL_CONFLICTS[@]}"
  [[ $ALLOW_LATE_CONFLICTS == 1 ]] || die 'Resolve the later critical conflict, or explicitly set ALLOW_LATE_CONFLICTS=1.'
fi
if [[ -f /etc/sysctl.conf ]] && grep -qE "^[[:space:]]*-?[[:space:]]*(${CRITICAL_PATTERN})[[:space:]]*=" /etc/sysctl.conf; then
  warn '/etc/sysctl.conf sets BBR/FQ-related keys. It is ignored by systemd-sysctl, but can override this profile if another boot task runs sysctl --system.'
fi

mkdir -p "$BACKUP_DIR"
if [[ -e "$TARGET" ]]; then cp -a "$TARGET" "$BACKUP_DIR/original-sysctl.conf"; else : > "$BACKUP_DIR/target-was-absent"; fi
if [[ -e "$MODULES_FILE" ]]; then cp -a "$MODULES_FILE" "$BACKUP_DIR/original-modules.conf"; else : > "$BACKUP_DIR/modules-file-was-absent"; fi

KEYS=(net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_moderate_rcvbuf net.ipv4.tcp_window_scaling net.ipv4.tcp_sack net.ipv4.tcp_timestamps net.ipv4.tcp_mtu_probing net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.core.netdev_max_backlog net.core.netdev_budget net.core.netdev_budget_usecs)
for key in "${KEYS[@]}"; do
  [[ -r "/proc/sys/${key//./\/}" ]] && printf '%s = %s\n' "$key" "$(sysctl -n "$key")"
done > "$BACKUP_DIR/runtime-before.conf"

tmp=$(mktemp)
modules_tmp=$(mktemp)
emit() {
  local key=$1 value=$2 path="/proc/sys/${1//./\/}"
  if [[ -e "$path" ]]; then printf '%s = %s\n' "$key" "$value" >> "$tmp"; else warn "Kernel does not expose $key; skipped."; fi
}
cat > "$tmp" <<EOF
# Generated by relay-throughput-tune at ${STAMP}
# Profile=${PROFILE}; bandwidth=${BW_MBPS}Mbps; RTT=${RTT_MS}ms; RAM=$((MEM_BYTES / MIB))MiB; CPUs=${CPU_COUNT}
# BDP=$((BDP_BYTES / MIB))MiB; selected TCP buffer ceiling=${MAX_MB}MiB
# Application-layer relay profile. Verify the actual NIC qdisc after reboot.
EOF
emit net.core.default_qdisc fq
emit net.ipv4.tcp_congestion_control bbr
emit net.core.rmem_max "$MAX_BYTES"
emit net.core.wmem_max "$MAX_BYTES"
emit net.ipv4.tcp_rmem "$TCP_RMEM_MIN $TCP_RMEM_DEF $MAX_BYTES"
emit net.ipv4.tcp_wmem "$TCP_WMEM_MIN $TCP_WMEM_DEF $MAX_BYTES"
emit net.ipv4.tcp_moderate_rcvbuf 1
emit net.ipv4.tcp_window_scaling 1
emit net.ipv4.tcp_sack 1
emit net.ipv4.tcp_timestamps 1
emit net.ipv4.tcp_mtu_probing 1
emit net.core.somaxconn 16384
emit net.ipv4.tcp_max_syn_backlog 32768
emit net.core.netdev_max_backlog "$NETDEV_BACKLOG"
emit net.core.netdev_budget "$NETDEV_BUDGET"
emit net.core.netdev_budget_usecs "$NETDEV_BUDGET_USECS"
printf 'tcp_bbr\nsch_fq\n' > "$modules_tmp"

# From this point every abnormal exit restores both files and captured runtime state.
CHANGES_STARTED=1
install -m 0644 "$tmp" "$TARGET"
install -m 0644 "$modules_tmp" "$MODULES_FILE"
sysctl -p "$TARGET" || die 'sysctl application failed.'
[[ $(sysctl -n net.ipv4.tcp_congestion_control) == bbr ]] || die 'BBR verification failed.'
[[ $(sysctl -n net.core.default_qdisc) == fq ]] || die 'FQ default-qdisc verification failed.'

cat > "$BACKUP_DIR/rollback.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$BACKUP_DIR/original-sysctl.conf" ]]; then cp -a "$BACKUP_DIR/original-sysctl.conf" "$TARGET"; else rm -f "$TARGET"; fi
if [[ -f "$BACKUP_DIR/original-modules.conf" ]]; then cp -a "$BACKUP_DIR/original-modules.conf" "$MODULES_FILE"; else rm -f "$MODULES_FILE"; fi
sysctl --system
printf 'Configuration restored. Reboot, then verify the interface qdisc.\n'
EOF
chmod 0700 "$BACKUP_DIR/rollback.sh"
COMMITTED=1

ok "Profile written to $TARGET"
ok "Rollback script: $BACKUP_DIR/rollback.sh"
printf '\nProfile: %s | RAM: %s MiB | CPU: %s | BW: %s Mbps | RTT: %s ms\n' "$PROFILE" "$((MEM_BYTES / MIB))" "$CPU_COUNT" "$BW_MBPS" "$RTT_MS"
printf 'BDP: %.2f MiB | 2*BDP: %.2f MiB | TCP ceiling: %s MiB\n' \
  "$(awk -v b="$BDP_BYTES" -v m="$MIB" 'BEGIN {printf "%.2f", b/m}')" \
  "$(awk -v b="$TWO_BDP_BYTES" -v m="$MIB" 'BEGIN {printf "%.2f", b/m}')" "$MAX_MB"
printf 'softirq profile: backlog=%s budget=%s usecs=%s (aggressive=%s)\n' "$NETDEV_BACKLOG" "$NETDEV_BUDGET" "$NETDEV_BUDGET_USECS" "$AGGRESSIVE_SOFTIRQ"
printf 'CC: %s | default qdisc: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control)" "$(sysctl -n net.core.default_qdisc)"
if [[ -n ${DEFAULT_IFACE:-} ]] && command -v tc >/dev/null 2>&1; then
  printf 'Current qdisc on %s (may change only after reboot):\n' "$DEFAULT_IFACE"
  tc qdisc show dev "$DEFAULT_IFACE" || true
fi
warn 'Reboot during a maintenance window, verify the actual NIC qdisc, then test real single- and multi-stream traffic.'
warn 'For high concurrency inspect LimitNOFILE, CPU saturation, NIC queue count, retransmits, memory pressure, and packet drops.'
