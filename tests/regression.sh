#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load wireconf as a library. Works against both the source tree (which sources
# lib/*.sh from disk) and a single-file build (with libs inlined).
# shellcheck disable=SC2034
WIRECONF_SOURCE_ONLY=1
# shellcheck source=/dev/null
source "$ROOT/wireconf"
unset WIRECONF_SOURCE_ONLY

pass_count=0
fail_count=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local want="$1" got="$2" msg="$3"
  [[ "$want" == "$got" ]] || fail "$msg (want=$want got=$got)"
}

assert_ok() {
  local msg="$1"
  shift
  "$@" >/dev/null 2>&1 || fail "$msg"
}

assert_not_ok() {
  local msg="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$msg"
  fi
}

run_test() {
  local name="$1"
  if "$name"; then
    printf 'PASS: %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf 'FAIL: %s\n' "$name" >&2
    fail_count=$((fail_count + 1))
  fi
}

reset_wireconf_globals() {
  WC_INVENTORY=""
  WC_INVENTORY_EXPLICIT=0
  WC_LOG_FILE=""
  WC_IFACE="wg0"
  WC_NETWORK="10.200.0.0/24"
  WC_PORT="51820"
  WC_HUB_ENDPOINT=""
  WC_HUB_SSH_TARGET=""
  WC_AUTO_START="no"
  WC_FULL_TUNNEL_DEFAULT="no"
  WC_PARALLEL=1
  WC_ASSUME_YES=0
  WC_FORCE=0
  WC_HANDSHAKE_TIMEOUT=300
  WC_SSH_PORT_DEFAULT=22
  WC_SSH_TARGETS=()
  WC_SSH_PORTS=()
  WC_FULL_TUNNEL=()
  WC_APPLY_PREV_TARGETS=()
  WC_APPLY_REMOVED_TARGETS=()
  WC_APPLY_BRING_UP=()
  if declare -p WC_SSH_PORT_HINTS >/dev/null 2>&1; then
    WC_SSH_PORT_HINTS=()
  fi
  WC_DOCTOR_TOTAL_CHECKS=0
  WC_DOCTOR_FAILED_CHECKS=0
  WC_DOCTOR_FAILED_HOSTS=0
}

test_endpoint_defaults_strip_ssh_user() {
  reset_wireconf_globals
  WC_SSH_TARGETS=("root@hub.example.com" "peer.example.com")
  WC_HUB_SSH_TARGET="${WC_SSH_TARGETS[0]}"
  WC_HUB_ENDPOINT=""
  wc_resolve_hub_endpoint_from_inventory >/dev/null
  assert_eq "hub.example.com" "$WC_HUB_ENDPOINT" "default endpoint should strip ssh username"
}

test_ip_allocator_rejects_broadcast_capacity() {
  assert_not_ok "/30 must not allow three hosts" wg_allocate_ips "10.0.0.0/30" 3
  assert_not_ok "/24 must reject assigning the broadcast address" wg_allocate_ips "10.0.0.0/24" 255
  assert_ok "/24 should still allow 254 hosts" wg_allocate_ips "10.0.0.0/24" 254
}

test_removed_host_uses_saved_ssh_port_hint() {
  reset_wireconf_globals
  local tmpdir
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wireconf-test.XXXXXX")"

  WC_INVENTORY="$tmpdir/inventory"
  WC_LOG_FILE="${WC_INVENTORY}.wireconf.log"
  printf '%s\n' '2026-04-07T12:00:00Z apply iface=wg0 hosts=hub,oldpeer' >"$WC_LOG_FILE"
  printf '%s\n' $'hub\t22' $'oldpeer\t2222' >"${WC_INVENTORY}.wireconf.last-state"
  WC_SSH_TARGETS=("hub" "newpeer")
  WC_SSH_PORTS=(22 22)

  wc_log_read_last_apply
  assert_eq "2222" "$(wc_ssh_port_for_target oldpeer)" "removed host should keep its previous ssh port"
  rm -rf -- "$tmpdir"
}

test_verify_reads_remote_epoch() {
  reset_wireconf_globals

  wc_run_sudo() {
    [[ "$2" == *"date +%s"* ]] || return 1
    printf '900\n'
  }

  assert_eq "900" "$(wc_remote_epoch testhost)" "remote epoch should come from the target host"
}

test_inline_hosts_basic() {
  reset_wireconf_globals
  wc_load_inline_hosts "root@hub" "root@peer1" "peer2"
  assert_eq "3" "${#WC_SSH_TARGETS[@]}" "three hosts loaded inline"
  assert_eq "root@hub" "${WC_SSH_TARGETS[0]}" "hub is first inline host"
  assert_eq "root@hub" "$WC_HUB_SSH_TARGET" "WC_HUB_SSH_TARGET tracks first inline host"
  assert_eq "22" "${WC_SSH_PORTS[1]}" "inline peer uses WC_SSH_PORT_DEFAULT when spec omits a port"
  assert_eq "no" "${WC_FULL_TUNNEL[2]}" "inline peer inherits WC_FULL_TUNNEL_DEFAULT"
}

