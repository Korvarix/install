#!/usr/bin/env bash
# module: korvarix-llm
# Deploys the korvarix-llm FRONTEND (Open WebUI panel) via the cluster station.
# Thin wrapper around the box's own korvarix-llm/install.sh - this module only
# fetches the folder, wires it to the cluster (model endpoint), and orchestrates
# install + gate + nginx. All secrets stay in the frontend box's korvarix-llm/.env.
#
# Requires (set by wizard/env): LLM_FRONTEND_DIR, plus korvarix-llm's own knobs
# (LLM_DOMAIN, OPENAI_API_BASE_URL, WEBUI_ADMIN_EMAIL...).
# Entry: kcv_module_korvarix-llm

KLM_DIR="${LLM_FRONTEND_DIR:-/opt/korvarix-llm}"
# raw.githubusercontent fallback documented here; deploy uses git (history + updates)
# KLM_REPO_RAW=https://raw.githubusercontent.com/Korvarix/install/main/korvarix-llm

klm_fetch() {
  require_root
  kcv_base_tools
  dep_ensure "git:git"
  net_gate "https://github.com/Korvarix/install"
  if [[ -d "$KLM_DIR/.git" ]]; then
    log "korvarix-llm: updating checkout at $KLM_DIR"
    git -C "$KLM_DIR" fetch --all --quiet 2>/dev/null || true
    git -C "$KLM_DIR" reset --hard origin/main --quiet
  else
    log "korvarix-llm: cloning into $KLM_DIR"
    git clone --depth 1 https://github.com/Korvarix/install "$KLM_DIR" || die "clone failed"
  fi
  # the deployable folder lives at install/korvarix-llm in the repo
  [[ -f "$KLM_DIR/korvarix-llm/install.sh" ]] || die "$KLM_DIR/korvarix-llm/install.sh not found - repo layout changed?"
  # exec bits survive a clone only if the source repo committed them - this
  # one doesn't, so run install.sh via bash (and mark it anyway for its own
  # internal ./install.sh re-invocations, e.g. 'check' spawning hooks)
  chmod +x "$KLM_DIR/korvarix-llm/install.sh" 2>/dev/null || true
}

# seed cluster endpoints into the frontend's .env BEFORE first container boot
klm_wire_cluster() {
  local env_file="$KLM_DIR/korvarix-llm/.env"
  [[ -f "$env_file" ]] || return 0
  local master="${KLM_MASTER_ENDPOINT:-}"
  if [[ -z "$master" ]]; then
    master="${MASTER_VPN_IP:+http://$MASTER_VPN_IP:${LLAMA_PORT:-8080}/v1}"
    master="${master:-${NODE_VPN_IP:+http://$NODE_VPN_IP:${LLAMA_PORT:-8080}/v1}}"
  fi
  [[ -n "$master" ]] || { warn "no cluster endpoint known - leaving OPENAI_API_BASE_URL empty (set later in $env_file)"; return 0; }
  if grep -q '^OPENAI_API_BASE_URL=.\+' "$env_file"; then
    warn "OPENAI_API_BASE_URL already set - leaving it"
  else
    sed -i "s|^OPENAI_API_BASE_URL=.*|OPENAI_API_BASE_URL=$master|" "$env_file"
    log "wired cluster endpoint: $master"
  fi
  # ollama backend (pool or single node)
  # KLM_OLLAMA_ENDPOINTS (comma-separated, optional) wins; else master's
  # 11434. Written into OLLAMA_BASE_URLS (pool) when >1 endpoint, else
  # OLLAMA_BASE_URL. install.sh's ollama-check verifies every endpoint.
  local ollama="${KLM_OLLAMA_ENDPOINT:-}"
  local pool="${KLM_OLLAMA_ENDPOINTS:-}"
  if [[ -z "$pool" && -n "${MASTER_VPN_IP:-}" ]]; then
    pool="http://$MASTER_VPN_IP:${OLLAMA_PORT:-11434}"
  fi
  if [[ -n "$pool" ]] && ! grep -q '^OLLAMA_BASE_URLS=.\+' "$env_file"; then
    if [[ "$pool" == *","* ]]; then
      sed -i "s|^OLLAMA_BASE_URLS=.*|OLLAMA_BASE_URLS=$pool|" "$env_file"
      log "wired ollama pool: $pool"
    elif [[ -z "$ollama" ]]; then
      ollama="$pool"
    fi
  fi
  if [[ -n "$ollama" ]] && ! grep -q '^OLLAMA_BASE_URL=.\+' "$env_file"; then
    sed -i "s|^OLLAMA_BASE_URL=.*|OLLAMA_BASE_URL=$ollama|" "$env_file"
    log "wired ollama endpoint: $ollama"
  fi
}

klm_install() {
  require_root
  klm_fetch
  dep_ensure "docker:docker.io"
  docker info >/dev/null 2>&1 || die "docker not reachable - daemon down? (sudo usermod -aG docker \$USER)"
  klm_wire_cluster
  log "korvarix-llm: install/update"
  ( cd "$KLM_DIR/korvarix-llm" && bash install.sh ) || die "korvarix-llm install failed"
  ( cd "$KLM_DIR/korvarix-llm" && bash install.sh check ) || warn "check reported warnings above"
}

klm_gate() {
  require_root
  [[ -f "$KLM_DIR/korvarix-llm/install.sh" ]] || die "frontend not fetched yet - run korvarix-llm install first"
  log "korvarix-llm: SSO gate (needs LLM_SSO_KEY + OPEN_WEBUI_API_KEY afterwards)"
  ( cd "$KLM_DIR/korvarix-llm" && bash install.sh gate )
}

