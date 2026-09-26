#!/usr/bin/env bash
# module: uninstall
# Removes korvarix pieces. Model data is NEVER wiped automatically -
# only via explicit wipe-models. Menu entrypoint: kcv_module_uninstall.

uninstall_run() {
  kcv_init
  local scope="${1:-all}"
  log "uninstall: scope=$scope"

  if [[ "$scope" == "all" || "$scope" == "llama" ]]; then
    systemctl stop korvarix-llama-server korvarix-rpc-server 2>/dev/null || true
    systemctl disable korvarix-llama-server korvarix-rpc-server 2>/dev/null || true
    rm -f /etc/systemd/system/korvarix-llama-server.service /etc/systemd/system/korvarix-rpc-server.service
  fi

  # rpc-only scope: retire a merged-RAM donor (llama.cpp rpc-server era) and
  # keep everything else (VPN, ollama worker pool, monitoring) untouched.
  if [[ "$scope" == "rpc" ]]; then
    systemctl stop korvarix-rpc-server 2>/dev/null || true
    systemctl disable korvarix-rpc-server 2>/dev/null || true
    rm -f /etc/systemd/system/korvarix-rpc-server.service
    systemctl daemon-reload
    ok "rpc-server removed (llama.cpp build tree left in /var/lib/korvarix-cluster/llama.cpp)"
    ok "next on the MASTER: remove this donor from RPC_PEERS in /etc/korvarix-cluster/korvarix.env, then restart llama-server"
    warn "if converting this node to an Ollama worker instead: korvarix-cluster.sh ollama install && korvarix-cluster.sh ollama serve"
    return 0
  fi

  if [[ "$scope" == "all" || "$scope" == "ollama" ]]; then
    systemctl stop korvarix-ollama 2>/dev/null || true
    systemctl disable korvarix-ollama 2>/dev/null || true
    rm -f /etc/systemd/system/korvarix-ollama.service
    cron_remove ollama-patch
  fi

  if [[ "$scope" == "all" || "$scope" == "vpn" ]]; then
    systemctl stop "wg-quick@wg0" 2>/dev/null || true
    systemctl disable "wg-quick@wg0" 2>/dev/null || true
    rm -f /etc/wireguard/wg0.conf
    ip link del wg0 2>/dev/null || true
  fi

  if [[ "$scope" == "all" || "$scope" == "cron" ]]; then
    cron_remove health
    cron_remove backup
    cron_remove ollama-patch
    cron_remove hfmodels-patch
  fi

  systemctl daemon-reload
  ok "uninstall: done (models + wireguard keys preserved)"

  if [[ "$scope" == "wipe-models" ]]; then
    kcv_confirm "REALLY wipe ${MODELS_DIR:-/data/models}? UNRECOVERABLE (models are re-downloadable but large)." || { warn "wipe aborted"; return 0; }
    rm -rf "${MODELS_DIR:?}"
    ok "models wiped"
  else
    warn "models at ${MODELS_DIR:-/data/models} preserved - manual wipe: rm -rf ${MODELS_DIR:-/data/models}"
  fi
}

kcv_module_uninstall() {
  local scope="${1:-menu}"
  if [[ "$scope" != "menu" ]]; then
    if kcv_tty; then
      kcv_confirm "uninstall korvarix pieces (scope: $scope)? model data is preserved" || return 0
    fi
    uninstall_run "$scope"
    return 0
  fi
  echo "  1) uninstall everything (keep model data + WG keys)  2) also wipe models  0) back"
  echo "  3) retire rpc-server only (donor -> ollama worker conversion path)"
  local r; read -r -p "select: " r
  case "$r" in
    1) uninstall_run all ;;
    2) uninstall_run wipe-models ;;
    3) uninstall_run rpc ;;
    *) : ;;
  esac
}