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

test_verify_pings_before_handshake_checks() {
  reset_wireconf_globals
  WC_SSH_TARGETS=("hub.example.com" "peer1.example.com" "peer2.example.com")
  WC_INDEX_TO_IP=([0]="10.200.0.1" [1]="10.200.0.2" [2]="10.200.0.3")

  local order=""
  verify_ping_peer() {
    order+="ping:${2};"
  }
  verify_handshakes() {
    order+="handshake:${1};"
  }
  verify_print_topology_schema() {
    :
  }
  wc_resolve_hub_endpoint_from_inventory() {
    return 1
  }
  log_info() {
    :
  }

  verify_all >/dev/null 2>&1
  assert_eq \
    "ping:10.200.0.2;ping:10.200.0.3;handshake:hub.example.com;handshake:peer1.example.com;handshake:peer2.example.com;" \
    "$order" \
    "verify should ping from hub before strict handshake checks"
}

test_verify_ping_peer_uses_quiet_sudo() {
  reset_wireconf_globals
  assert_ok "verify ping should use quiet sudo wrapper" \
    bash -c 'WIRECONF_SOURCE_ONLY=1 source "'"$ROOT"'/wireconf"; \
      quiet_calls=0; noisy_calls=0; \
      wc_run_sudo_quiet() { quiet_calls=$((quiet_calls + 1)); return 0; }; \
      wc_run_sudo() { noisy_calls=$((noisy_calls + 1)); return 0; }; \
      log_info() { :; }; \
      verify_ping_peer "hub.example.com" "10.200.0.2" >/dev/null 2>&1; \
      [[ "$quiet_calls" -eq 1 ]] && [[ "$noisy_calls" -eq 0 ]]'
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

test_hub_resolving_to_local_runs_as_local() {
  reset_wireconf_globals
  assert_ok "hub should be local when its DNS resolves to this machine" \
    bash -c 'WIRECONF_SOURCE_ONLY=1 source "'"$ROOT"'/wireconf"; \
      WC_SSH_TARGETS=("root@hub.example.com" "peer.example.com"); \
      WC_HUB_SSH_TARGET="${WC_SSH_TARGETS[0]}"; \
      wc_host_resolved_ips() { printf "%s\n" "203.0.113.10"; }; \
      wc_local_ips() { printf "%s\n" "127.0.0.1" "203.0.113.10"; }; \
      wc_is_local_execution_target "root@hub.example.com"'
}

test_peer_resolving_to_local_stays_remote() {
  reset_wireconf_globals
  assert_not_ok "only hub gets resolve-to-local special case" \
    bash -c 'WIRECONF_SOURCE_ONLY=1 source "'"$ROOT"'/wireconf"; \
      WC_SSH_TARGETS=("root@hub.example.com" "peer.example.com"); \
      WC_HUB_SSH_TARGET="${WC_SSH_TARGETS[0]}"; \
      wc_host_resolved_ips() { printf "%s\n" "203.0.113.10"; }; \
      wc_local_ips() { printf "%s\n" "127.0.0.1" "203.0.113.10"; }; \
      wc_is_local_execution_target "peer.example.com"'
}


test_init_does_not_create_gitignore() {
  local tmpdir rc=0
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wireconf-init-test.XXXXXX")"

  assert_ok "wireconf init should succeed" \
    bash -c "cd \"$tmpdir\" && bash \"$ROOT/wireconf\" init" || rc=1

  assert_ok "init should create inventory" test -f "${tmpdir}/inventory" || rc=1
  assert_ok "init should create wireconf.env" test -f "${tmpdir}/wireconf.env" || rc=1
  assert_not_ok "init should not create .gitignore" test -e "${tmpdir}/.gitignore" || rc=1

  rm -rf -- "$tmpdir"
  return "$rc"
}


test_install_script_installs_binary_at_prefix_root() {
  local tmpdir prefix fake_bin_path fake_tool_dir rc=0
  if [[ ! -f "$ROOT/scripts/install.sh" ]]; then
    return 0
  fi
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wireconf-install-test.XXXXXX")"
  prefix="${tmpdir}/opt/wireconf"
  fake_bin_path="${tmpdir}/fake-wireconf"
  fake_tool_dir="${tmpdir}/tools"
  mkdir -p "$fake_tool_dir"

  cat >"$fake_bin_path" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-V" ]]; then
  printf '%s\n' 'wireconf vtest'
  exit 0
fi
exit 0
EOF
  chmod 0755 "$fake_bin_path"

  cat >"${fake_tool_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=""
while (($#)); do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cp "$WIRECONF_FAKE_BINARY" "$out"
EOF
  chmod 0755 "${fake_tool_dir}/curl"

  assert_ok "install.sh should place binary at <prefix>/wireconf" \
    env PATH="${fake_tool_dir}:$PATH" \
      WIRECONF_PREFIX="$prefix" \
      WIRECONF_VERIFY=0 \
      WIRECONF_FAKE_BINARY="$fake_bin_path" \
      bash "$ROOT/scripts/install.sh" || rc=1

  assert_ok "binary should exist at prefix root" test -x "${prefix}/wireconf" || rc=1
  assert_not_ok "binary should not be installed under bin/" test -e "${prefix}/bin/wireconf" || rc=1

  rm -rf -- "$tmpdir"
  return "$rc"
}

run_test test_endpoint_defaults_strip_ssh_user
run_test test_ip_allocator_rejects_broadcast_capacity
run_test test_removed_host_uses_saved_ssh_port_hint
run_test test_verify_reads_remote_epoch
run_test test_verify_pings_before_handshake_checks
run_test test_verify_ping_peer_uses_quiet_sudo
run_test test_inline_hosts_basic
run_test test_inline_hosts_port_and_tunnel
run_test test_inline_hosts_rejects_leading_dash
run_test test_inline_hosts_rejects_duplicates
run_test test_inline_hosts_requires_two
run_test test_hub_endpoint_obviously_reachable
run_test test_doctor_check_dns_short_circuits
run_test test_doctor_mark_fail_bumps_counters
run_test test_bootstrap_user_for_target
run_test test_hub_resolving_to_local_runs_as_local
run_test test_peer_resolving_to_local_stays_remote
run_test test_init_does_not_create_gitignore
run_test test_install_script_installs_binary_at_prefix_root

printf 'Passed %d tests; failed %d tests\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
