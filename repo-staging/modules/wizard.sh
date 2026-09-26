#!/usr/bin/env bash
# module: wizard
# Guided role wizards: interface box / first node (master) / additional node
# (RAM donor) / frontend box. Generates .env interactively, then walks each
# step with explanations. Entry: kcv_module_wizard

wiz_header() {
  printf '\033[1;35m== korvarix cluster - %s ==\033[0m\n\n' "$1"
}

wiz_env_reset() {
  mkdir -p "$KCV_ETC_DIR"
  if [[ -f "$KCV_ENV_FILE" ]]; then
    log "existing config: $KCV_ENV_FILE"
    if kcv_confirm "keep it and continue (recommended)? No = overwrite (backup kept)"; then
      return 0
    fi
    cp "$KCV_ENV_FILE" "${KCV_ENV_FILE}.bak.$(date +%s)"
  fi
  : > "$KCV_ENV_FILE"
}

wiz_env_set() {
  grep -v "^$1=" "$KCV_ENV_FILE" 2>/dev/null > "${KCV_ENV_FILE}.t" || true
  printf '%s=%s\n' "$1" "$2" >> "${KCV_ENV_FILE}.t"
  mv "${KCV_ENV_FILE}.t" "$KCV_ENV_FILE"
}

wiz_common() {
  kcv_ask NODE_NAME "This machine's name (e.g. llm-interface, llm-node1)" "$(hostname)"
  wiz_env_set NODE_NAME "$NODE_NAME"
}

wiz_cron_offer() {
  kcv_confirm "install monitoring cron (health every 5 min)? backup cron is offered separately" || return 0
  local station
  station="$(state_get station_path)"
  cron_install health "*/5 * * * *" "root $station health >> $KCV_LOG_DIR/health.log 2>&1"
}

wiz_role_vpn() {
  wiz_header "setup - interface box (WireGuard hub)"
  log "role: dedicated WireGuard hub + SSH jump. Small box is fine (4c/4GB)."
  log "gets NO llama/ollama - it anchors cluster identity and routes all VPN traffic."
  wiz_env_reset
  wiz_common
  VPN_PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  kcv_ask VPN_PUBLIC_IP "Public IP of THIS box (peers reach udp/${WG_PORT:-51820} here)" "$VPN_PUBLIC_IP"
  wiz_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  wiz_env_set VPN_NET "10.8.0.0"
  wiz_env_set VPN_MASK "24"
  state_set role vpn
  log "config saved - installing the hub..."
  kcv_run_module vpn setup
  ok "interface box ready. Next: menu 3 -> issue peer configs for EVERY other box"
  ok "(hub + node1 + each donor - use each box's NODE_NAME)."
}

wiz_role_master() {
  wiz_header "setup - first node (master)"
  log "role: node1 - model library on LOCAL disk (NFS-exported to workers)"
  log "+ its own sandboxed Ollama daemon. Models live at /data/models."
  wiz_env_reset
  wiz_common
  kcv_ask VPN_PUBLIC_IP "Interface box public IP" ""
  wiz_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  wiz_env_set MODELS_DIR "/data/models"
  state_set role master
  state_set vpn_expected 1

  log "step 1/4: join VPN (have the peer .conf issued from the interface box ready)"
  kcv_run_module vpn join
  NODE_VPN_IP="$(state_get vpn_local_ip)"
  wiz_env_set NODE_VPN_IP "$NODE_VPN_IP"
  wiz_env_set MASTER_VPN_IP "$NODE_VPN_IP"
  ok "step 1/4 - this master is $NODE_VPN_IP"

  log "step 2/4: ollama install (sandboxed) + serving on the VPN IP"
  wiz_env_set OLLAMA_BIND "$NODE_VPN_IP"
  kcv_run_module ollama install
  kcv_run_module ollama serve

  log "step 3/4: model serving"
  mkdir -p "${MODELS_DIR:-/data/models}"
  kcv_ask MODELS_ALLOWLIST "models clients may call (space-separated, e.g. qwen2.5:7b llama3.1:8b; empty = skip)" "${MODELS_ALLOWLIST:-}"
  if [[ -n "${MODELS_ALLOWLIST:-}" ]]; then
    kcv_run_module ollama pull
    if kcv_confirm "build + push the request policy to the frontend now?"; then
      kcv_run_module ollama policy
      kcv_run_module ollama push
    fi
  else
    warn "no models set - add later via menu 5 (allowlist + pull + policy)"
  fi

  log "step 4/4: monitoring cron"
  wiz_cron_offer
  ok "MASTER COMPLETE. Workers: run this script on each -> wizard -> 3) Additional node."
}

