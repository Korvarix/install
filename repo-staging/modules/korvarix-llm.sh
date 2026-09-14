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
  # ollama backend (allowlist models) when the master serves one
  local ollama="${KLM_OLLAMA_ENDPOINT:-}"
  if [[ -z "$ollama" && -n "${MASTER_VPN_IP:-}" ]]; then
    ollama="http://$MASTER_VPN_IP:${OLLAMA_PORT:-11434}"
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
  ( cd "$KLM_DIR/korvarix-llm" && ./install.sh )
  ( cd "$KLM_DIR/korvarix-llm" && ./install.sh check ) || warn "check reported warnings above"
}

klm_gate() {
  require_root
  [[ -f "$KLM_DIR/korvarix-llm/install.sh" ]] || die "frontend not fetched yet - run korvarix-llm install first"
  log "korvarix-llm: SSO gate (needs LLM_SSO_KEY + OPEN_WEBUI_API_KEY afterwards)"
  ( cd "$KLM_DIR/korvarix-llm" && ./install.sh gate )
}

klm_nginx() {
  require_root
  [[ -f "$KLM_DIR/korvarix-llm/install.sh" ]] || die "frontend not fetched yet - run korvarix-llm install first"
  log "korvarix-llm: nginx proxy + Let's Encrypt (LLM_DOMAIN must be set in its .env)"
  ( cd "$KLM_DIR/korvarix-llm" && ./install.sh nginx )
}

klm_status() {
  local dir="$KLM_DIR/korvarix-llm"
  if [[ ! -f "$dir/install.sh" ]]; then
    echo "korvarix-llm frontend: not deployed"
    return 0
  fi
  docker ps --filter "name=^korvarix-llm$" --format '  container: running ({{.Status}})'
  docker ps --filter "name=^korvarix-llm-gate$" --format '  gate:      running ({{.Status}})'
  ( cd "$dir" && ./install.sh status )
}

klm_menu() {
  echo "  1) install/update frontend (Open WebUI + wiring)"
  echo "  2) install SSO gate      3) install nginx proxy"
  echo "  4) status                5) logs (100)   0) back"
  local r
  read -r -p "select: " r
  case "$r" in
    1) klm_install ;;
    2) klm_gate ;;
    3) klm_nginx ;;
    4) klm_status ;;
    5) docker logs --tail 100 korvarix-llm 2>&1 | tail -100 ;;
    *) : ;;
  esac
}

kcv_module_korvarix-llm() {
  local action="${1:-menu}"
  case "$action" in
    install) klm_install ;;
    gate)    klm_gate ;;
    nginx)   klm_nginx ;;
    status)  klm_status ;;
    fetch)   klm_fetch ;;
    menu)    klm_menu ;;
    *) die "usage: korvarix-llm install|gate|nginx|status|fetch" ;;
  esac
}