test_inline_hosts_port_and_tunnel() {
  reset_wireconf_globals
  wc_load_inline_hosts "root@hub 2222 no" "root@peer yes"
  assert_eq "2" "${#WC_SSH_TARGETS[@]}" "two hosts loaded inline"
  assert_eq "root@hub" "${WC_SSH_TARGETS[0]}" "hub host parsed from 3-field spec"
  assert_eq "2222" "${WC_SSH_PORTS[0]}" "hub ssh_port picked from 2nd field when numeric"
  assert_eq "no" "${WC_FULL_TUNNEL[0]}" "hub full_tunnel picked from 3rd field"
  assert_eq "root@peer" "${WC_SSH_TARGETS[1]}" "peer host parsed from 2-field spec"
  assert_eq "22" "${WC_SSH_PORTS[1]}" "peer keeps default ssh_port when 2nd field is bool"
  assert_eq "yes" "${WC_FULL_TUNNEL[1]}" "peer full_tunnel picked from 2nd (bool) field"
}

test_inline_hosts_rejects_leading_dash() {
  reset_wireconf_globals
  assert_not_ok "dash-prefixed specs should be rejected as leftover flags" \
    bash -c 'WIRECONF_SOURCE_ONLY=1 source "'"$ROOT"'/wireconf"; wc_load_inline_hosts "-I" "host" 2>/dev/null'
}

test_inline_hosts_rejects_duplicates() {
  reset_wireconf_globals
  assert_not_ok "duplicate hosts should be rejected" \
    bash -c 'WIRECONF_SOURCE_ONLY=1 source "'"$ROOT"'/wireconf"; wc_load_inline_hosts "host" "host" 2>/dev/null'
}

test_inline_hosts_requires_two() {
  reset_wireconf_globals
  assert_not_ok "single inline host should be rejected (hub + peer needed)" \
    bash -c 'WIRECONF_SOURCE_ONLY=1 source "'"$ROOT"'/wireconf"; wc_load_inline_hosts "host" 2>/dev/null'
}

test_hub_endpoint_obviously_reachable() {
  assert_ok "dotted FQDN is obviously reachable" wc_hub_endpoint_is_obviously_reachable "hub.example.com"
  assert_ok "IPv4 literal is obviously reachable" wc_hub_endpoint_is_obviously_reachable "192.0.2.10"
  assert_ok "strip user@ before probing" wc_hub_endpoint_is_obviously_reachable "root@hub.example.com"
  assert_not_ok "bare single-label host should not be obviously reachable" \
    wc_hub_endpoint_is_obviously_reachable "hub"
  assert_not_ok "bare single-label host with user should not be obviously reachable" \
    wc_hub_endpoint_is_obviously_reachable "root@hub"
}

test_doctor_check_dns_short_circuits() {
  reset_wireconf_globals
  assert_ok "doctor_check_dns: localhost is always OK" doctor_check_dns "localhost"
  assert_eq "1" "$WC_DOCTOR_TOTAL_CHECKS" "localhost dns bumps total counter"
  assert_eq "0" "$WC_DOCTOR_FAILED_CHECKS" "localhost dns does not fail"

  reset_wireconf_globals
  assert_ok "doctor_check_dns: IPv4 literal is OK" doctor_check_dns "192.0.2.7"
  assert_eq "0" "$WC_DOCTOR_FAILED_CHECKS" "IPv4 literal does not fail"

  reset_wireconf_globals
  assert_ok "doctor_check_dns: user@IPv4 is OK" doctor_check_dns "root@192.0.2.7"
  assert_eq "0" "$WC_DOCTOR_FAILED_CHECKS" "user@IPv4 does not fail"
}

test_doctor_mark_fail_bumps_counters() {
  reset_wireconf_globals
  doctor_mark_ok "probe" >/dev/null 2>&1
  doctor_mark_fail "probe" "boom" "first-fix" >/dev/null 2>&1
  assert_eq "2" "$WC_DOCTOR_TOTAL_CHECKS" "two checks ran"
  assert_eq "1" "$WC_DOCTOR_FAILED_CHECKS" "one check failed"
}

test_bootstrap_user_for_target() {
  assert_eq "root" "$(wc_ssh_user_for_target 'root@hub.example.com')" "user extracted from user@host"
  assert_eq "alice" "$(wc_ssh_user_for_target 'alice@host:extra')" "user is first @-split token only"
  local got
  got="$(USER=operator wc_ssh_user_for_target 'hub.example.com')"
  assert_eq "operator" "$got" "user falls back to \$USER when target has no user@"
}

run_test test_endpoint_defaults_strip_ssh_user
run_test test_ip_allocator_rejects_broadcast_capacity
run_test test_removed_host_uses_saved_ssh_port_hint
run_test test_verify_reads_remote_epoch
run_test test_inline_hosts_basic
run_test test_inline_hosts_port_and_tunnel
run_test test_inline_hosts_rejects_leading_dash
run_test test_inline_hosts_rejects_duplicates
run_test test_inline_hosts_requires_two
run_test test_hub_endpoint_obviously_reachable
run_test test_doctor_check_dns_short_circuits
run_test test_doctor_mark_fail_bumps_counters
run_test test_bootstrap_user_for_target

printf 'Passed %d tests; failed %d tests\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
