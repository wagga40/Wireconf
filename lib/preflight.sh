#!/usr/bin/env bash
# shellcheck shell=bash
# Preflight: existing WireGuard config / interface checks, optional backup.

preflight_all_hosts() {
  local i t
  for ((i = 0; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    t="${WC_SSH_TARGETS[$i]}"
    preflight_one_host "$t"
  done
}

preflight_one_host() {
  local target="$1"
  local conf="/etc/wireguard/${WC_IFACE}.conf"
  local exists iface_up

  exists="$(wc_run_sudo "$target" "test -f $(printf '%q' "$conf") && echo yes || echo no")"
  iface_up="$(wc_run_sudo "$target" "wg show $(printf '%q' "$WC_IFACE") >/dev/null 2>&1 && echo yes || echo no")"

  if [[ "$exists" == "yes" || "$iface_up" == "yes" ]]; then
    if [[ "$WC_FORCE" -eq 1 ]]; then
      log_warn "Overwriting existing WireGuard state on $target ($conf / interface up=$iface_up) due to --force"
      return 0
    fi
    if [[ -n "$WC_BACKUP_DIR" ]]; then
      local ts dir
      ts="$(date +%Y%m%d%H%M%S)"
      dir="${WC_BACKUP_DIR%/}/$target/$ts"
      log_info "Backing up WireGuard files on $target to $dir"
      wc_run_sudo "$target" "mkdir -p $(printf '%q' "$dir")"
      if [[ "$exists" == "yes" ]]; then
        wc_run_sudo "$target" "cp -a $(printf '%q' "$conf") $(printf '%q' "$dir/")" || true
      fi
      wc_run_sudo "$target" "shopt -s nullglob; for f in /etc/wireguard/${WC_IFACE}*.key; do cp -a \"\$f\" $(printf '%q' "$dir/"); done" || true
      return 0
    fi
    # apply always runs wg-quick down then replaces config; re-apply after inventory changes is expected.
    if [[ "${WC_APPLY_PREFLIGHT_QUIET:-0}" -eq 1 ]]; then
      return 0
    fi
    log_warn "Existing WireGuard on $target (config present=$exists, ${WC_IFACE} up=$iface_up); apply will take the interface down and install the new config. Use --backup-dir DIR to save a copy first."
    return 0
  fi
}

preflight_plan_hint() {
  local target="$1"
  local conf="/etc/wireguard/${WC_IFACE}.conf"
  local exists iface_up
  exists="$(wc_run_sudo "$target" "test -f $(printf '%q' "$conf") && echo yes || echo no" 2>/dev/null)" || exists="unreachable"
  iface_up="$(wc_run_sudo "$target" "wg show $(printf '%q' "$WC_IFACE") >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)" || iface_up="unreachable"
  echo "$exists $iface_up"
}
