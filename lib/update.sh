#!/usr/bin/env bash
# shellcheck shell=bash
# wireconf update: fetch and install the single-file release from GitHub,
# verify the sha256 sidecar, and atomically replace the running binary.
# Only supported for single-file installs (WIRECONF_SINGLE_FILE=1). Source-tree
# checkouts are rejected with guidance so we never touch lib/ / examples/ out of
# sync with the main file.
# shellcheck source=common.sh

WIRECONF_UPDATE_REPO_DEFAULT="wagga40/Wireconf"

# Return the absolute path of the currently running wireconf. Follows symlinks
# so the install ends up replacing the real file (typical layout puts the
# binary in ${PREFIX}/wireconf with no symlink, but a manual symlink setup
# should still update the target).
wc_update_resolve_self() {
  local p="${BASH_SOURCE[0]:-$0}"
  if [[ "$p" != /* ]]; then
    p="$(pwd)/${p#./}"
  fi
  if command -v readlink >/dev/null 2>&1 && readlink -f "$p" >/dev/null 2>&1; then
    readlink -f -- "$p"
  elif command -v realpath >/dev/null 2>&1; then
    realpath -- "$p"
  else
    printf '%s\n' "$p"
  fi
}

# Download $1 to $2. Prefers curl, falls back to wget. Any failure is the
# caller's to report — this helper only returns non-zero on error.
wc_update_fetch() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url"
  else
    log_err "update: neither curl nor wget found on PATH"
    return 1
  fi
}

# Print the sha256 of $1 using whichever tool is available.
wc_update_sha256() {
  local f="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  else
    return 1
  fi
}

# Compute the release asset base URL for the requested version. "latest" uses
# the GitHub convenience redirect; a pinned version (with or without a leading
# "v") resolves to /releases/download/<tag>/. Mirrors scripts/install.sh so the
# one-liner installer and `wireconf update` stay in lockstep.
wc_update_resolve_asset_base() {
  local repo="$1" version="$2" tag
  if [[ "$version" == "latest" ]]; then
    printf 'https://github.com/%s/releases/latest/download\n' "$repo"
    return 0
  fi
  case "$version" in
    v*) tag="$version" ;;
    *) tag="v${version}" ;;
  esac
  printf 'https://github.com/%s/releases/download/%s\n' "$repo" "$tag"
}

wireconf_cmd_update() {
  if [[ "${WIRECONF_SINGLE_FILE:-0}" != "1" ]]; then
    log_err "update: only supported for single-file installs (produced by scripts/build-single-file.sh)."
    log_info "This wireconf is running from a source checkout — update with one of:"
    log_detail "git pull                 # git checkout"
    log_detail "task install             # reinstall from source tree"
    log_detail "task dist-install        # build + install single-file artifact"
    exit 2
  fi

  local repo version verify target tmpdir
  repo="${WIRECONF_REPO:-$WIRECONF_UPDATE_REPO_DEFAULT}"
  version="${_WIRECONF_UPDATE_TARGET:-latest}"
  verify="${WIRECONF_VERIFY:-1}"

  local asset_base bin_url sha_url
  asset_base="$(wc_update_resolve_asset_base "$repo" "$version")"
  bin_url="${asset_base}/wireconf"
  sha_url="${asset_base}/wireconf.sha256"

  target="$(wc_update_resolve_self)"
  [[ -n "$target" && -f "$target" ]] || die "update: could not resolve running binary path"

  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wireconf-update.XXXXXX")" || die "update: mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -rf -- '$tmpdir'" EXIT

  if [[ "$verify" == "1" ]]; then
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
      die "update: checksum verification needs sha256sum or shasum; install one or set WIRECONF_VERIFY=0 (discouraged)"
    fi
  fi

  log_info "update: repo=${repo} target-version=${version}"
  log_info "update: downloading ${bin_url}"
  wc_update_fetch "$bin_url" "${tmpdir}/wireconf" \
    || die "update: download failed (${bin_url}); check WIRECONF_REPO / WIRECONF_VERSION"

  if [[ "$verify" == "1" ]]; then
    log_info "update: downloading ${sha_url}"
    wc_update_fetch "$sha_url" "${tmpdir}/wireconf.sha256" \
      || die "update: sha256 download failed (${sha_url})"
    local want got
    want="$(awk 'NF {print $1; exit}' "${tmpdir}/wireconf.sha256")"
    [[ -n "$want" ]] || die "update: empty checksum file (${sha_url})"
    got="$(wc_update_sha256 "${tmpdir}/wireconf")" || die "update: sha256 tool missing"
    [[ "$want" == "$got" ]] || die "update: sha256 mismatch (want ${want}, got ${got})"
    log_detail_ok "sha256 ${got:0:16}..."
  else
    log_warn "update: sha256 verification disabled (WIRECONF_VERIFY=0) — downloaded binary NOT verified"
  fi

  chmod 0755 "${tmpdir}/wireconf"

  local new_version old_version
  if ! new_version="$("${tmpdir}/wireconf" -V 2>/dev/null)"; then
    die "update: downloaded wireconf did not respond to -V; refusing to install"
  fi
  new_version="${new_version##* }"
  old_version="${WIRECONF_VERSION}"

  if [[ "$new_version" == "$old_version" ]]; then
    log_info "update: already at ${old_version} (${target}); nothing to do."
    rm -rf -- "$tmpdir"
    trap - EXIT
    return 0
  fi

  # Atomic replacement relies on install(1)'s write-temp-then-rename, which is
  # safe to run against the currently-executing file on Unix: the kernel keeps
  # the old inode alive for the running process while the directory entry is
  # rebound to the new file.
  local parent use_sudo=0
  parent="$(dirname -- "$target")"
  if [[ ! -w "$parent" ]] || { [[ -e "$target" ]] && [[ ! -w "$target" ]]; }; then
    use_sudo=1
  fi
  if [[ "$use_sudo" -eq 1 ]] && { [[ "$(id -u)" == "0" ]] || [[ "${WIRECONF_NO_SUDO:-0}" == "1" ]]; }; then
    use_sudo=0
  fi

  if [[ "$use_sudo" -eq 1 ]]; then
    command -v sudo >/dev/null 2>&1 \
      || die "update: ${target} not writable and sudo is unavailable (rerun as root or set WIRECONF_NO_SUDO=1 after making ${parent} writable)"
    log_info "update: installing ${new_version} -> ${target} (via sudo)"
    sudo install -m 0755 "${tmpdir}/wireconf" "$target" \
      || die "update: install failed (${target})"
  else
    log_info "update: installing ${new_version} -> ${target}"
    install -m 0755 "${tmpdir}/wireconf" "$target" \
      || die "update: install failed (${target}); rerun with sudo or unset WIRECONF_NO_SUDO"
  fi

  rm -rf -- "$tmpdir"
  trap - EXIT
  log_info "update: upgraded ${old_version} -> ${new_version}"
  return 0
}
