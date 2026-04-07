#!/usr/bin/env bash
# shellcheck shell=bash
# Connectivity checks: recent WireGuard handshakes and hub -> peer ping.

verify_all() {
  local i hub="${WC_SSH_TARGETS[0]}"
  wc_resolve_hub_endpoint_from_inventory || true
  log_info "Checking WireGuard handshakes on each host..."
  for ((i = 0; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    verify_handshakes "${WC_SSH_TARGETS[$i]}"
  done
  log_info "Pinging peer VPN addresses from hub (${hub})..."
  for ((i = 1; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    verify_ping_peer "$hub" "${WC_INDEX_TO_IP[$i]}"
  done
  verify_print_topology_schema
  log_info "Verify finished OK."
}

verify_box_border() {
  local fill="$1"
  local width="$2"
  local bar
  printf -v bar '%*s' "$width" ''
  bar="${bar// /$fill}"
  printf '+%s+' "$bar"
}

verify_box_line() {
  local text="$1"
  local width="$2"
  printf '| %-*s |' "$width" "$text"
}

verify_box_center_line() {
  local text="$1"
  local width="$2"
  local pad_left pad_right
  pad_left=$(((width - ${#text}) / 2))
  (( pad_left < 0 )) && pad_left=0
  pad_right=$((width - ${#text} - pad_left))
  (( pad_right < 0 )) && pad_right=0
  printf '| %*s%s%*s |' "$pad_left" '' "$text" "$pad_right" ''
}

# ASCII schema: hub-and-spoke from inventory + addressing (after checks pass).
verify_print_topology_schema() {
  local i n="${#WC_SSH_TARGETS[@]}"
  local hub="${WC_SSH_TARGETS[0]}"
  local mode
  local width=57
  local line
  printf '\n' >&2
  log_info "Topology schema (hub-and-spoke, ${WC_NETWORK}):"
  log_detail ""
  line="$(verify_box_border "=" "$width")"
  log_detail_centered "$line"
  line="$(verify_box_center_line "HUB" "$width")"
  log_detail_centered "$line"
  line="$(verify_box_line "VPN ${WC_INDEX_TO_IP[0]}  dev ${WC_IFACE}" "$width")"
  log_detail_centered "$line"
  line="$(verify_box_line "SSH ${hub} port ${WC_SSH_PORTS[0]}" "$width")"
  log_detail_centered "$line"
  line="$(verify_box_line "WG listen UDP/${WC_PORT}  (peers use Endpoint)" "$width")"
  log_detail_centered "$line"
  line="$(verify_box_line "Endpoint ${WC_HUB_ENDPOINT:-<unset>}" "$width")"
  log_detail_centered "$line"
  line="$(verify_box_border "=" "$width")"
  log_detail_centered "$line"
  log_detail_centered "|"
  log_detail_centered "(star / no mesh)"
  log_detail_centered "|"
  for ((i = 1; i < n; i++)); do
    mode="split-tunnel  AllowedIPs=${WC_NETWORK}"
    [[ "${WC_FULL_TUNNEL[$i]}" == "yes" ]] && mode="full-tunnel  AllowedIPs=0.0.0.0/0"
    line="$(verify_box_border "-" "$width")"
    log_detail_centered "$line"
    line="$(verify_box_center_line "PEER ${i}" "$width")"
    log_detail_centered "$line"
    line="$(verify_box_line "VPN ${WC_INDEX_TO_IP[$i]}" "$width")"
    log_detail_centered "$line"
    line="$(verify_box_line "SSH ${WC_SSH_TARGETS[$i]} port ${WC_SSH_PORTS[$i]}" "$width")"
    log_detail_centered "$line"
    line="$(verify_box_line "${mode}" "$width")"
    log_detail_centered "$line"
    line="$(verify_box_border "-" "$width")"
    log_detail_centered "$line"
  done
  line="$(verify_box_line "Peers do not WG-talk to each other" "$width")"
  log_detail_centered "$line"
  line="$(verify_box_border "=" "$width")"
  log_detail_centered "$line"
  printf '\n' >&2
}

verify_handshakes() {
  local target="$1"
  local now age pk t raw threshold
  threshold="${WC_HANDSHAKE_TIMEOUT:-300}"
  now="$(date +%s)"
  raw="$(wc_run_sudo "$target" "wg show $(printf '%q' "$WC_IFACE") latest-handshakes 2>/dev/null" || true)"
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    die "No WireGuard data on $target (interface ${WC_IFACE} down?)"
  fi
  while read -r pk t; do
    [[ -z "${pk:-}" ]] && continue
    [[ -z "${t:-}" ]] && continue
    if [[ "$t" -eq 0 ]]; then
      die "No handshake yet on $target for peer ${pk:0:16}..."
    fi
    age=$((now - t))
    if [[ "$age" -gt "$threshold" ]]; then
      die "Stale handshake on $target (age ${age}s, threshold ${threshold}s) for peer ${pk:0:16}..."
    fi
  done < <(printf '%s\n' "$raw")
  log_info "Handshakes on $target look recent."
}

verify_ping_peer() {
  local hub_target="$1"
  local ip="$2"
  wc_run_sudo "$hub_target" "ping -c 3 -w 5 $(printf '%q' "$ip") >/dev/null"
  log_info "Hub reached peer VPN IP ${ip}"
}

# Non-fatal status: reports per-host state without dying on problems.
status_all() {
  local i hub="${WC_SSH_TARGETS[0]}" failures=0
  local threshold="${WC_HANDSHAKE_TIMEOUT:-300}"
  wc_resolve_hub_endpoint_from_inventory || true
  log_info "Checking interface status on each host..."
  for ((i = 0; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    status_one_host "${WC_SSH_TARGETS[$i]}" "$threshold" || failures=$((failures + 1))
  done
  printf '\n' >&2
  log_info "Pinging peer VPN addresses from hub (${hub})..."
  for ((i = 1; i < ${#WC_SSH_TARGETS[@]}; i++)); do
    if wc_run_sudo "$hub" "ping -c 1 -w 3 $(printf '%q' "${WC_INDEX_TO_IP[$i]}") >/dev/null 2>&1"; then
      log_detail_ok "hub -> ${WC_INDEX_TO_IP[$i]} (${WC_SSH_TARGETS[$i]})"
    else
      log_err "hub -> ${WC_INDEX_TO_IP[$i]} (${WC_SSH_TARGETS[$i]}) UNREACHABLE"
      failures=$((failures + 1))
    fi
  done
  verify_print_topology_schema
  if [[ "$failures" -gt 0 ]]; then
    log_warn "status: ${failures} issue(s) detected."
    return 1
  fi
  log_info "status: all hosts healthy."
}

status_one_host() {
  local target="$1" threshold="$2"
  local now age pk t raw iface_up
  now="$(date +%s)"
  iface_up="$(wc_run_sudo "$target" "wg show $(printf '%q' "$WC_IFACE") >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)" || iface_up="unreachable"
  if [[ "$iface_up" == "unreachable" ]]; then
    log_err "${target}  interface=${WC_IFACE}  status=unreachable"
    return 1
  fi
  if [[ "$iface_up" != "yes" ]]; then
    log_warn "${target}  interface=${WC_IFACE}  status=down"
    return 1
  fi
  raw="$(wc_run_sudo "$target" "wg show $(printf '%q' "$WC_IFACE") latest-handshakes 2>/dev/null" || true)"
  if [[ -z "${raw//[[:space:]]/}" ]]; then
    log_warn "${target}  interface=${WC_IFACE}  status=up  handshakes=none"
    return 1
  fi
  local ok=0 stale=0 none=0
  while read -r pk t; do
    [[ -z "${pk:-}" ]] && continue
    [[ -z "${t:-}" ]] && continue
    if [[ "$t" -eq 0 ]]; then
      none=$((none + 1)); continue
    fi
    age=$((now - t))
    if [[ "$age" -gt "$threshold" ]]; then
      stale=$((stale + 1))
    else
      ok=$((ok + 1))
    fi
  done < <(printf '%s\n' "$raw")
  local summary="up  peers: ${ok} ok"
  [[ "$stale" -gt 0 ]] && summary="${summary}, ${stale} stale"
  [[ "$none" -gt 0 ]] && summary="${summary}, ${none} no-handshake"
  if [[ "$stale" -gt 0 || "$none" -gt 0 ]]; then
    log_warn "${target}  interface=${WC_IFACE}  ${summary}"
    return 1
  fi
  log_detail_ok "${target}  interface=${WC_IFACE}  ${summary}"
  return 0
}
