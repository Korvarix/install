#!/usr/bin/env bash
# module: lib
# Shared engine sourced by every module. Not user-facing.
# Provides: logging, env handling, prompts, dependency self-check + auto-install,
# distro-agnostic package install, network gates, state, cron, firewall, services.

KCV_PREFIX="korvarix"
KCV_ETC_DIR="/etc/${KCV_PREFIX}-cluster"
KCV_LIB_DIR="/var/lib/${KCV_PREFIX}-cluster"
KCV_STATE_FILE="${KCV_LIB_DIR}/state"
KCV_ENV_FILE="${KCV_ETC_DIR}/korvarix.env"
KCV_LOG_DIR="/var/log/${KCV_PREFIX}"
# shellcheck disable=SC2034  # consumed by the station and other modules
KCV_MODULES_DIR="${KCV_LIB_DIR}/modules"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok \033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m %s\n' "$*" >&2; exit 1; }
kcv_tty() { [[ -t 0 ]]; }

kcv_init() {
  mkdir -p "$KCV_ETC_DIR" "$KCV_LIB_DIR" "$KCV_LOG_DIR"
}

kcv_env_missing() { [[ ! -f "$KCV_ENV_FILE" ]]; }

kcv_require_env() {
  kcv_env_missing && die "no config at $KCV_ENV_FILE - run the setup wizard first (menu 1)"
}

kcv_ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" reply
  if [[ -n "${!__var:-}" ]]; then return 0; fi
  if kcv_tty; then
    if [[ -n "$__default" ]]; then
      read -r -p "$__prompt [$__default]: " reply || die "input failed"
    else
      read -r -p "$__prompt: " reply || die "input failed"
    fi
    reply="${reply:-$__default}"
  else
    [[ -n "$__default" ]] || die "non-interactive: $__var not set in $KCV_ENV_FILE"
    reply="$__default"
  fi
  printf -v "$__var" '%s' "$reply"
}

kcv_confirm() {
  local __reply
  if ! kcv_tty; then warn "non-interactive: auto-confirming: $1"; return 0; fi
  read -r -p "$1 [Y/n] " __reply || die "input failed"
  case "${__reply:-y}" in n|N) return 1 ;; *) return 0 ;; esac
}

pkg_install() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq && apt-get -y -qq install "$@"
  elif command -v dnf >/dev/null 2>&1; then dnf -y -q install "$@"
  elif command -v yum >/dev/null 2>&1; then yum -y -q install "$@"
  elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install "$@"
  elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm --quiet "$@"
  elif command -v apk >/dev/null 2>&1; then apk add --no-cache --quiet "$@"
  else die "no known package manager - install manually: $*"
  fi
}

# dep_ensure "binary:package" ... - checks, prompts, installs, re-verifies
dep_ensure() {
  local missing=() entry bin pkg
  for entry in "$@"; do
    bin="${entry%%:*}"; pkg="${entry#*:}"
    command -v "$bin" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  log "missing dependencies: ${missing[*]}"
  if kcv_tty; then
    kcv_confirm "install ${missing[*]} with the system package manager?" || \
      die "declined - install manually, then re-run (nothing was changed)"
  fi
  pkg_install "${missing[@]}"
  for entry in "$@"; do
    bin="${entry%%:*}"; pkg="${entry#*:}"
    command -v "$bin" >/dev/null 2>&1 || \
      die "dependency still missing after install: $bin ($pkg) - install manually and re-run; nothing else was changed"
  done
  ok "dependencies satisfied: ${missing[*]}"
}

net_gate() {
  local url="$1"
  log "checking reachability: $url"
  curl -fsSI --max-time 10 -o /dev/null "$url" 2>/dev/null || \
    die "cannot reach $url - check network/DNS/firewall, then re-run"
}

fetch() {
  local url="$1" out="$2"
  curl -fsSL --retry 3 --max-time 120 -o "$out" "$url" || die "download failed: $url"
}

ssh_remote() {
  local host="$1"; shift
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "root@${host}" "$@"
}

state_set() {
  grep -v "^$1=" "$KCV_STATE_FILE" 2>/dev/null > "${KCV_STATE_FILE}.t" || true
  printf '%s=%s\n' "$1" "$2" >> "${KCV_STATE_FILE}.t"
  mv "${KCV_STATE_FILE}.t" "$KCV_STATE_FILE"
}
state_get() {
  local v
  v="$(grep "^$1=" "$KCV_STATE_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
  printf '%s' "$v"
}

cron_install() {
  local name="$1" schedule="$2" cmd="$3"
  printf '%s %s\n' "$schedule" "$cmd" > "/etc/cron.d/${KCV_PREFIX}-${name}"
  chmod 0644 "/etc/cron.d/${KCV_PREFIX}-${name}"
  ok "cron installed: /etc/cron.d/${KCV_PREFIX}-${name}"
}

cron_remove() {
  rm -f "/etc/cron.d/${KCV_PREFIX}-$1"
  ok "cron removed: $1"
}

fw_allow() {
  local proto="$1" port="$2"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$port/$proto" >/dev/null 2>&1 && ok "ufw: opened $port/$proto"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/${proto}" >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 && ok "firewalld: opened $port/$proto"
  else
    warn "no active firewall detected - ensure $port/$proto is reachable"
  fi
}

svc_write() {
  local name="$1" content="$2"
  printf '%s\n' "$content" > "/etc/systemd/system/${KCV_PREFIX}-${name}.service"
  systemctl daemon-reload
  systemctl enable "${KCV_PREFIX}-${name}" >/dev/null 2>&1 || true
}

svc_active() { systemctl is-active --quiet "${KCV_PREFIX}-$1" 2>/dev/null; }

kcv_virt_check() {
  local virt
  virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  case "$virt" in
    kvm|qemu|none) ok "virtualization: $virt" ;;
    *) die "virtualization '$virt' unsupported (needs KVM/QEMU) - see CLUSTER.md purchase checklist" ;;
  esac
}

kcv_base_tools() {
  dep_ensure "curl:curl" "chronyc:chrony"
  systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || true
}

kcv_next_vpn_ip() {
  local i used
  for i in $(seq 10 250); do
    used="$(state_get "vpn_ip_$i")"
    [[ -z "$used" ]] && { echo "10.8.0.$i"; return 0; }
  done
  return 1
}