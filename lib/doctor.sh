#!/usr/bin/env bash
# shellcheck shell=bash
# Non-fatal per-host preflight: DNS, TCP, SSH key auth, sudo, OS, tools, kernel
# module. Emits structured "OK" / "FAIL — how to fix" lines and a rollup.
# Runs under WC_PARALLEL. Exits 0 iff every host passes every check.
# shellcheck source=common.sh
# shellcheck source=plan_checks.sh

# Counters bumped by doctor_check_one via doctor_mark_{ok,fail}.
declare -i WC_DOCTOR_TOTAL_CHECKS=0
declare -i WC_DOCTOR_FAILED_CHECKS=0
declare -i WC_DOCTOR_FAILED_HOSTS=0

doctor_mark_ok() {
  WC_DOCTOR_TOTAL_CHECKS=$((WC_DOCTOR_TOTAL_CHECKS + 1))
  printf '  %s%s%s: %sOK%s\n' "${WC_C_DIM:-}" "$1" "${WC_C_RESET:-}" "${WC_C_GREEN:-}" "${WC_C_RESET:-}" >&2
}

doctor_mark_fail() {
  local label="$1" reason="$2"
  shift 2
  WC_DOCTOR_TOTAL_CHECKS=$((WC_DOCTOR_TOTAL_CHECKS + 1))
  WC_DOCTOR_FAILED_CHECKS=$((WC_DOCTOR_FAILED_CHECKS + 1))
  printf '  %s%s%s: %sFAIL%s — %s\n' "${WC_C_DIM:-}" "$label" "${WC_C_RESET:-}" "${WC_C_RED:-}" "${WC_C_RESET:-}" "$reason" >&2
  local fix
  for fix in "$@"; do
    printf '    %s$ %s%s\n' "${WC_C_DIM:-}" "$fix" "${WC_C_RESET:-}" >&2
  done
}