wiz_role_node() {
  wiz_header "setup - additional node (Ollama worker)"
  log "role: node N - joins the VPN + runs its own sandboxed Ollama daemon."
  log "inference is LOCAL to each node (RAM cannot be pooled over the network);"
  log "the master serves model files (NFS) and the frontend load-balances the pool."
  wiz_env_reset
  wiz_common
  kcv_ask VPN_PUBLIC_IP "Interface box public IP" ""
  wiz_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  kcv_ask MASTER_VPN_IP "Master VPN IP (10.8.0.x - menu 2 on master)" ""
  wiz_env_set MASTER_VPN_IP "$MASTER_VPN_IP"
  state_set role node
  state_set vpn_expected 1

  log "step 1/4: join VPN (peer .conf from the interface box)"
  kcv_run_module vpn join
  NODE_VPN_IP="$(state_get vpn_local_ip)"
  wiz_env_set NODE_VPN_IP "$NODE_VPN_IP"
  ok "step 1/4 - this node is $NODE_VPN_IP"

  log "step 2/4: ollama install (sandboxed) + serving on the VPN IP"
  wiz_env_set OLLAMA_BIND "$NODE_VPN_IP"
  kcv_run_module ollama install
  kcv_run_module ollama serve

  log "step 3/4: pull the allowlist models (master's MODELS_ALLOWLIST)"
  kcv_run_module ollama pull

  log "step 4/4: monitoring cron"
  wiz_cron_offer
  echo
  warn "LAST STEP (on the FRONTEND, once): add this node to the inference pool:"
  warn "  append http://$NODE_VPN_IP:${OLLAMA_PORT:-11434} to OLLAMA_BASE_URLS in korvarix-llm/.env"
  warn "  then: ./install.sh && ./install.sh ollama-check"
  ok "NODE JOINED. Pool capacity grows one full Ollama daemon (2-4 concurrent slots)."
}

wiz_role_frontend() {
  wiz_header "setup - frontend box (Open WebUI panel)"
  log "role: korvarix-llm - Open WebUI + SSO gate + nginx. Joins the VPN to reach"
  log "the Ollama worker pool (master 10.8.0.x first) and receives the policy push."
  wiz_env_reset
  wiz_common
  kcv_ask VPN_PUBLIC_IP "Interface box public IP" ""
  wiz_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  kcv_ask MASTER_VPN_IP "Master VPN IP (10.8.0.x - menu 2 on master)" ""
  wiz_env_set MASTER_VPN_IP "$MASTER_VPN_IP"
  state_set role frontend
  state_set vpn_expected 1

  log "step 1/2: join VPN (peer .conf from the interface box)"
  kcv_run_module vpn join
  NODE_VPN_IP="$(state_get vpn_local_ip)"
  wiz_env_set NODE_VPN_IP "$NODE_VPN_IP"
  wiz_env_set FRONTEND_VPN_IP "$NODE_VPN_IP"
  ok "step 1/2 - this frontend is $NODE_VPN_IP"

  log "step 2/2: korvarix-llm frontend (Open WebUI + gate + nginx)"
  kcv_run_module korvarix-llm
  wiz_cron_offer
  ok "FRONTEND DONE. Clients hit https://llm.korvarix.com (or LLM_DOMAIN)."
}

kcv_module_wizard() {
  wiz_header "setup wizard"
  echo "  1) Interface box    - WireGuard hub + SSH jump (small box)"
  echo "  2) First node       - master: model library on local disk + own Ollama"
  echo "  3) Additional node  - Ollama worker: VPN + own Ollama daemon (pool slot)"
  echo "  4) Frontend box     - Open WebUI panel (korvarix-llm)"
  echo "  0) cancel"
  local r
  read -r -p "role [1-4]: " r || die "input failed"
  case "$r" in
    1) wiz_role_vpn ;;
    2) wiz_role_master ;;
    3) wiz_role_node ;;
    4) wiz_role_frontend ;;
    *) echo "cancelled" ;;
  esac
}