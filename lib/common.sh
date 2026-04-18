#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for wireconf: paths, logging, argv, env, inventory, remote runner.

set -euo pipefail

wireconf_common_init() {
  local _here
  _here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  WIRECONF_LIB_DIR="$_here"
  WIRECONF_ROOT="$(cd "$_here/.." && pwd)"
  wireconf_init_colors
}

# ANSI colors: disabled when stderr is not a TTY, or when NO_COLOR is set; FORCE_COLOR overrides TTY check.
wireconf_init_colors() {
  WC_C_RESET=$'\033[0m'
  WC_C_BOLD=$'\033[1m'
  WC_C_DIM=$'\033[2m'
  WC_C_CYAN=$'\033[36m'
  WC_C_GREEN=$'\033[32m'
  WC_C_YELLOW=$'\033[33m'
  WC_C_RED=$'\033[31m'
  if [[ -n "${NO_COLOR:-}" ]]; then
    WC_C_RESET="" WC_C_BOLD="" WC_C_DIM="" WC_C_CYAN="" WC_C_GREEN="" WC_C_YELLOW="" WC_C_RED=""
  elif [[ -z "${FORCE_COLOR:-}" ]] && [[ ! -t 2 ]]; then
    WC_C_RESET="" WC_C_BOLD="" WC_C_DIM="" WC_C_CYAN="" WC_C_GREEN="" WC_C_YELLOW="" WC_C_RED=""
  fi
}

log_info() {
  printf '%s[wireconf]%s %s%s%s\n' "${WC_C_CYAN}${WC_C_BOLD}" "$WC_C_RESET" "$WC_C_GREEN" "$*" "$WC_C_RESET" >&2
}
log_warn() {
  printf '%s[wireconf]%s %sWARN:%s %s%s%s\n' "${WC_C_CYAN}${WC_C_BOLD}" "$WC_C_RESET" "$WC_C_YELLOW" "$WC_C_RESET" "$WC_C_YELLOW" "$*" "$WC_C_RESET" >&2
}
log_err() {
  printf '%s[wireconf]%s %sERROR:%s %s%s%s\n' "${WC_C_CYAN}${WC_C_BOLD}" "$WC_C_RESET" "$WC_C_RED" "$WC_C_RESET" "$WC_C_RED" "$*" "$WC_C_RESET" >&2
}

# Indented secondary output (plan lists, check details).
log_detail() { printf '  %s%s%s\n' "$WC_C_DIM" "$*" "$WC_C_RESET" >&2; }

# Indented line with trailing status in green (e.g. OK).
log_detail_ok() {
  local msg="$1"
  printf '  %s%s%s %s%s%s\n' "$WC_C_DIM" "$msg" "$WC_C_RESET" "$WC_C_GREEN" "OK" "$WC_C_RESET" >&2
}

wc_term_cols() {
  local cols="${COLUMNS:-}"
  if [[ -z "$cols" ]] && command -v tput >/dev/null 2>&1; then
    cols="$(tput cols 2>/dev/null || true)"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  (( cols < 20 )) && cols=20
  printf '%s\n' "$cols"
}