# Return 0 if DNS resolves; skip (no-op OK) for literal IPs and localhost.
doctor_check_dns() {
  local target="$1" host
  host="${target##*@}"
  host="${host%%:*}"
  if is_local_host "$target"; then
    doctor_mark_ok "dns"
    return 0
  fi
  if [[ "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [[ "$host" == *:* ]]; then
    doctor_mark_ok "dns (IP literal)"
    return 0
  fi
  if command -v getent >/dev/null 2>&1; then
    if getent ahosts "$host" >/dev/null 2>&1; then
      doctor_mark_ok "dns"
      return 0
    fi
  elif command -v host >/dev/null 2>&1; then
    if host -W 3 "$host" >/dev/null 2>&1; then
      doctor_mark_ok "dns"
      return 0
    fi
  elif command -v nslookup >/dev/null 2>&1; then
    if nslookup "$host" >/dev/null 2>&1; then
      doctor_mark_ok "dns"
      return 0
    fi
  else
    # No resolver tool; can't decide. Call it OK so we don't falsely fail.
    doctor_mark_ok "dns (no resolver tool; skipped)"
    return 0
  fi
  doctor_mark_fail "dns" "${host} does not resolve" \
    "getent ahosts ${host}  # confirm the resolver" \
    "echo '<ip> ${host}' | sudo tee -a /etc/hosts  # operator-side shortcut"
  return 1
}

# Best-effort TCP probe. Uses bash /dev/tcp if available (always is in bash).
doctor_check_tcp() {
  local target="$1" port="$2" host
  host="${target##*@}"
  host="${host%%:*}"
  if is_local_host "$target"; then
    doctor_mark_ok "tcp (local, no probe)"
    return 0
  fi
  if (timeout 5 bash -c "</dev/tcp/${host}/${port}" 2>/dev/null); then
    doctor_mark_ok "tcp ${port}"
    return 0
  fi
  doctor_mark_fail "tcp ${port}" "cannot open TCP to ${host}:${port}" \
    "ss -ltnp | grep :${port}  # on the target host" \
    "sudo ufw allow ${port}/tcp  # if ufw is blocking (Debian/Ubuntu)"
  return 1
}

# Host key status: known / new / changed. "new" is OK with --ssh-accept-new;
# "changed" is always FAIL. Local hosts skip this check.
doctor_check_ssh_hostkey() {
  local target="$1" port="$2" host out rc
  host="${target##*@}"
  host="${host%%:*}"
  if is_local_host "$target"; then
    doctor_mark_ok "ssh hostkey (local, skipped)"
    return 0
  fi
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    doctor_mark_ok "ssh hostkey (ssh-keygen missing; skipped)"
    return 0
  fi
  out="$(ssh-keygen -F "[${host}]:${port}" 2>/dev/null || ssh-keygen -F "$host" 2>/dev/null || true)"
  if [[ -n "$out" ]]; then
    doctor_mark_ok "ssh hostkey (known_hosts hit)"
    return 0
  fi
  rc=0
  ssh-keyscan -T 5 -p "$port" "$host" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    if [[ "${WC_SSH_ACCEPT_NEW:-no}" == "yes" ]]; then
      doctor_mark_ok "ssh hostkey (new; will be accepted by --ssh-accept-new)"
      return 0
    fi
    doctor_mark_fail "ssh hostkey" "host key not in known_hosts (would prompt)" \
      "ssh-keyscan -p ${port} ${host} >> ~/.ssh/known_hosts" \
      "or re-run wireconf with --ssh-accept-new / SSH_ACCEPT_NEW=yes"
    return 1
  fi
  doctor_mark_fail "ssh hostkey" "ssh-keyscan timed out or refused" \
    "ssh -p ${port} -v ${target}  # watch for connection errors"
  return 1
}

# BatchMode key auth. Runs `true` with a short timeout.
doctor_check_ssh_auth() {
  local target="$1" port="$2"
  if is_local_host "$target"; then
    doctor_mark_ok "ssh auth (local, skipped)"
    return 0
  fi
  if wc_ssh_exec "$target" "$port" "true" >/dev/null 2>&1; then
    doctor_mark_ok "ssh auth (BatchMode)"
    return 0
  fi
  doctor_mark_fail "ssh auth" "BatchMode SSH failed — no key-based auth or wrong key" \
    "ssh-copy-id -p ${port} ${target}" \
    "or run: wireconf bootstrap ${target}  # (ssh-copy-id + sudo drop-in + wg-tools)"
  return 1
}

doctor_check_sudo() {
  local target="$1"
  if wc_run_sudo_quiet "$target" "true" >/dev/null 2>&1; then
    doctor_mark_ok "sudo -n (passwordless)"
    return 0
  fi
  local user hint remote_user
  remote_user="${target%@*}"
  [[ "$remote_user" == "$target" || -z "$remote_user" ]] && remote_user='$USER'
  user="${remote_user}"
  hint="echo '${user} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/wireconf-${user}"
  doctor_mark_fail "sudo -n" "passwordless sudo failed (or command blocked)" \
    "ssh ${target}; then: ${hint}" \
    "or run: wireconf bootstrap ${target}"
  return 1
}

doctor_check_os() {
  local target="$1"
  if plan_target_is_debian_family "$target"; then
    doctor_mark_ok "os (debian/ubuntu family)"
    return 0
  fi
  doctor_mark_fail "os" "/etc/os-release is not Debian/Ubuntu" \
    "wireconf targets Debian-family only; use a Debian/Ubuntu host"
  return 1
}

# Args: target, index, hub_needs_nat (1 if any peer is full-tunnel).
doctor_check_tools() {
  local target="$1" idx="$2" hub_nat="$3"
  local req="wg wg-quick ip systemctl ping bash"
  [[ "$idx" -eq 0 && "$hub_nat" -eq 1 ]] && req="$req iptables sysctl"
  if wc_run_sudo_quiet "$target" \
    "for x in $req; do command -v \"\$x\" >/dev/null || { echo missing:\$x >&2; exit 1; }; done" \
    >/dev/null 2>&1; then
    doctor_mark_ok "tools (${req})"
    return 0
  fi
  doctor_mark_fail "tools" "one or more of '${req}' missing" \
    "sudo apt-get update && sudo apt-get install -y wireguard iproute2 systemd iputils-ping iptables" \
    "or run: wireconf bootstrap ${target}"
  return 1
}

doctor_check_wg_module() {
  local target="$1"
  if wc_run_sudo_quiet "$target" "modprobe -n wireguard 2>/dev/null || modinfo wireguard >/dev/null 2>&1" \
    >/dev/null 2>&1; then
    doctor_mark_ok "kernel wireguard module loadable"
    return 0
  fi
  doctor_mark_fail "kernel wireguard module" "modprobe -n wireguard failed (kernel 5.6+ ships it built-in)" \
    "sudo apt-get install -y linux-headers-\$(uname -r) wireguard-dkms" \
    "uname -r  # check kernel version; upgrade to 5.6+ if practical"
  return 1
}

# Runs every check for one host. Returns 0 on all-OK, 1 on any failure.
doctor_check_one() {
  local target="$1" port="$2" idx="$3" hub_nat="$4"
  local fail_before="$WC_DOCTOR_FAILED_CHECKS"
  printf '\n%s[wireconf]%s %s%s%s  (index %d%s)\n' \
    "${WC_C_CYAN:-}${WC_C_BOLD:-}" "${WC_C_RESET:-}" "${WC_C_BOLD:-}" "$target" "${WC_C_RESET:-}" \
    "$idx" "$([[ $idx -eq 0 ]] && echo ' — hub')" >&2
  doctor_check_dns "$target"          || true
  doctor_check_tcp "$target" "$port"  || true
  doctor_check_ssh_hostkey "$target" "$port" || true
  doctor_check_ssh_auth "$target" "$port"    || true
  # Remaining checks require working SSH auth; skip with a hint if auth failed.
  if is_local_host "$target" || wc_ssh_exec "$target" "$port" "true" >/dev/null 2>&1; then
    doctor_check_sudo "$target"                || true
    doctor_check_os "$target"                  || true
    doctor_check_tools "$target" "$idx" "$hub_nat" || true
    doctor_check_wg_module "$target"           || true
  else
    printf '  %s(sudo / os / tools / wg_module skipped: SSH auth is a prerequisite)%s\n' \
      "${WC_C_DIM:-}" "${WC_C_RESET:-}" >&2
  fi
  [[ "$WC_DOCTOR_FAILED_CHECKS" -eq "$fail_before" ]]
}

doctor_all() {
  local n="${#WC_SSH_TARGETS[@]}"
  [[ "$n" -ge 1 ]] || die "doctor: no hosts to check"

  local max_j="${WC_PARALLEL:-1}"
  [[ "$max_j" =~ ^[0-9]+$ ]] && [[ "$max_j" -ge 1 ]] || max_j=1

  local hub_nat=0
  any_full_tunnel_peer && hub_nat=1

  WC_DOCTOR_TOTAL_CHECKS=0
  WC_DOCTOR_FAILED_CHECKS=0
  WC_DOCTOR_FAILED_HOSTS=0

  log_info "doctor: running preflight checks on ${n} host(s) (parallel=${max_j})"

  if [[ "$max_j" -le 1 ]]; then
    local i
    for ((i = 0; i < n; i++)); do
      doctor_check_one "${WC_SSH_TARGETS[$i]}" "${WC_SSH_PORTS[$i]}" "$i" "$hub_nat" ||
        WC_DOCTOR_FAILED_HOSTS=$((WC_DOCTOR_FAILED_HOSTS + 1))
    done
  else
    # Parallel: capture per-host output, then replay in order so the report reads top-to-bottom.
    local tmpdir i jobs=0
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wireconf-doctor.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN
    for ((i = 0; i < n; i++)); do
      (
        exec 2>"$tmpdir/${i}.err"
        local sub_fail=0
        doctor_check_one "${WC_SSH_TARGETS[$i]}" "${WC_SSH_PORTS[$i]}" "$i" "$hub_nat" || sub_fail=1
        printf '%d\t%d\t%d\n' "$sub_fail" "$WC_DOCTOR_TOTAL_CHECKS" "$WC_DOCTOR_FAILED_CHECKS" >"$tmpdir/${i}.rc"
      ) &
      jobs=$((jobs + 1))
      if [[ "$jobs" -ge "$max_j" ]]; then
        wait -n >/dev/null 2>&1 || true
        jobs=$((jobs - 1))
      fi
    done
    wait
    for ((i = 0; i < n; i++)); do
      [[ -s "$tmpdir/${i}.err" ]] && cat "$tmpdir/${i}.err" >&2
      local sub_fail total_checks fail_checks
      IFS=$'\t' read -r sub_fail total_checks fail_checks <"$tmpdir/${i}.rc"
      WC_DOCTOR_TOTAL_CHECKS=$((WC_DOCTOR_TOTAL_CHECKS + total_checks))
      WC_DOCTOR_FAILED_CHECKS=$((WC_DOCTOR_FAILED_CHECKS + fail_checks))
      [[ "$sub_fail" -ne 0 ]] && WC_DOCTOR_FAILED_HOSTS=$((WC_DOCTOR_FAILED_HOSTS + 1))
    done
  fi

  printf '\n' >&2
  if [[ "$WC_DOCTOR_FAILED_HOSTS" -eq 0 ]]; then
    log_info "doctor: all ${n} host(s) passed (${WC_DOCTOR_TOTAL_CHECKS} checks)"
    return 0
  fi
  log_err "doctor: ${WC_DOCTOR_FAILED_HOSTS}/${n} host(s) failed (${WC_DOCTOR_FAILED_CHECKS}/${WC_DOCTOR_TOTAL_CHECKS} checks)"
  log_detail "re-run with --parallel N to speed this up, or: wireconf bootstrap <hosts>  # fix ssh / sudo / wg-tools automatically"
  return 1
}
