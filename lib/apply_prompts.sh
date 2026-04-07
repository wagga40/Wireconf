#!/usr/bin/env bash
# shellcheck shell=bash
# Action log, interactive apply prompts, removed-host teardown (depends on common.sh, systemd.sh).

WC_LOG_FILE=""

# Append one line: YYYY-MM-DDTHH:MM:SS ACTION key=value ...
wc_log_action() {
  [[ -n "${WC_LOG_FILE:-}" ]] || WC_LOG_FILE="${WC_INVENTORY}.wireconf.log"
  local ts action
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  action="$1"
  shift
  printf '%s %s %s\n' "$ts" "$action" "$*" >>"$WC_LOG_FILE"
}

# Build comma-separated host list from WC_SSH_TARGETS (for log lines).
wc_log_hosts_csv() {
  local IFS=','
  printf '%s' "${WC_SSH_TARGETS[*]}"
}

# Populate WC_APPLY_PREV_TARGETS from the last "apply" line in the action log.
# Falls back to legacy *.wireconf.last-targets if the log does not exist yet.
wc_log_read_last_apply() {
  WC_APPLY_PREV_TARGETS=()
  [[ -n "${WC_LOG_FILE:-}" ]] || WC_LOG_FILE="${WC_INVENTORY}.wireconf.log"

  if [[ -f "$WC_LOG_FILE" ]]; then
    local last hosts
    last="$(grep '^[^ ]* apply ' "$WC_LOG_FILE" | tail -1)" || true
    if [[ -n "$last" ]]; then
      hosts="${last##*hosts=}"
      hosts="${hosts%% *}"
      if [[ -n "$hosts" ]]; then
        IFS=',' read -r -a WC_APPLY_PREV_TARGETS <<<"$hosts"
      fi
    fi
    return 0
  fi

  # Migration: read legacy snapshot if present.
  local legacy="${WC_INVENTORY}.wireconf.last-targets"
  if [[ -f "$legacy" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
      WC_APPLY_PREV_TARGETS+=("$line")
    done <"$legacy"
  fi
}

# Remove legacy snapshot after a successful log write (one-time migration).
wc_log_cleanup_legacy() {
  local legacy="${WC_INVENTORY}.wireconf.last-targets"
  [[ -f "$legacy" ]] && rm -f -- "$legacy"
  return 0
}

wc_apply_prev_contains_host() {
  local h="$1" p
  for p in "${WC_APPLY_PREV_TARGETS[@]}"; do
    [[ "$p" == "$h" ]] && return 0
  done
  return 1
}

wc_apply_collect_new_peers() {
  WC_APPLY_NEW_PEER_LIST=()
  local i
  for ((i = 1; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    wc_apply_prev_contains_host "${WC_SSH_TARGETS[$i]}" || WC_APPLY_NEW_PEER_LIST+=("${WC_SSH_TARGETS[$i]}")
  done
}

wc_apply_current_contains_host() {
  local h="$1" t
  for t in "${WC_SSH_TARGETS[@]}"; do
    [[ "$t" == "$h" ]] && return 0
  done
  return 1
}

# Hosts in last-apply log but not in current inventory.
wc_apply_collect_removed_hosts() {
  WC_APPLY_REMOVED_TARGETS=()
  local p
  for p in "${WC_APPLY_PREV_TARGETS[@]}"; do
    wc_apply_current_contains_host "$p" || WC_APPLY_REMOVED_TARGETS+=("$p")
  done
}

wc_apply_teardown_removed_hosts() {
  local t
  [[ ${#WC_APPLY_REMOVED_TARGETS[@]} -gt 0 ]] || return 0
  log_info "Teardown on host(s) removed from inventory: ${WC_APPLY_REMOVED_TARGETS[*]}"
  for t in "${WC_APPLY_REMOVED_TARGETS[@]}"; do
    log_info "Stopping ${WC_IFACE} on ${t}..."
    wg_teardown_on_host "$t" "$WC_FORCE"
    if [[ "$WC_FORCE" -eq 1 ]]; then
      log_detail "${t}: removed /etc/wireguard/${WC_IFACE}.conf"
    fi
  done
  local IFS=','
  wc_log_action teardown-removed "iface=${WC_IFACE} hosts=${WC_APPLY_REMOVED_TARGETS[*]}"
}

# stdout: "yes"/"no" for config-exists and iface-up.
wc_apply_probe_host_state() {
  local target="$1"
  local conf="/etc/wireguard/${WC_IFACE}.conf"
  local exists iface_up
  exists="$(wc_run_sudo_quiet "$target" "test -f $(printf '%q' "$conf") && echo yes || echo no" 2>/dev/null)" || exists="unreachable"
  iface_up="$(wc_run_sudo_quiet "$target" "wg show $(printf '%q' "$WC_IFACE") >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)" || iface_up="unreachable"
  printf '%s %s\n' "$exists" "$iface_up"
}

# Sets WC_APPLY_BRING_UP[i]; returns 1 if user cancels apply entirely.
wc_apply_prepare_prompts() {
  WC_APPLY_BRING_UP=()
  local i n="${#WC_SSH_TARGETS[@]}"
  for ((i = 0; i < n; i++)); do
    WC_APPLY_BRING_UP+=(1)
  done

  wc_log_read_last_apply

  if [[ "${WC_ASSUME_YES:-0}" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 2 ]]; then
    log_err "apply: need an interactive terminal (stderr) for apply prompts, or use -y / WIRECONF_YES=1"
    exit 1
  fi

  local asked=0 st exists iface_up autostart
  autostart="$(normalize_bool "$WC_AUTO_START")"

  if [[ ${#WC_APPLY_PREV_TARGETS[@]} -gt 0 ]]; then
    wc_apply_collect_new_peers
    if [[ ${#WC_APPLY_NEW_PEER_LIST[@]} -gt 0 ]]; then
      asked=1
      log_info "New peer(s) since last apply: ${WC_APPLY_NEW_PEER_LIST[*]}"
      if ! wireconf_prompt_yes "Regenerate keys and refresh the hub and every host? (required for mesh consistency when adding peers)"; then
        log_info "apply: cancelled."
        return 1
      fi
    fi
  fi

  for ((i = 0; i < n; i++)); do
    st="$(wc_apply_probe_host_state "${WC_SSH_TARGETS[$i]}")"
    exists="${st%% *}"
    iface_up="${st#* }"
    if [[ "$exists" == "unreachable" || "$iface_up" == "unreachable" ]]; then
      die "apply: could not probe WireGuard state on ${WC_SSH_TARGETS[$i]} (sudo/SSH)."
    fi
    if [[ "$iface_up" == "yes" ]]; then
      asked=1
      if ! wireconf_prompt_yes "${WC_SSH_TARGETS[$i]}: ${WC_IFACE} is up. Take it down, replace the config, and bring it back up?"; then
        log_info "apply: cancelled."
        return 1
      fi
      WC_APPLY_BRING_UP[i]=1
    elif [[ "$exists" == "yes" && "$iface_up" == "no" ]]; then
      if [[ "$autostart" == "yes" ]]; then
        log_info "${WC_SSH_TARGETS[$i]}: config present, ${WC_IFACE} down — will enable and restart wg-quick@${WC_IFACE} (AUTO_START=yes)."
        WC_APPLY_BRING_UP[i]=1
      else
        asked=1
        if wireconf_prompt_yes "${WC_SSH_TARGETS[$i]}: config exists but ${WC_IFACE} is down. Bring the tunnel up after deploying the new config?"; then
          WC_APPLY_BRING_UP[i]=1
        else
          WC_APPLY_BRING_UP[i]=0
          log_info "${WC_SSH_TARGETS[$i]}: new config will be installed; ${WC_IFACE} will stay down until you run wg-quick up."
        fi
      fi
    fi
  done

  if [[ "$asked" -eq 0 ]]; then
    log_info "Ready to deploy WireGuard (${WC_IFACE}, ${WC_NETWORK}, UDP/${WC_PORT}) to ${n} host(s); inventory: ${WC_INVENTORY}"
    if ! wireconf_prompt_yes "Proceed with apply?"; then
      log_info "apply: cancelled."
      return 1
    fi
  fi
  # Interactive apply already confirmed replace/start; skip duplicate preflight WARN (read in preflight.sh).
  # shellcheck disable=SC2034
  WC_APPLY_PREFLIGHT_QUIET=1
  return 0
}
