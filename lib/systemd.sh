#!/usr/bin/env bash
# shellcheck shell=bash
# Enable or disable wg-quick@ on target hosts.

# Stop/disable unit, wg-quick down; optional remove conf (force_rm=1). Used by teardown and apply (removed peers).
wg_teardown_on_host() {
  local target="$1"
  local force_rm="${2:-0}"
  local unit="wg-quick@${WC_IFACE}.service"
  wc_run_sudo "$target" "systemctl disable --now $(printf '%q' "$unit") 2>/dev/null || true"
  wc_run_sudo "$target" "wg-quick down $(printf '%q' "$WC_IFACE") 2>/dev/null || true"
  if [[ "$force_rm" -eq 1 ]]; then
    wc_run_sudo "$target" "rm -f $(printf '%q' "/etc/wireguard/${WC_IFACE}.conf")" 2>/dev/null || true
  fi
}

wg_systemd_set_autostart() {
  local target="$1"
  local want="$2"
  local unit="wg-quick@${WC_IFACE}.service"
  if [[ "$want" == "yes" ]]; then
    # enable --now does not restart an already-active unit; after wg-quick down the iface is often
    # down while systemd still shows active, so new /etc/wireguard config would not load. Restart applies it.
    wc_run_sudo "$target" "systemctl enable $(printf '%q' "$unit") && systemctl restart $(printf '%q' "$unit")"
  else
    wc_run_sudo "$target" "systemctl disable --now $(printf '%q' "$unit") 2>/dev/null || true"
  fi
}