log_detail_centered() {
  local msg="$1"
  local cols inner pad
  cols="$(wc_term_cols)"
  inner=$((cols - 2))
  (( inner < 1 )) && inner=1
  pad=$(((inner - ${#msg}) / 2))
  (( pad < 0 )) && pad=0
  printf '  %s%*s%s%s\n' "$WC_C_DIM" "$pad" "" "$msg" "$WC_C_RESET" >&2
}

# --help output (stderr); uses same NO_COLOR / FORCE_COLOR / TTY rules as log_*.
# Padding uses a space buffer (not printf '%*s' '') to avoid extra blank lines on some shells/terminals.
WC_HELP_PAD64='                                                                '

log_help_title() { printf '%s%s%s\n' "${WC_C_CYAN}${WC_C_BOLD}" "$1" "$WC_C_RESET" >&2; }
log_help_usage_line() {
  printf '%sUsage:%s %s%s%s\n' "${WC_C_CYAN}${WC_C_BOLD}" "$WC_C_RESET" "${WC_C_GREEN}" "$1" "$WC_C_RESET" >&2
}
log_help_option() {
  local syn="$1" desc="$2"
  local pad=$((34 - ${#syn}))
  (( pad < 1 )) && pad=1
  (( pad > ${#WC_HELP_PAD64} )) && pad=${#WC_HELP_PAD64}
  printf '  %s%s%s%s%s%s%s\n' "${WC_C_YELLOW}" "$syn" "$WC_C_RESET" "${WC_HELP_PAD64:0:pad}" "${WC_C_DIM}" "$desc" "$WC_C_RESET" >&2
}
log_help_cmd() {
  local name="$1" desc="$2"
  local pad=$((16 - ${#name}))
  (( pad < 1 )) && pad=1
  (( pad > ${#WC_HELP_PAD64} )) && pad=${#WC_HELP_PAD64}
  printf '  %s%s%s%s%s%s%s\n' "${WC_C_GREEN}" "$name" "$WC_C_RESET" "${WC_HELP_PAD64:0:pad}" "${WC_C_DIM}" "$desc" "$WC_C_RESET" >&2
}
log_help_para() { printf '%s%s%s\n' "$WC_C_DIM" "$1" "$WC_C_RESET" >&2; }

die() {
  log_err "$1"
  exit "${2:-1}"
}

# Prompt on /dev/tty; 0 = yes. WC_ASSUME_YES=1 skips prompt (see -y / WIRECONF_YES).
wireconf_prompt_yes() {
  local msg="$1"
  if [[ "${WC_ASSUME_YES:-0}" -eq 1 ]]; then
    log_info "Auto-yes (-y / WIRECONF_YES=1): ${msg}"
    return 0
  fi
  if [[ ! -r /dev/tty ]]; then
    return 1
  fi
  printf '%s%s [y/N] %s' "${WC_C_YELLOW}" "$msg" "$WC_C_RESET" >&2
  local line
  if ! read -r line < /dev/tty 2>/dev/null; then
    return 1
  fi
  case "${line,,}" in
    y | yes) return 0 ;;
    *) return 1 ;;
  esac
}

# Defaults (override via env file or CLI)
WC_ENV_FILE=""
WC_ENV_FILE_EXPLICIT=0
WC_INVENTORY=""
WC_INVENTORY_EXPLICIT=0
WC_IFACE="${WG_INTERFACE:-wg0}"
WC_NETWORK="${WG_NETWORK:-10.200.0.0/24}"
WC_PORT="${WG_PORT:-51820}"
WC_HUB_ENDPOINT="${WG_HUB_ENDPOINT:-}"
WC_HUB_EGRESS="${WG_HUB_EGRESS:-}"
WC_AUTO_START="${AUTO_START:-yes}"
WC_FULL_TUNNEL_DEFAULT="${FULL_TUNNEL_DEFAULT:-no}"
WC_SSH_OPTS="${SSH_OPTS:-}"
WC_PEER_DNS="${WG_PEER_DNS:-}"
WC_SPLIT_DNS="${WG_SPLIT_DNS:-}"
WC_FORCE=0
WC_BACKUP_DIR=""
WC_SSH_PORT_DEFAULT="${SSH_PORT:-22}"
# yes = ssh/scp use StrictHostKeyChecking=accept-new (add new host keys to known_hosts; refuse on changed keys)
WC_SSH_ACCEPT_NEW="${SSH_ACCEPT_NEW:-no}"
WC_SSH_HOSTKEY_OPTS=""
WC_KEEPALIVE="${WG_KEEPALIVE:-25}"
WC_MTU="${WG_MTU:-}"
WC_HANDSHAKE_TIMEOUT="${WG_HANDSHAKE_TIMEOUT:-300}"
WC_PARALLEL="${WG_PARALLEL:-1}"
# Set by plan_check_operator_wg_keygen: local | remote_hub
WC_KEYGEN_MODE=""
# 1 = skip "install wireguard?" prompts (also WIRECONF_YES=1 in env)
WC_ASSUME_YES=0
# 1 = show command omits PrivateKey lines (--redact)
WC_SHOW_REDACT=0

# Populated by parse_inventory (or wc_load_inline_hosts)
declare -a WC_SSH_TARGETS=()
declare -a WC_SSH_PORTS=()
declare -a WC_FULL_TUNNEL=()
declare -A WC_SSH_PORT_HINTS=()
WC_HUB_SSH_TARGET=""

# Trailing non-flag arguments to subcommands (up, add-peer, remove-peer, bootstrap, doctor).
declare -a WC_CMD_EXTRA_ARGS=()

is_local_host() {
  case "$1" in
    localhost | 127.0.0.1 | ::1) return 0 ;;
    *) return 1 ;;
  esac
}

wc_host_resolved_ips() {
  local host="$1"
  host="${host#[}"
  host="${host%]}"
  [[ -n "$host" ]] || return 1

  # Fast-path literal IPs so callers don't need DNS tools.
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$host" == *:* ]]; then
    printf '%s\n' "$host"
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    getent ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi
  if command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" 2>/dev/null | awk '/ip_address:/{print $2}' | sort -u
    return 0
  fi
  if command -v host >/dev/null 2>&1; then
    host "$host" 2>/dev/null | awk '/ has address /{print $4} / has IPv6 address /{print $5}' | sort -u
    return 0
  fi
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" 2>/dev/null | awk 'NF>0{print $1}' | sort -u
    return 0
  fi

  return 1
}

wc_local_ips() {
  printf '%s\n' "127.0.0.1" "::1"

  if command -v hostname >/dev/null 2>&1; then
    hostname -I 2>/dev/null | tr ' ' '\n' | awk 'NF>0{print $1}'
  fi
  if command -v ip >/dev/null 2>&1; then
    ip -o addr show up 2>/dev/null | awk '{print $4}' | awk -F/ '{print $1}'
  elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | awk '
      $1 == "inet" {print $2}
      $1 == "inet6" {gsub(/%.*$/, "", $2); print $2}
    '
  fi
}

# True for literal localhost, or for the configured hub target when that host
# resolves to one of this machine's addresses (public IP/FQDN that points back).
wc_is_local_execution_target() {
  local target="$1"
  is_local_host "$target" && return 0

  local hub="${WC_HUB_SSH_TARGET:-${WC_SSH_TARGETS[0]:-}}"
  [[ -n "$hub" ]] || return 1
  [[ "$target" == "$hub" ]] || return 1

  local host
  host="$(wc_wireguard_endpoint_host "$target")"
  is_local_host "$host" && return 0

  local resolved local_ips ip
  resolved="$(wc_host_resolved_ips "$host" 2>/dev/null || true)"
  [[ -n "$resolved" ]] || return 1
  local_ips="$(wc_local_ips 2>/dev/null | sort -u || true)"
  [[ -n "$local_ips" ]] || return 1

  while IFS= read -r ip; do
    local lip
    [[ -n "$ip" ]] || continue
    while IFS= read -r lip; do
      [[ -n "$lip" ]] || continue
      [[ "$ip" == "$lip" ]] && return 0
    done <<<"$local_ips"
  done <<<"$resolved"
  return 1
}

wc_wireguard_endpoint_host() {
  local target="$1"
  printf '%s\n' "${target##*@}"
}

# Run remote/local sudo command; on failure log hints unless quiet (use quiet for expected-failure probes).
__wc_run_sudo_impl() {
  local target="$1"
  local quiet="$2"
  shift 2
  local r=0 port
  if wc_is_local_execution_target "$target"; then
    bash -c "set -euo pipefail; sudo -n bash -c $(printf '%q' "$*")" || r=$?
  else
    port="$(wc_ssh_port_for_target "$target")"
    # shellcheck disable=SC2086
    ssh ${WC_SSH_OPTS:-} ${WC_SSH_HOSTKEY_OPTS:-} -p "$port" -o BatchMode=yes -o ConnectTimeout=15 "$target" \
      "bash -lc $(printf '%q' "set -euo pipefail; sudo -n bash -c $(printf '%q' "$*")")" || r=$?
  fi
  if [[ "$r" -ne 0 && "$quiet" -eq 0 ]]; then
    log_err "Remote/local command failed on ${target} (exit ${r})."
    if wc_is_local_execution_target "$target"; then
      log_err "If sudo was denied, configure passwordless sudo for the needed commands and verify: sudo -n true"
    else
      log_err "If sudo was denied, configure passwordless sudo for the needed commands and verify: ssh -p ${port} ${target} 'sudo -n true'"
    fi
  fi
  return "$r"
}

wc_run_sudo() {
  local target="$1"
  shift
  __wc_run_sudo_impl "$target" 0 "$@"
}

# Same as wc_run_sudo but no ERROR lines on non-zero (tool probes, command -v checks, etc.).
wc_run_sudo_quiet() {
  local target="$1"
  shift
  __wc_run_sudo_impl "$target" 1 "$@"
}

wc_scp_to() {
  local target="$1"
  local src="$2"
  local dst="$3"
  if wc_is_local_execution_target "$target"; then
    wc_run_sudo "$target" "install -m 0600 -T $(printf '%q' "$src") $(printf '%q' "$dst")"
  else
    local port remote_tmp qtmp qdst
    port="$(wc_ssh_port_for_target "$target")"
    remote_tmp="$(wc_ssh_exec "$target" "$port" "mktemp /tmp/wireconf.XXXXXX")" || die "mktemp failed on ${target}"
    remote_tmp="${remote_tmp//$'\r'/}"
    remote_tmp="${remote_tmp//$'\n'/}"
    [[ -n "$remote_tmp" ]] || die "mktemp returned empty path on ${target}"
    qtmp=$(printf '%q' "$remote_tmp")
    qdst=$(printf '%q' "$dst")
    # shellcheck disable=SC2086
    if ! scp ${WC_SSH_OPTS:-} ${WC_SSH_HOSTKEY_OPTS:-} -P "$port" -q "$src" "${target}:$remote_tmp"; then
      wc_ssh_exec "$target" "$port" "rm -f -- $qtmp" >/dev/null 2>&1 || true
      die "scp failed for ${target}"
    fi
    wc_run_sudo "$target" "{ install -m 0600 -T $qtmp $qdst && rm -f -- $qtmp; } || { rm -f -- $qtmp; exit 1; }"
  fi
}

normalize_bool() {
  case "${1,,}" in
    1 | y | yes | true | on) echo yes ;;
    0 | n | no | false | off | "") echo no ;;
    *) die "Invalid boolean: $1" 2 ;;
  esac
}

load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || die "Env file not found: $f"
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
  # Re-sync WC_* from env after source
  WC_IFACE="${WG_INTERFACE:-$WC_IFACE}"
  WC_NETWORK="${WG_NETWORK:-$WC_NETWORK}"
  WC_PORT="${WG_PORT:-$WC_PORT}"
  WC_HUB_ENDPOINT="${WG_HUB_ENDPOINT:-$WC_HUB_ENDPOINT}"
  WC_HUB_EGRESS="${WG_HUB_EGRESS:-$WC_HUB_EGRESS}"
  WC_AUTO_START="${AUTO_START:-$WC_AUTO_START}"
  WC_FULL_TUNNEL_DEFAULT="${FULL_TUNNEL_DEFAULT:-$WC_FULL_TUNNEL_DEFAULT}"
  WC_SSH_OPTS="${SSH_OPTS:-$WC_SSH_OPTS}"
  WC_PEER_DNS="${WG_PEER_DNS:-$WC_PEER_DNS}"
  WC_SPLIT_DNS="${WG_SPLIT_DNS:-$WC_SPLIT_DNS}"
  WC_KEEPALIVE="${WG_KEEPALIVE:-$WC_KEEPALIVE}"
  WC_MTU="${WG_MTU:-$WC_MTU}"
  WC_HANDSHAKE_TIMEOUT="${WG_HANDSHAKE_TIMEOUT:-$WC_HANDSHAKE_TIMEOUT}"
  WC_PARALLEL="${WG_PARALLEL:-$WC_PARALLEL}"
  WC_INVENTORY="${WC_INVENTORY:-${INVENTORY:-}}"
  WC_SSH_PORT_DEFAULT="${SSH_PORT:-${WC_SSH_PORT_DEFAULT:-22}}"
  case "${WIRECONF_YES:-}" in
    1 | y | yes | true | on | Y | YES | TRUE | ON) WC_ASSUME_YES=1 ;;
  esac
}

# Inventory line: host [ssh_port] [full_tunnel]
# - One field: host (ssh_port from SSH_PORT / default, full_tunnel from default)
# - Two fields: if second is 1-65535 → ssh_port; else full_tunnel yes|no
# - Three fields: host ssh_port full_tunnel
parse_inventory_line() {
  local line="$1"
  local def_port="$2"
  local def_bool="$3"
  local -n _out_host="$4"
  local -n _out_port="$5"
  local -n _out_ft="$6"
  local -a tok=()
  read -r -a tok <<<"$line"
  local n="${#tok[@]}"
  _out_host="${tok[0]:-}"
  [[ -n "$_out_host" ]] || return 1
  _out_port="$def_port"
  _out_ft="$def_bool"
  [[ "$n" -eq 1 ]] && return 0
  if [[ "$n" -eq 2 ]]; then
    if [[ "${tok[1]}" =~ ^[0-9]+$ ]]; then
      [[ "${tok[1]}" -ge 1 && "${tok[1]}" -le 65535 ]] || die "Invalid SSH port in inventory: $line"
      _out_port="${tok[1]}"
    else
      _out_ft="$(normalize_bool "${tok[1]}")"
    fi
    return 0
  fi
  if [[ "$n" -eq 3 ]]; then
    [[ "${tok[1]}" =~ ^[0-9]+$ ]] && [[ "${tok[1]}" -ge 1 ]] && [[ "${tok[1]}" -le 65535 ]] ||
      die "Invalid inventory (ssh_port must be 1-65535): $line"
    _out_port="${tok[1]}"
    _out_ft="$(normalize_bool "${tok[2]}")"
    return 0
  fi
  die "Too many fields in inventory line: $line"
}

validate_ssh_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]] || die "Invalid SSH port: $p"
}

# Linux IFNAMSIZ 15; restrict chars so hub PostUp/PostDown (shell) cannot inject commands.
validate_iface_name() {
  local n="$1"
  local what="${2:-Interface name}"
  [[ -n "$n" ]] || die "${what} cannot be empty"
  [[ "$n" =~ ^[a-zA-Z0-9._@-]{1,15}$ ]] || die "${what} must be 1-15 chars [a-zA-Z0-9._@-]: $n"
}

validate_wg_listen_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && [[ "$p" -ge 1 ]] && [[ "$p" -le 65535 ]] || die "Invalid WireGuard listen port (1-65535): $p"
}

validate_keepalive_secs() {
  local k="$1"
  [[ "$k" =~ ^[0-9]+$ ]] && [[ "$k" -le 65535 ]] || die "Invalid keepalive (0-65535 seconds): $k"
}

validate_parallel_jobs() {
  local n="$1"
  [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge 1 ]] && [[ "$n" -le 64 ]] || die "Invalid parallel job count (1-64): $n"
}

# After inventory + CIDR; before plan/apply/show/…
wc_validate_runtime_config() {
  validate_iface_name "$WC_IFACE" "WG_INTERFACE / --iface"
  validate_wg_listen_port "$WC_PORT"
  validate_keepalive_secs "$WC_KEEPALIVE"
  validate_parallel_jobs "${WC_PARALLEL:-1}"
  [[ -z "${WC_HUB_EGRESS:-}" ]] || validate_iface_name "$WC_HUB_EGRESS" "WG_HUB_EGRESS"
}

# After CLI/env: set WC_SSH_HOSTKEY_OPTS from normalized WC_SSH_ACCEPT_NEW.
wc_apply_ssh_hostkey_opts() {
  WC_SSH_ACCEPT_NEW="$(normalize_bool "${WC_SSH_ACCEPT_NEW:-no}")"
  if [[ "$WC_SSH_ACCEPT_NEW" == "yes" ]]; then
    WC_SSH_HOSTKEY_OPTS='-o StrictHostKeyChecking=accept-new'
  else
    WC_SSH_HOSTKEY_OPTS=""
  fi
}

# Build WC_SSH_TARGETS / WC_SSH_PORTS / WC_FULL_TUNNEL / WC_HUB_SSH_TARGET from a
# list of CLI-provided hosts using the same grammar as `parse_inventory_line`
# (host [ssh_port] [full_tunnel]). First arg is the hub. No file is read or
# written; callers are expected to set WC_INVENTORY="" afterwards so persistent
# state (action log, last-state) is skipped.
wc_load_inline_hosts() {
  local n=$#
  [[ "$n" -ge 2 ]] || die "inline hosts: need at least 2 (hub + peer), got $n"

  validate_ssh_port "$WC_SSH_PORT_DEFAULT"

  WC_SSH_TARGETS=()
  WC_SSH_PORTS=()
  WC_FULL_TUNNEL=()
  local -A _seen_hosts=()
  local def spec host port ft
  def="$(normalize_bool "$WC_FULL_TUNNEL_DEFAULT")"

  for spec in "$@"; do
    case "$spec" in
      -*) die "inline hosts: '$spec' looks like a flag — global flags must come before the subcommand (e.g. wireconf -y up root@hub root@peer)" ;;
    esac
    parse_inventory_line "$spec" "$WC_SSH_PORT_DEFAULT" "$def" host port ft || die "inline hosts: empty spec"
    if [[ -n "${_seen_hosts[$host]+x}" ]]; then
      die "inline hosts: duplicate host $host"
    fi
    _seen_hosts["$host"]=1
    WC_SSH_TARGETS+=("$host")
    WC_SSH_PORTS+=("$port")
    WC_FULL_TUNNEL+=("$ft")
  done

  WC_HUB_SSH_TARGET="${WC_SSH_TARGETS[0]}"
}

# Parse inventory: sets WC_SSH_TARGETS, WC_SSH_PORTS, WC_FULL_TUNNEL, WC_HUB_SSH_TARGET
parse_inventory() {
  local inv="$1"
  [[ -n "$inv" ]] || die "Inventory path not set"
  [[ -f "$inv" ]] || die "Inventory not found: $inv"

  validate_ssh_port "$WC_SSH_PORT_DEFAULT"

  WC_SSH_TARGETS=()
  WC_SSH_PORTS=()
  WC_FULL_TUNNEL=()
  local line host ft port def
  local -A _seen_hosts=()
  def="$(normalize_bool "$WC_FULL_TUNNEL_DEFAULT")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    parse_inventory_line "$line" "$WC_SSH_PORT_DEFAULT" "$def" host port ft || continue
    if [[ -n "${_seen_hosts[$host]+x}" ]]; then
      die "Duplicate host in inventory: $host (each host may appear only once)"
    fi
    _seen_hosts["$host"]=1
    WC_SSH_TARGETS+=("$host")
    WC_SSH_PORTS+=("$port")
    WC_FULL_TUNNEL+=("$ft")
  done <"$inv"

  [[ "${#WC_SSH_TARGETS[@]}" -ge 2 ]] || die "Need at least hub + one peer in inventory"
  WC_HUB_SSH_TARGET="${WC_SSH_TARGETS[0]}"
}

# Same parsing as parse_inventory but missing file is OK (empty lists) and there is no minimum host count.
# Used by add-peer when building an inventory from an empty or incomplete file.
parse_inventory_relaxed() {
  local inv="$1"
  [[ -n "$inv" ]] || die "Inventory path not set"
  validate_ssh_port "$WC_SSH_PORT_DEFAULT"

  WC_SSH_TARGETS=()
  WC_SSH_PORTS=()
  WC_FULL_TUNNEL=()
  WC_HUB_SSH_TARGET=""

  [[ -f "$inv" ]] || return 0

  local line host ft port def
  local -A _seen_hosts=()
  def="$(normalize_bool "$WC_FULL_TUNNEL_DEFAULT")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    parse_inventory_line "$line" "$WC_SSH_PORT_DEFAULT" "$def" host port ft || continue
    if [[ -n "${_seen_hosts[$host]+x}" ]]; then
      die "Duplicate host in inventory: $host (each host may appear only once)"
    fi
    _seen_hosts["$host"]=1
    WC_SSH_TARGETS+=("$host")
    WC_SSH_PORTS+=("$port")
    WC_FULL_TUNNEL+=("$ft")
  done <"$inv"

  if [[ "${#WC_SSH_TARGETS[@]}" -gt 0 ]]; then
    WC_HUB_SSH_TARGET="${WC_SSH_TARGETS[0]}"
  else
    WC_HUB_SSH_TARGET=""
  fi
  return 0
}

wc_ssh_port_for_target() {
  local want="$1"
  local i
  for ((i = 0; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    if [[ "${WC_SSH_TARGETS[$i]}" == "$want" ]]; then
      echo "${WC_SSH_PORTS[$i]}"
      return 0
    fi
  done
  if [[ -n "${WC_SSH_PORT_HINTS[$want]+x}" ]]; then
    echo "${WC_SSH_PORT_HINTS[$want]}"
    return 0
  fi
  echo "$WC_SSH_PORT_DEFAULT"
}

# Non-interactive SSH. Args: target, port, remote argv passed to ssh (e.g. "true").
wc_ssh_exec() {
  local target="$1"
  local port="$2"
  shift 2
  if wc_is_local_execution_target "$target"; then
    bash -lc "$*"
    return $?
  fi
  # shellcheck disable=SC2086
  ssh ${WC_SSH_OPTS:-} ${WC_SSH_HOSTKEY_OPTS:-} -p "$port" -o BatchMode=yes -o ConnectTimeout=10 "$target" "$@"
}

# Allocate VPN addresses: prints lines "index ip" (0=hub, 1..=peers-1)
wg_allocate_ips() {
  local cidr="$1"
  local total="$2"
  awk -v cidr="$cidr" -v total="$total" '
  function ip2num(ip,   a, n) {
    n = split(ip, a, ".")
    if (n != 4) exit 2
    return a[1]*16777216 + a[2]*65536 + a[3]*256 + a[4] + 0
  }
  function num2ip(x,   o1,o2,o3,o4) {
    o4 = int(x % 256); x = int(x / 256)
    o3 = int(x % 256); x = int(x / 256)
    o2 = int(x % 256); o1 = int(x / 256)
    return o1 "." o2 "." o3 "." o4
  }
  BEGIN {
    split(cidr, p, "/")
    if (length(p) != 2) exit 3
    prefix = p[2] + 0
    if (prefix < 16 || prefix > 30) exit 4
    raw = ip2num(p[1])
    hostbits = 32 - prefix
    net = int(raw / (2^hostbits)) * (2^hostbits)
    maxhosts = 2^hostbits
    usable = maxhosts - 2
    if (total > usable) exit 5
    base = net + 1
    for (i = 0; i < total; i++) {
      print i, num2ip(base + i)
    }
  }'
}

wc_build_ip_map() {
  local n="${#WC_SSH_TARGETS[@]}"
  local out
  out="$(wg_allocate_ips "$WC_NETWORK" "$n")" || die "WG_NETWORK $WC_NETWORK cannot fit $n hosts (need /16–/30 with enough addresses)"
  declare -gA WC_INDEX_TO_IP=()
  while read -r idx ip; do
    [[ -n "$idx" ]] || continue
    WC_INDEX_TO_IP["$idx"]="$ip"
  done <<<"$out"
}

cidr_prefix_len() {
  local c="$1"
  echo "${c#*/}"
}

validate_cidr() {
  local cidr="$1"
  [[ "$cidr" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/([0-9]+)$ ]] ||
    die "Invalid WG_NETWORK CIDR format: $cidr (expected A.B.C.D/N)"
  local pfx="${BASH_REMATCH[2]}"
  [[ "$pfx" -ge 16 && "$pfx" -le 30 ]] ||
    die "WG_NETWORK prefix /$pfx out of range (must be /16–/30)"
  local IFS='.' octets
  read -ra octets <<<"${BASH_REMATCH[1]}"
  local o
  for o in "${octets[@]}"; do
    [[ "$o" -le 255 ]] || die "Invalid octet $o in WG_NETWORK: $cidr"
  done
}

# Non-fatal heuristic: warn if WC_NETWORK overlaps with an existing non-WireGuard
# route on the HUB host. Uses `ip -4 route show` via wc_ssh_exec when the hub is
# remote, or a local shell when it is localhost. Silently skipped if `ip` is
# unavailable or anything errors out — this is advisory only.
wc_warn_if_network_collides() {
  local net="$WC_NETWORK"
  [[ -n "$net" ]] || return 0
  [[ -n "${WC_HUB_SSH_TARGET:-}" ]] || return 0

  local probe_cmd
  probe_cmd='command -v ip >/dev/null 2>&1 && ip -4 route show 2>/dev/null || true'

  local out=""
  if wc_is_local_execution_target "$WC_HUB_SSH_TARGET"; then
    out="$(bash -c "$probe_cmd" 2>/dev/null || true)"
  else
    local port
    port="$(wc_ssh_port_for_target "$WC_HUB_SSH_TARGET")"
    # shellcheck disable=SC2086
    out="$(ssh ${WC_SSH_OPTS:-} ${WC_SSH_HOSTKEY_OPTS:-} -p "$port" \
      -o BatchMode=yes -o ConnectTimeout=8 "$WC_HUB_SSH_TARGET" \
      "bash -lc $(printf '%q' "$probe_cmd")" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || return 0

  local line dest dev suggest
  while IFS= read -r line; do
    [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+) ]] || continue
    dest="${BASH_REMATCH[1]}"
    [[ "$dest" == "$net" ]] || continue
    dev="${line##*dev }"
    dev="${dev%% *}"
    case "$dev" in
      "$WC_IFACE" | wg* | utun* ) continue ;;  # ours or a tunnel iface
    esac
    suggest="${net%.*}"
    suggest="${suggest%.*}.$(( ${net##*.} / 256 * 256 + 1 )).0/24"
    log_warn "WG_NETWORK ${net} overlaps an existing route on ${WC_HUB_SSH_TARGET} (dev ${dev:-unknown}); pick a different range with --network (e.g. 10.201.0.0/24) or set WG_NETWORK."
    return 0
  done <<<"$out"
  return 0
}

