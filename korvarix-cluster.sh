#!/usr/bin/env bash
# korvarix-cluster - command station for the korvarix LLM cluster.
# Thin client: menu + wizard orchestration + module downloader (sha256-verified).
# Heavy lifting lives in modules fetched from KCV_REPO_URL per manifest.txt.
#
#   ./korvarix-cluster.sh              interactive menu
#   ./korvarix-cluster.sh health       cron entrypoint (runs from cache)
#   ./korvarix-cluster.sh backup       cron entrypoint
#   ./korvarix-cluster.sh update       refresh modules from repo
#   ./korvarix-cluster.sh <module> [args]   direct module entrypoint

set -uo pipefail

KCV_VERSION="0.2.1"
KCV_REPO_URL="${KCV_REPO_URL:-https://raw.githubusercontent.com/Korvarix/install/main/modules}"
# shellcheck disable=SC2034  # reserved for pinned-release mode
KCV_REF="${KCV_REF:-main}"
KCV_ETC_DIR="/etc/korvarix-cluster"
KCV_LIB_DIR="/var/lib/korvarix-cluster"
KCV_MODULES_DIR="${KCV_LIB_DIR}/modules"
KCV_ENV_FILE="${KCV_ETC_DIR}/korvarix.env"
# shellcheck disable=SC2034  # used by sourced lib.sh
KCV_STATE_FILE="${KCV_LIB_DIR}/state"
KCV_LOG_DIR="/var/log/korvarix"
SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m %s\n' "$*" >&2; exit 1; }
kcv_tty() { [[ -t 0 ]]; }

# ---- bootstrap deps (before any module can load) -----------------------------

ensure_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    log "installing curl (bootstrap dependency)"
    if command -v apt-get >/dev/null 2>&1; then apt-get update -qq && apt-get -y -qq install curl
    elif command -v dnf >/dev/null 2>&1; then dnf -y -q install curl
    elif command -v yum >/dev/null 2>&1; then yum -y -q install curl
    elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install curl
    elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm curl
    elif command -v apk >/dev/null 2>&1; then apk add --no-cache curl
    else die "no package manager and curl missing - install curl manually"
    fi
  fi
  command -v curl >/dev/null 2>&1 || die "curl still missing - install it manually"
}

# ---- module system -----------------------------------------------------------

module_list() {
  # cache-buster: raw.githubusercontent edges cache ~5min per URL, so right
  # after a push a box can get a stale-but-self-consistent snapshot (old
  # manifest + old module) and "up to date" becomes a lie. ts= defeats it.
  curl -fsSL --max-time 30 "${KCV_REPO_URL}/manifest.txt?ts=$(date +%s)" 2>/dev/null || return 1
}

manifest_sha() {
  module_list | awk -v n="$1" '$1==n{print $3}'
}

# fetch one module and verify sha256 against $want. Retries with backoff,
# re-fetching the manifest each round: right after a push, raw.githubusercontent
# edges can briefly serve the NEW manifest with an OLD module file (or vice
# versa) - a transient skew a bare verify would misreport as tampering.
module_fetch_verify() {
  local name="$1" want="$2" out="$3" attempt got
  for attempt in 1 2 3 4; do
    if (( attempt > 1 )); then
      sleep $(( (attempt - 1) * 20 ))
      want="$(manifest_sha "$name")"
    fi
    [[ -n "$want" ]] || continue
    curl -fsSL --retry 2 --max-time 120 -o "$out" "${KCV_REPO_URL}/${name}.sh?ts=$(date +%s)" \
      || { rm -f "$out"; continue; }
    got="$(sha256sum "$out" | awk '{print $1}')"
    if [[ "$got" == "$want" ]]; then printf '%s\n' "$got"; return 0; fi
  done
  return 1
}

