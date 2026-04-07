#!/usr/bin/env bash
# shellcheck shell=bash
# Atomic add/remove of inventory lines (peer helpers). Depends on common.sh.

# Args: inventory path, then HOST [ssh_port|tunnel] [tunnel] (same rules as inventory lines).
inventory_peer_add() {
  local inv="$1"
  shift
  [[ $# -ge 1 ]] || die "add-peer: need HOST [ssh_port|tunnel] [tunnel]"
  local new_line="$*"
  local host _p _f
  parse_inventory_line "$new_line" "$WC_SSH_PORT_DEFAULT" "$(normalize_bool "$WC_FULL_TUNNEL_DEFAULT")" host _p _f

  parse_inventory_relaxed "$inv"
  local h
  for h in "${WC_SSH_TARGETS[@]}"; do
    [[ "$h" != "$host" ]] || die "add-peer: host already in inventory: $host"
  done

  local dir tmp last
  dir="$(dirname -- "$inv")"
  tmp="$(mktemp "${dir}/.wireconf-inv.XXXXXX")" || die "add-peer: mktemp failed"
  # shellcheck disable=SC2064
  trap 'rm -f -- "$tmp"' EXIT

  {
    if [[ -f "$inv" ]] && [[ -s "$inv" ]]; then
      last="$(tail -c1 "$inv" 2>/dev/null || true)"
      cat "$inv"
      if [[ -n "$last" && "$last" != $'\n' ]]; then
        printf '\n'
      fi
    fi
    printf '%s\n' "$new_line"
  } >"$tmp"

  parse_inventory_relaxed "$tmp"
  mv -f -- "$tmp" "$inv"
  trap - EXIT
  log_info "add-peer: appended to ${inv}: ${new_line}"
  if [[ "${#WC_SSH_TARGETS[@]}" -lt 2 ]]; then
    log_warn "add-peer: inventory still needs hub plus at least one peer before plan/apply (currently ${#WC_SSH_TARGETS[@]} host line(s))."
  fi
}

# Args: inventory path, HOST (first field of line to remove; must not be hub; must leave hub + one peer).
inventory_peer_remove() {
  local inv="$1"
  local want="$2"
  [[ -n "$want" ]] || die "remove-peer: need HOST (first field of the line to remove)"
  [[ $# -eq 2 ]] || die "remove-peer: extra arguments"

  parse_inventory "$inv"
  local n="${#WC_SSH_TARGETS[@]}"
  [[ "$n" -ge 2 ]] || die "remove-peer: inventory must have hub and at least one peer"

  local idx=-1 i host _p _f
  for ((i = 0; i < n; i++)); do
    if [[ "${WC_SSH_TARGETS[$i]}" == "$want" ]]; then
      idx=$i
      break
    fi
  done
  [[ "$idx" -ge 0 ]] || die "remove-peer: no inventory line with host: $want"
  [[ "$idx" -ne 0 ]] || die "remove-peer: cannot remove hub (first host line)"
  [[ "$n" -gt 2 ]] || die "remove-peer: cannot remove last peer (need hub + at least one peer)"

  local dir tmp removed=0 line
  dir="$(dirname -- "$inv")"
  tmp="$(mktemp "${dir}/.wireconf-inv.XXXXXX")" || die "remove-peer: mktemp failed"
  # shellcheck disable=SC2064
  trap 'rm -f -- "$tmp"' EXIT

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
      printf '%s\n' "$line"
      continue
    fi
    parse_inventory_line "$line" "$WC_SSH_PORT_DEFAULT" "$(normalize_bool "$WC_FULL_TUNNEL_DEFAULT")" host _p _f || {
      printf '%s\n' "$line"
      continue
    }
    if [[ "$host" == "$want" && "$removed" -eq 0 ]]; then
      removed=1
      continue
    fi
    printf '%s\n' "$line"
  done <"$inv" >"$tmp"

  [[ "$removed" -eq 1 ]] || die "remove-peer: line not removed (internal error)"

  parse_inventory "$tmp"
  mv -f -- "$tmp" "$inv"
  trap - EXIT
  log_info "remove-peer: removed ${want} from ${inv}"
}
