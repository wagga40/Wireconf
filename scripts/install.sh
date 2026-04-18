#!/usr/bin/env bash
# shellcheck shell=bash
# Wireconf installer. Fetches the single-file wireconf from a GitHub release,
# verifies its SHA-256 against the sidecar checksum, and installs it.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/<owner>/Wireconf/main/scripts/install.sh | bash
#
# Environment variables (all optional):
#   WIRECONF_REPO      owner/name       GitHub repo           (default: derived from script URL if piped; falls back to the value embedded below)
#   WIRECONF_VERSION   tag (e.g. v0.3.0) or "latest"          (default: latest)
#   WIRECONF_PREFIX    install prefix                          (default: /usr/local)
#   WIRECONF_NO_SUDO   "1" to disable automatic sudo escalation (default: sudo if not root and prefix is not writable)
#   WIRECONF_VERIFY    "0" to skip sha256 verification (discouraged; default: 1)
#
# Idempotent: running twice at the same version is a no-op after the checksum match.
set -euo pipefail

DEFAULT_REPO="${WIRECONF_REPO:-wagga40/Wireconf}"
VERSION="${WIRECONF_VERSION:-latest}"
PREFIX="${WIRECONF_PREFIX:-/usr/local}"
VERIFY="${WIRECONF_VERIFY:-1}"

_log() { printf '[install.sh] %s\n' "$*" >&2; }
_err() {
  printf '[install.sh] ERROR: %s\n' "$*" >&2
  exit 1
}

_need() {
  command -v "$1" >/dev/null 2>&1 || _err "required command not found on PATH: $1"
}

_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    _err "neither sha256sum nor shasum found; install coreutils or set WIRECONF_VERIFY=0 (not recommended)"
  fi
}

_need curl
_need install
_need mktemp
_need uname

if [[ "$VERIFY" == "1" ]]; then
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
    _err "checksum verification requires sha256sum or shasum; install one or set WIRECONF_VERIFY=0"
fi

# Resolve the release asset base URL. "latest" uses the convenience redirect;
# a pinned tag uses /download/<tag>/ directly.
if [[ "$VERSION" == "latest" ]]; then
  asset_base="https://github.com/${DEFAULT_REPO}/releases/latest/download"
else
  case "$VERSION" in
    v*) tag="$VERSION" ;;
    *) tag="v${VERSION}" ;;
  esac
  asset_base="https://github.com/${DEFAULT_REPO}/releases/download/${tag}"
fi

bin_url="${asset_base}/wireconf"
sha_url="${asset_base}/wireconf.sha256"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/wireconf-install.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

_log "downloading ${bin_url}"
curl -fsSL --retry 3 -o "${tmpdir}/wireconf" "$bin_url" ||
  _err "download failed: ${bin_url} (check WIRECONF_REPO / WIRECONF_VERSION)"

if [[ "$VERIFY" == "1" ]]; then
  _log "downloading ${sha_url}"
  curl -fsSL --retry 3 -o "${tmpdir}/wireconf.sha256" "$sha_url" ||
    _err "checksum download failed: ${sha_url}"
  want="$(awk 'NF {print $1; exit}' "${tmpdir}/wireconf.sha256")"
  [[ -n "$want" ]] || _err "empty checksum file: ${sha_url}"
  got="$(_sha256 "${tmpdir}/wireconf")"
  if [[ "$want" != "$got" ]]; then
    _err "sha256 mismatch: expected ${want}, got ${got}"
  fi
  _log "sha256 OK (${got:0:16}...)"
fi

chmod 0755 "${tmpdir}/wireconf"

if ! "${tmpdir}/wireconf" -V >/dev/null 2>&1; then
  _err "downloaded wireconf did not respond to -V; refusing to install"
fi
installed_version="$("${tmpdir}/wireconf" -V 2>/dev/null | awk '{print $NF}')"

bindir="${PREFIX}/bin"
dest="${bindir}/wireconf"

run_install() {
  install -d "$bindir"
  install -m 0755 "${tmpdir}/wireconf" "$dest"
}

needs_sudo() {
  [[ "${WIRECONF_NO_SUDO:-0}" != "1" ]] &&
    [[ "$(id -u)" != "0" ]] &&
    [[ ! -w "$bindir" || ( ! -d "$bindir" && ! -w "$PREFIX" ) ]]
}

if needs_sudo; then
  if ! command -v sudo >/dev/null 2>&1; then
    _err "${bindir} is not writable by $(whoami) and sudo is missing; rerun as root or set WIRECONF_PREFIX=\$HOME/.local"
  fi
  _log "installing to ${dest} (via sudo)"
  sudo install -d "$bindir"
  sudo install -m 0755 "${tmpdir}/wireconf" "$dest"
else
  _log "installing to ${dest}"
  run_install
fi

_log "installed wireconf ${installed_version} -> ${dest}"
if ! printf '%s' ":${PATH}:" | grep -q ":${bindir}:"; then
  _log "note: ${bindir} is not on your PATH; add it or invoke ${dest} directly"
fi