module_sync() {
  ensure_curl
  log "module repo: $KCV_REPO_URL"
  local manifest
  manifest="$(module_list)" || die "cannot reach module repo ($KCV_REPO_URL) - check network or set KCV_REPO_URL"
  mkdir -p "$KCV_MODULES_DIR"
  local updated=0 failed=0 name ver sha want cur got
  while read -r name ver sha _rest; do
    [[ -n "$name" ]] || continue
    [[ "$name" == "korvarix-station" ]] && continue
    want="${KCV_MODULES_DIR}/${name}.sh"
    cur="none"
    [[ -f "$want" ]] && cur="$(sha256sum "$want" | awk '{print $1}')"
    [[ "$cur" == "$sha" ]] && continue
    got="$(module_fetch_verify "$name" "$sha" "${want}.new")"
    if [[ -z "$got" ]]; then
      warn "checksum mismatch for $name (manifest: $sha) - CDN skew or broken push; cached version kept"
      rm -f "${want}.new"
      failed=$((failed+1))
      continue
    fi
    mv "${want}.new" "$want"
    updated=$((updated+1))
    ok "module updated: $name ($ver)"
  done <<EOF2
$manifest
EOF2
  if [[ "$failed" -gt 0 ]]; then
    die "$failed module(s) failed verification after retries - repo briefly inconsistent (CDN skew) or a bad push; wait a few minutes and re-run update. Cached modules are untouched."
  fi
  # commit the cached manifest only after EVERY module verified - a failed
  # sync must never leave the cache referencing files it does not have
  printf '%s\n' "$manifest" > "${KCV_MODULES_DIR}/manifest.txt"
  [[ "$updated" -eq 0 ]] && ok "all modules up to date"
  # station self-update: the station itself rides the same manifest
  # (korvarix-station <ver> <sha>). Replace in place + exec if changed,
  # else a new-module release can depend on station code the box never got.
  local st_sha st_cur base_url
  st_sha="$(printf '%s\n' "$manifest" | awk '$1=="korvarix-station"{print $3}')"
  if [[ -n "$st_sha" ]]; then
    base_url="${KCV_REPO_URL%/modules}"
    st_cur="$(sha256sum "$SELF_PATH" 2>/dev/null | awk '{print $1}')"
    if [[ "$st_cur" != "$st_sha" ]]; then
      curl -fsSL --retry 2 --max-time 120 -o "${SELF_PATH}.new" "${base_url}/korvarix-cluster.sh?ts=$(date +%s)" \
        && [[ "$(sha256sum "${SELF_PATH}.new" | awk '{print $1}')" == "$st_sha" ]] \
        && mv "${SELF_PATH}.new" "$SELF_PATH" && chmod +x "$SELF_PATH" \
        && ok "station updated - re-run your command" && exec bash "$SELF_PATH" "$@"
    fi
  fi
  return 0
}

kcv_run_module() {
  local name="$1"; shift || true
  ensure_curl
  if [[ ! -f "${KCV_MODULES_DIR}/${name}.sh" ]]; then
    log "module '$name' not cached - fetching"
    module_sync
  fi
  local file="${KCV_MODULES_DIR}/${name}.sh"
  [[ -f "$file" ]] || die "module '$name' not in repo manifest"
  local cur want
  cur="$(sha256sum "$file" | awk '{print $1}')"
  want="$(manifest_sha "$name")"
  if [[ -n "$want" && "$cur" != "$want" ]]; then
    log "module '$name' changed upstream - updating"
    module_sync
  fi
  # shellcheck disable=SC1090  # module path is dynamic by design
  source "$file"
  if [[ -f "$KCV_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$KCV_ENV_FILE"
    set +a
  fi
  declare -F "kcv_module_${name}" >/dev/null || die "module $name has no entrypoint"
  "kcv_module_${name}" "$@"
}

# ---- shared lib bootstrap ----------------------------------------------------

load_lib() {
  [[ -f "${KCV_MODULES_DIR}/lib.sh" ]] || module_sync
  # shellcheck disable=SC1091
  source "${KCV_MODULES_DIR}/lib.sh"
  kcv_init
  mkdir -p "$KCV_ETC_DIR" "$KCV_LIB_DIR" "$KCV_LOG_DIR"
  state_set station_path "$SELF_PATH"
}

require_root() { [[ $EUID -eq 0 ]] || die "run as root (sudo -i)"; }

# ---- menu --------------------------------------------------------------------

menu() {
  load_lib
  while true; do
    echo
    printf '\033[1;35m== korvarix cluster v%s ==\033[0m\n' "$KCV_VERSION"
    echo " host: $(hostname)   config: ${KCV_ENV_FILE}"
    echo " 1) Set up this machine (wizard: interface box / first node / donor / frontend)"
    echo " 2) Status & health check"
    echo " 3) VPN management (WireGuard: issue peer / list / revoke / join)"
    echo " 4) Models & inference (build, llama-server & rpc-server, add peer)"
    echo " 5) Ollama (sandboxed serve, allowlist, daily patches, policy)"
    echo " 6) Backup now / restore"
    echo " 7) Cron jobs (health 5min, backup nightly, ollama daily, usage report)"
    echo " 8) Update modules from repo"
    echo " 9) View logs"
    echo "10) Uninstall pieces"
    echo "11) korvarix-llm frontend (Open WebUI panel: install/gate/nginx)"
    echo "12) Usage report (nightly LLM usage summary -> webhook)"
    echo " 0) Exit"
    local r
    read -r -p "select: " r || exit 0
    case "$r" in
      1) kcv_run_module wizard ;;
      2) kcv_run_module status ;;
      3) kcv_run_module vpn ;;
      4) kcv_run_module llama ;;
      5) kcv_run_module ollama ;;
      6) kcv_run_module backup ;;
      7) kcv_run_module status cron ;;
      8) module_sync ;;
      9) kcv_run_module status logs ;;
      10) kcv_run_module uninstall ;;
      11) kcv_run_module korvarix-llm ;;
      12) kcv_run_module report ;;
      0) exit 0 ;;
      *) : ;;
    esac
  done
}

# ---- entry -------------------------------------------------------------------

# shellcheck disable=SC2124  # "$@" is passed through verbatim
case "${1:-}" in
  "")     if kcv_tty; then menu; else die "non-interactive: pass a subcommand (health|backup|update|<module>)"; fi ;;
  update) module_sync ;;
  *)      load_lib; require_root; kcv_run_module "$1" "${@:2}" ;;
esac