klm_nginx() {
  require_root
  [[ -f "$KLM_DIR/korvarix-llm/install.sh" ]] || die "frontend not fetched yet - run korvarix-llm install first"
  log "korvarix-llm: nginx proxy + Let's Encrypt (LLM_DOMAIN must be set in its .env)"
  ( cd "$KLM_DIR/korvarix-llm" && bash install.sh nginx )
}

klm_status() {
  local dir="$KLM_DIR/korvarix-llm"
  if [[ ! -f "$dir/install.sh" ]]; then
    echo "korvarix-llm frontend: not deployed"
    return 0
  fi
  docker ps --filter "name=^korvarix-llm$" --format '  container: running ({{.Status}})'
  docker ps --filter "name=^korvarix-llm-gate$" --format '  gate:      running ({{.Status}})'
  ( cd "$dir" && bash install.sh status )
}

# generic runner: every new install.sh subcommand is reachable from the
# station without its own wrapper (ollama-check, gate-off/on, check, ...)
klm_run() {
  local action="$1"; shift || true
  [[ -f "$KLM_DIR/korvarix-llm/install.sh" ]] || die "frontend not fetched yet - run korvarix-llm install first"
  ( cd "$KLM_DIR/korvarix-llm" && bash install.sh "$action" "$@" )
}

# ollama-check that works from ANY role. On the frontend it runs the real
# install.sh check (the pool is defined there in OLLAMA_BASE_URLS). On
# master/worker/interface (no /opt/korvarix-llm) it probes this cluster's
# own Ollama endpoints instead: MASTER_VPN_IP + NODE_VPN_IP, so a serving
# node can verify the whole pool from its own box.
klm_ollama_check() {
  local dir="$KLM_DIR/korvarix-llm"
  if [[ -f "$dir/install.sh" ]]; then
    ( cd "$dir" && bash install.sh ollama-check )
    return
  fi
  # not the frontend box: derive endpoints from the cluster config
  # - dedupe (master IP == NODE_VPN_IP must not probe itself twice)
  # - probe NODE_VPN_IP only when THIS box runs korvarix-ollama (a
  #   non-serving node must not report itself as a dead pool endpoint)
  local eps=()
  if [[ -n "${MASTER_VPN_IP:-}" ]]; then
    eps+=("http://$MASTER_VPN_IP:${OLLAMA_PORT:-11434}")
  elif [[ -n "${NODE_VPN_IP:-}" ]] && systemctl list-unit-files 2>/dev/null | grep -q korvarix-ollama; then
    eps+=("http://$NODE_VPN_IP:${OLLAMA_PORT:-11434}")
  fi
  if [[ -n "${NODE_VPN_IP:-}" && -n "${MASTER_VPN_IP:-}" && "${NODE_VPN_IP}" != "${MASTER_VPN_IP}" ]] \
     && systemctl list-unit-files 2>/dev/null | grep -q korvarix-ollama; then
    eps+=("http://$NODE_VPN_IP:${OLLAMA_PORT:-11434}")
  fi
  if ((${#eps[@]} == 0)); then
    die "no Ollama endpoints known on this box - set MASTER_VPN_IP (or install ollama: korvarix-cluster.sh ollama install) in $KCV_ENV_FILE, or run this on the frontend"
  fi
  local ok=0 total=0 ep rc
  for ep in "${eps[@]}"; do
    total=$((total + 1))
    curl -fs --max-time 5 "${ep%/}/api/version" >/dev/null 2>&1 \
      && { log "ollama OK: $ep"; ok=$((ok + 1)); } \
      || warn "ollama UNREACHABLE: $ep (daemon down? OLLAMA_BIND loopback? firewall?)"
  done
  if ((ok == total)); then
    ok "ollama pool: ${ok}/${total} endpoints answering"
  else
    warn "ollama pool: only ${ok}/${total} endpoints answering"
    return 1
  fi
}

klm_menu() {
  echo "  1) install/update frontend (Open WebUI + wiring)"
  echo "  2) install SSO gate      3) install nginx proxy"
  echo "  4) status                5) logs (100)   0) back"
  echo "  6) check (strict)        7) ollama-check (pool)"
  echo "  8) gate-off (EMERGENCY)  9) gate-on"
  local r
  read -r -p "select: " r
  case "$r" in
    1) klm_install ;;
    2) klm_gate ;;
    3) klm_nginx ;;
    4) klm_status ;;
    5) docker logs --tail 100 korvarix-llm 2>&1 | tail -100 ;;
    6) klm_run check || warn "check reported warnings above" ;;
    7) klm_ollama_check || warn "a pool endpoint is not answering" ;;
    8) kcv_confirm "EMERGENCY gate-off: panel opens WITHOUT korvarix.com SSO. Only for a base-site outage. Continue?" || return 0
       klm_run gate-off ;;
    9) klm_run gate-on ;;
    *) : ;;
  esac
}

kcv_module_korvarix-llm() {
  local action="${1:-menu}"
  case "$action" in
    install)      klm_install ;;
    gate)         klm_gate ;;
    nginx)        klm_nginx ;;
    status)       klm_status ;;
    fetch)        klm_fetch ;;
    check)        klm_run check ;;
    ollama-check) klm_ollama_check ;;
    gate-off)     klm_run gate-off ;;
    gate-on)      klm_run gate-on ;;
    menu)         klm_menu ;;
    *) die "usage: korvarix-llm install|gate|nginx|status|fetch|check|ollama-check|gate-off|gate-on" ;;
  esac
}