# Peer count (excluding hub)
wc_peer_count() {
  echo $((${#WC_SSH_TARGETS[@]} - 1))
}

any_full_tunnel_peer() {
  local i
  for ((i = 1; i < ${#WC_FULL_TUNNEL[@]}; i++)); do
    [[ "${WC_FULL_TUNNEL[$i]}" == "yes" ]] && return 0
  done
  return 1
}

# True if any inventory peer (line index >= 1) is not localhost.
wc_any_remote_peer() {
  local i
  for ((i = 1; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    is_local_host "${WC_SSH_TARGETS[$i]}" || return 0
  done
  return 1
}

# A hub host is "obviously reachable" as a WireGuard Endpoint= when it is an
# IP address (v4/v6) or looks like an FQDN (contains a dot). Single-label names
# like `hub` or `gateway` usually only resolve inside the operator's /etc/hosts
# or LAN DNS — worth warning about.
wc_hub_endpoint_is_obviously_reachable() {
  local host="$1"
  host="${host##*@}"
  host="${host%%:*}"
  [[ -n "$host" ]] || return 1
  case "$host" in
    *:*) return 0 ;;  # IPv6 literal
  esac
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 0
  fi
  [[ "$host" == *.* ]]
}

# When WG_HUB_ENDPOINT / -H is unset and a remote peer exists, set WC_HUB_ENDPOINT
# to the inventory hub host (first line). Returns 0 if this default was applied
# AND the inferred endpoint is not obviously reachable (i.e., callers should warn).
# Returns 1 if the endpoint was already set OR the inferred value is obviously
# usable OR there are no remote peers.
wc_resolve_hub_endpoint_from_inventory() {
  [[ -n "$WC_HUB_ENDPOINT" ]] && return 1
  wc_any_remote_peer || return 1
  [[ -n "${WC_HUB_SSH_TARGET:-}" ]] || die "Inventory hub (first line) missing for default WireGuard endpoint"
  WC_HUB_ENDPOINT="$(wc_wireguard_endpoint_host "$WC_HUB_SSH_TARGET")"
  wc_hub_endpoint_is_obviously_reachable "$WC_HUB_ENDPOINT" && return 1
  return 0
}

wc_require_hub_endpoint_for_apply() {
  wc_resolve_hub_endpoint_from_inventory || true
  local i
  for ((i = 1; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    if ! is_local_host "${WC_SSH_TARGETS[$i]}"; then
      [[ -n "$WC_HUB_ENDPOINT" ]] || die "WG_HUB_ENDPOINT or --hub-endpoint required when peers are remote (inventory hub host unavailable)"
      return 0
    fi
  done
  return 0
}
