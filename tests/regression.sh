#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/apply_prompts.sh
source "$ROOT/lib/apply_prompts.sh"
# shellcheck source=lib/verify.sh
source "$ROOT/lib/verify.sh"

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

load_wireconf_functions() {
  # shellcheck disable=SC2034
  WIRECONF_SOURCE_ONLY=1
  # shellcheck source=/dev/null
  source "$ROOT/wireconf"
  unset WIRECONF_SOURCE_ONLY
}

reset_wireconf_globals() {
  WC_INVENTORY=""
  WC_LOG_FILE=""
  WC_IFACE="wg0"
  WC_NETWORK="10.200.0.0/24"
  WC_PORT="51820"
  WC_HUB_ENDPOINT=""
  WC_HUB_SSH_TARGET=""
  WC_AUTO_START="no"
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

run_test test_endpoint_defaults_strip_ssh_user
run_test test_ip_allocator_rejects_broadcast_capacity
run_test test_removed_host_uses_saved_ssh_port_hint
run_test test_verify_reads_remote_epoch

printf 'Passed %d tests; failed %d tests\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
