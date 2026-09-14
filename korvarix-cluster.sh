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

KCV_VERSION="0.1.0"
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
  curl -fsSL --max-time 30 "${KCV_REPO_URL}/manifest.txt" 2>/dev/null || return 1
}

manifest_sha() {
  module_list | awk -v n="$1" '$1==n{print $3}'
}

module_sync() {
  ensure_curl
  log "module repo: $KCV_REPO_URL"
  local manifest
  manifest="$(module_list)" || die "cannot reach module repo ($KCV_REPO_URL) - check network or set KCV_REPO_URL"
  mkdir -p "$KCV_MODULES_DIR"
  printf '%s\n' "$manifest" > "${KCV_MODULES_DIR}/manifest.txt"
  local updated=0 name ver sha want cur got
  while read -r name ver sha _rest; do
    [[ -n "$name" ]] || continue
    want="${KCV_MODULES_DIR}/${name}.sh"
    cur="none"
    [[ -f "$want" ]] && cur="$(sha256sum "$want" | awk '{print $1}')"
    if [[ "$cur" != "$sha" ]]; then
      curl -fsSL --retry 3 --max-time 120 -o "${want}.new" "${KCV_REPO_URL}/${name}.sh" \
        || die "download failed: $name (repo: $KCV_REPO_URL)"
      got="$(sha256sum "${want}.new" | awk '{print $1}')"
      [[ "$got" == "$sha" ]] || die "checksum mismatch for $name (expected $sha, got $got) - refusing to install"
      mv "${want}.new" "$want"
      updated=$((updated+1))
      ok "module updated: $name ($ver)"
    fi
  done <<EOF2
$manifest
EOF2
  [[ "$updated" -eq 0 ]] && ok "all modules up to date"
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
    echo " 1) Set up this machine (wizard: VPN box / first node / additional node)"
    echo " 2) Status & health check"
    echo " 3) VPN management (issue client / list / join)"
    echo " 4) Models & inference (build, start/stop llama-server & rpc-server)"
    echo " 5) Storage (add brick, rebalance status)"
    echo " 6) Backup now / restore"
    echo " 7) Cron jobs (health 5min, backup nightly)"
    echo " 8) Update modules from repo"
    echo " 9) View logs"
    echo "10) Uninstall pieces"
    echo "11) korvarix-llm frontend (Open WebUI panel: install/gate/nginx)"
    echo "12) Models & Ollama (sandboxed serve, allowlist, daily patches, policy)"
    echo " 0) Exit"
    local r
    read -r -p "select: " r || exit 0
    case "$r" in
      1) kcv_run_module wizard ;;
      2) kcv_run_module status ;;
      3) kcv_run_module vpn ;;
      4) kcv_run_module llama ;;
      5) kcv_run_module gluster ;;
      6) kcv_run_module backup ;;
      7) kcv_run_module cron ;;
      8) module_sync ;;
      9) kcv_run_module status logs ;;
      10) kcv_run_module uninstall ;;
      11) kcv_run_module korvarix-llm ;;
      12) kcv_run_module ollama ;;
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