#!/usr/bin/env bash
# shellcheck shell=bash
# wireconf bootstrap: make a target apply-ready in three idempotent steps.
#   1. ssh-copy-id (if BatchMode key auth fails — falls back to ssh password prompt)
#   2. /etc/sudoers.d/wireconf-<user> NOPASSWD drop-in (validated with visudo -cf)
#   3. apt install wireguard-tools  (Debian-family only; no-op if already present)
# Runs sequentially — each step may prompt on /dev/tty for a password.
# shellcheck source=common.sh
# shellcheck source=plan_checks.sh

declare -i WC_BOOTSTRAP_FAILED_HOSTS=0

# Extract the remote username from a target spec ("user@host" -> "user").
# Falls back to the operator's $USER if the spec has no "@".
wc_ssh_user_for_target() {
  local target="$1"
  if [[ "$target" == *@* ]]; then
    printf '%s\n' "${target%@*}"
  else
    printf '%s\n' "${USER:-root}"
  fi
}

# ssh -t (TTY allocated) so sudo can prompt for a password interactively.
# Args: target, port, remote shell snippet.
wc_ssh_exec_tty() {
  local target="$1" port="$2"
  shift 2
  if wc_is_local_execution_target "$target"; then
    bash -c "$*"
    return $?
  fi
  # shellcheck disable=SC2086
  ssh ${WC_SSH_OPTS:-} ${WC_SSH_HOSTKEY_OPTS:-} -p "$port" -t "$target" "$@"
}

# Step 1: run ssh-copy-id if key auth is not already working. Returns 0 on success.
bootstrap_step_ssh_copy_id() {
  local target="$1" port="$2"
  if wc_is_local_execution_target "$target"; then
    log_detail_ok "ssh-copy-id: localhost — no-op"
    return 0
  fi
  if wc_ssh_exec "$target" "$port" "true" >/dev/null 2>&1; then
    log_detail_ok "ssh-copy-id: key auth already works on ${target}"
    return 0
  fi
  if ! command -v ssh-copy-id >/dev/null 2>&1; then
    log_err "ssh-copy-id not found on operator PATH — install openssh-client and retry"
    return 1
  fi
  # Locate a public key the operator can push. ssh-copy-id finds one automatically,
  # but error up-front so the failure reason is clear if none exists.
  local k
  for k in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_rsa.pub" "${HOME}/.ssh/id_ecdsa.pub"; do
    [[ -f "$k" ]] && break
  done
  if [[ ! -f "$k" ]]; then
    log_err "No SSH public key found in \$HOME/.ssh (tried id_ed25519.pub, id_rsa.pub, id_ecdsa.pub)."
    log_err "Create one first: ssh-keygen -t ed25519 -C wireconf"
    return 1
  fi
  log_info "ssh-copy-id -p ${port} ${target}  (you'll be prompted for ${target}'s password)"
  # shellcheck disable=SC2086
  if ssh-copy-id ${WC_SSH_HOSTKEY_OPTS:-} -p "$port" "$target" </dev/tty; then
    log_detail_ok "ssh-copy-id: key installed on ${target}"
    return 0
  fi
  log_err "ssh-copy-id failed for ${target}"
  return 1
}

# Step 2: drop /etc/sudoers.d/wireconf-<user> if `sudo -n true` doesn't already work.
# Validated with `visudo -cf` on the tmp path before it's moved into place.
bootstrap_step_sudoers() {
  local target="$1" port="$2"
  local user
  user="$(wc_ssh_user_for_target "$target")"
  if [[ "$user" == "root" ]]; then
    log_detail_ok "sudoers: ${target} logs in as root — no drop-in needed"
    return 0
  fi
  if wc_run_sudo_quiet "$target" "true" >/dev/null 2>&1; then
    log_detail_ok "sudoers: ${target} already has passwordless sudo"
    return 0
  fi
  local file="/etc/sudoers.d/wireconf-${user}"
  local content="${user} ALL=(ALL) NOPASSWD: ALL"
  # Write via a tmpfile and visudo-validate before replacing the target.
  local remote_script
  remote_script=$(cat <<SCRIPT
set -euo pipefail
tmp="\$(mktemp)"
printf '%s\n' $(printf '%q' "$content") > "\$tmp"
sudo install -m 0440 -o root -g root "\$tmp" $(printf '%q' "$file")
rm -f "\$tmp"
sudo visudo -cf $(printf '%q' "$file") >/dev/null
SCRIPT
)
  log_info "sudoers: installing ${file} on ${target} (sudo may prompt for the user password)"
  if wc_ssh_exec_tty "$target" "$port" "$remote_script"; then
    log_detail_ok "sudoers: ${file} on ${target}"
    return 0
  fi
  log_err "sudoers drop-in failed on ${target}"
  return 1
}

# Step 3: apt install the 'wireguard' meta-package (pulls wireguard-tools + DKMS if
# the kernel needs it). Debian/Ubuntu only; no-op if wg & wg-quick are already present.
bootstrap_step_wg_tools() {
  local target="$1"
  if ! plan_target_is_debian_family "$target"; then
    log_warn "wireguard: ${target} is not Debian/Ubuntu — install wg/wg-quick manually before apply"
    return 1
  fi
  if wc_run_sudo_quiet "$target" \
    "command -v wg >/dev/null && command -v wg-quick >/dev/null" >/dev/null 2>&1; then
    log_detail_ok "wireguard: already installed on ${target}"
    return 0
  fi
  log_info "wireguard: installing on ${target} (apt-get install -y wireguard)"
  if wc_run_sudo "$target" \
    "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard"; then
    log_detail_ok "wireguard: installed on ${target}"
    return 0
  fi
  log_err "apt-get install wireguard failed on ${target}"
  return 1
}

bootstrap_one_host() {
  local target="$1" port="$2" idx="$3"
  printf '\n' >&2
  log_info "bootstrap: ${target}  (index ${idx}$([[ $idx -eq 0 ]] && echo ' — hub'))"

  bootstrap_step_ssh_copy_id "$target" "$port" || return 1
  bootstrap_step_sudoers "$target" "$port"     || return 1
  bootstrap_step_wg_tools "$target"            || return 1
  log_info "bootstrap: ${target} is apply-ready"
  return 0
}

bootstrap_all() {
  local n="${#WC_SSH_TARGETS[@]}"
  [[ "$n" -ge 1 ]] || die "bootstrap: no hosts to bootstrap"
  WC_BOOTSTRAP_FAILED_HOSTS=0

  log_info "bootstrap: preparing ${n} host(s) (sequential; may prompt for passwords)"

  local i
  for ((i = 0; i < n; i++)); do
    if ! bootstrap_one_host "${WC_SSH_TARGETS[$i]}" "${WC_SSH_PORTS[$i]}" "$i"; then
      WC_BOOTSTRAP_FAILED_HOSTS=$((WC_BOOTSTRAP_FAILED_HOSTS + 1))
      log_warn "bootstrap: ${WC_SSH_TARGETS[$i]} did not complete — re-run after fixing the error above"
    fi
  done

  printf '\n' >&2
  if [[ "$WC_BOOTSTRAP_FAILED_HOSTS" -eq 0 ]]; then
    log_info "bootstrap: all ${n} host(s) are apply-ready. Next: wireconf doctor  # then: wireconf up"
    return 0
  fi
  log_err "bootstrap: ${WC_BOOTSTRAP_FAILED_HOSTS}/${n} host(s) did not complete"
  return 1
}
