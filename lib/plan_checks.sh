#!/usr/bin/env bash
# shellcheck shell=bash
# Plan (and apply) pre-checks: operator basics, SSH, Debian/Ubuntu OS, WireGuard, target tools.

# True if /etc/os-release looks like Debian or Ubuntu (including ID_LIKE e.g. pop, mint).
plan_target_is_debian_family() {
  local target="$1"
  wc_run_sudo "$target" 'test -r /etc/os-release && {
      grep -qE "^ID=(debian|ubuntu)$" /etc/os-release ||
      grep -qE "^ID_LIKE=.*(debian|ubuntu)" /etc/os-release
    }' 2>/dev/null
}

plan_target_missing_wg_tools() {
  local target="$1"
  wc_run_sudo_quiet "$target" "command -v bash >/dev/null" 2>/dev/null || return 1
  ! wc_run_sudo_quiet "$target" "command -v wg >/dev/null && command -v wg-quick >/dev/null" 2>/dev/null
}

plan_install_wireguard_apt() {
  local target="$1"
  log_info "Running apt on ${target} to install wireguard..."
  wc_run_sudo "$target" "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y wireguard"
}

# Offer interactive (or -y) install when wg/wg-quick missing. Assumes host is Debian-family.
plan_try_offer_install_wireguard() {
  local target="$1"
  if wc_run_sudo_quiet "$target" "command -v wg >/dev/null && command -v wg-quick >/dev/null" 2>/dev/null; then
    return 0
  fi
  if ! wireconf_prompt_yes "Install package wireguard (apt) on ${target}?"; then
    log_err "WireGuard not installed on ${target}."
    log_detail "Install manually: sudo apt-get update && sudo apt-get install -y wireguard"
    log_detail "Non-interactive: use -y / --yes or WIRECONF_YES=1 to install without prompting."
    return 1
  fi
  plan_install_wireguard_apt "$target" || return 1
  if ! wc_run_sudo_quiet "$target" "command -v wg >/dev/null && command -v wg-quick >/dev/null" 2>/dev/null; then
    log_err "wg / wg-quick still missing on ${target} after apt install."
    return 1
  fi
  log_info "WireGuard tools are available on ${target}."
  return 0
}

plan_check_debian_family_all() {
  local i t
  log_info "Verifying Debian/Ubuntu on each inventory host (wireconf targets this family only)..."
  for ((i = 0; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    t="${WC_SSH_TARGETS[$i]}"
    if plan_target_is_debian_family "$t"; then
      log_detail_ok "${t}"
    else
      log_err "${t} is not Debian/Ubuntu (check /etc/os-release). Wireconf only supports Debian-family hosts."
      return 1
    fi
  done
}

plan_check_operator_basics() {
  local missing=()
  local c
  for c in ssh scp awk bash; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    log_err "On this machine, missing commands: ${missing[*]}"
    return 1
  fi
  log_info "Operator: ssh, scp, awk, bash OK."
  return 0
}

# Sets WC_KEYGEN_MODE; may install wireguard on hub (localhost or remote) after prompt.
plan_check_operator_wg_keygen() {
  if command -v wg >/dev/null 2>&1; then
    WC_KEYGEN_MODE=local
    log_info "WireGuard key generation: local (wg found on operator)."
    return 0
  fi

  WC_KEYGEN_MODE=remote_hub
  local ht="${WC_SSH_TARGETS[0]}"
  local hp="${WC_SSH_PORTS[0]}"

  if is_local_host "$ht"; then
    log_warn "No wg on operator and hub is localhost — need WireGuard tools on this machine."
    if ! plan_try_offer_install_wireguard "localhost"; then
      return 1
    fi
    WC_KEYGEN_MODE=local
    log_info "WireGuard key generation: local."
    return 0
  fi

  log_info "No local wg; keys will be generated on hub ${ht} (SSH)."
  if ! wc_ssh_exec "$ht" "$hp" "command -v wg >/dev/null && wg genkey | wg pubkey >/dev/null" 2>/dev/null; then
    if ! plan_try_offer_install_wireguard "$ht"; then
      return 1
    fi
  fi
  if ! wc_ssh_exec "$ht" "$hp" "command -v wg >/dev/null && wg genkey | wg pubkey >/dev/null" 2>/dev/null; then
    log_err "Hub ${ht} still has no working wg after install attempt."
    return 1
  fi
  return 0
}

plan_check_ssh_connectivity() {
  local i t p
  log_info "SSH connectivity (BatchMode):"
  for ((i = 0; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    t="${WC_SSH_TARGETS[$i]}"
    p="${WC_SSH_PORTS[$i]}"
    if is_local_host "$t"; then
      log_detail "${t}  (local, no ssh)"
      continue
    fi
    if wc_ssh_exec "$t" "$p" "true" >/dev/null 2>&1; then
      log_detail_ok "${t}  port ${p}"
    else
      log_err "SSH failed: ${t} (port ${p})"
      log_detail "If this host is new: use --ssh-accept-new or SSH_ACCEPT_NEW=yes to add its key to known_hosts, or ssh once: ssh -p ${p} ${t}"
      log_detail "Otherwise check SSH port (inventory column, SSH_PORT / --ssh-port) and that ssh-agent or keys match this user@host."
      return 1
    fi
  done
}

plan_check_target_tools() {
  local i t need_ipt
  log_info "Target tool availability (via sudo):"
  need_ipt=0
  any_full_tunnel_peer && need_ipt=1
  for ((i = 0; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    t="${WC_SSH_TARGETS[$i]}"
    if ! plan_check_target_tools_one "$t" "$i" "$need_ipt"; then
      if plan_target_missing_wg_tools "$t"; then
        if plan_try_offer_install_wireguard "$t"; then
          plan_check_target_tools_one "$t" "$i" "$need_ipt" || {
            log_err "Tool check still failing on ${t} after installing WireGuard."
            return 1
          }
        else
          return 1
        fi
      else
        log_err "Tool check failed on ${t}"
        return 1
      fi
    fi
    log_detail_ok "$t"
  done
}

# Args: target, index, hub_needs_nat (1 if any full-tunnel peer)
plan_check_target_tools_one() {
  local target="$1"
  local idx="$2"
  local hub_nat="$3"
  local req="wg wg-quick ip systemctl ping bash"
  [[ "$idx" -eq 0 && "$hub_nat" -eq 1 ]] && req="$req iptables sysctl"
  wc_run_sudo_quiet "$target" "for x in $req; do command -v \"\$x\" >/dev/null || { echo \"missing: \$x\" >&2; exit 1; }; done"
}
