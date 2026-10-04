#!/usr/bin/env bash
# module: allinone
# All-in-One Setup: Combines VPN Hub, Master Node, and Frontend on a single box.
# Eliminates the need for specialized roles for small deployments.
# Entry: kcv_module_allinone

allinone_env_reset() {
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

allinone_env_set() {
  grep -v "^$1=" "$KCV_ENV_FILE" 2>/dev/null > "${KCV_ENV_FILE}.t" || true
  printf '%s=%s\n' "$1" "$2" >> "${KCV_ENV_FILE}.t"
  mv "${KCV_ENV_FILE}.t" "$KCV_ENV_FILE"
}

kcv_module_allinone() {
  printf '\033[1;35m== korvarix cluster - All-in-One Setup ==\033[0m\n\n'
  log "role: Hub + Master + Frontend on one machine"
  
  allinone_env_reset
  
  kcv_ask NODE_NAME "This machine's name (e.g. korvarix-allinone)" "$(hostname)"
  allinone_env_set NODE_NAME "$NODE_NAME"
  
  VPN_PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  kcv_ask VPN_PUBLIC_IP "Public IP of this box" "$VPN_PUBLIC_IP"
  allinone_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  allinone_env_set VPN_NET "10.8.0.0"
  allinone_env_set VPN_MASK "24"
  
  log "step 1/5: Setting up VPN Hub..."
  kcv_run_module vpn setup
  
  log "step 2/5: Building llama.cpp & starting RPC server..."
  kcv_run_module llama build
  allinone_env_set NODE_VPN_IP "10.8.0.1"
  allinone_env_set MASTER_VPN_IP "10.8.0.1"
  kcv_run_module llama rpc-start
  
  log "step 3/5: Setting up llama-server..."
  allinone_env_set MODELS_DIR "/data/models"
  kcv_ask MODEL_FILE "gguf filename inside /data/models (empty = skip for now)" ""
  allinone_env_set MODEL_FILE "$MODEL_FILE"
  if [[ -n "$MODEL_FILE" ]]; then
    kcv_run_module llama start
  else
    warn "no model set - start later via menu 4"
  fi
  
  log "step 4/5: Installing korvarix-llm frontend..."
  kcv_run_module korvarix-llm install
  
  log "step 5/5: Finalizing frontend (NGINX/Domain)..."
  kcv_ask LLM_DOMAIN "Domain for LLM panel (e.g. llm.example.com)" ""
  allinone_env_set LLM_DOMAIN "$LLM_DOMAIN"
  if [[ -n "$LLM_DOMAIN" ]]; then
    kcv_run_module korvarix-llm nginx
  fi
  
  state_set role allinone
  state_set vpn_expected 1
  
  ok "ALL-IN-ONE SETUP COMPLETE"
  ok "Your cluster is now hosted on a single machine."
}
