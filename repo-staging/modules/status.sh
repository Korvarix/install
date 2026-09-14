#!/usr/bin/env bash
# module: status
# Human-readable status board + health check runner + logs viewer.

status_board() {
  kcv_init
  echo
  log "status: $(hostname) (role: $(state_get role))"
  printf '%-14s %s\n' "vpn" "$(systemctl is-active wg-quick@korvarix 2>/dev/null || systemctl is-active korvarix-wg-hub 2>/dev/null || echo 'n/a') $(ip -4 addr show wg0 2>/dev/null | grep -oE '10\.8\.0\.[0-9]+' | head -1)"
  svc_active llama-server && echo "  llama-server: running (bind ${LLAMA_BIND:-$NODE_VPN_IP}, port ${LLAMA_PORT:-8080})" || echo "  llama-server: stopped"
  svc_active rpc-server && echo "  rpc-server: running ($(state_get rpc_port))" || echo "  rpc-server: stopped"
  if [[ "$(state_get role)" == "master" ]]; then
    kcv_run_module llama peers 2>/dev/null || true
  fi
  systemctl list-unit-files 2>/dev/null | grep -q korvarix-ollama && {
    svc_active ollama && echo "  ollama: running ($(state_get ollama_port))" || echo "  ollama: stopped"
    echo "  allowlist: ${MODELS_ALLOWLIST:-none set}"
  }
  echo "  models: ${MODELS_DIR:-/data/models}  disk: $(df -Ph "${MODELS_DIR:-/}" | awk 'NR==2{print $5" used"}')  mem: $(free | awk '/Mem:/{printf "%d%%", $3/$2*100}')"
}

logs_view() {
  kcv_init
  echo "  1) llama-server  2) rpc-server  3) wireguard  4) ollama  5) health  6) backup  7) usage report"
  local r n=100
  read -r -p "select: " r
  case "$r" in
    1) journalctl -u korvarix-llama-server -n "$n" --no-pager ;;
    2) journalctl -u korvarix-rpc-server -n "$n" --no-pager ;;
    3) journalctl -u korvarix-wg-hub -n "$n" --no-pager 2>/dev/null || journalctl -u "wg-quick@korvarix" -n "$n" --no-pager ;;
    4) journalctl -u korvarix-ollama -n "$n" --no-pager 2>/dev/null || warn "ollama not installed" ;;
    5) tail -"$n" "$KCV_LOG_DIR/health.log" 2>/dev/null || warn "no health log" ;;
    6) tail -"$n" "$KCV_LOG_DIR/backup.log" 2>/dev/null || warn "no backup log" ;;
    7) tail -"$n" "$KCV_LOG_DIR/usage-report.log" 2>/dev/null || warn "no usage report log" ;;
    *) : ;;
  esac
}

cron_menu_run() {
  kcv_init
  local station
  station="$(state_get station_path)"
  [[ -n "$station" ]] || die "station path unknown"
  echo "  1) install health cron (every 5 min)"
  echo "  2) install backup cron (nightly 04:17 + jitter)"
  echo "  3) install ollama daily cron (05:23 + jitter)"
  echo "  4) install usage report cron (05:43 nightly)"
  echo "  5) remove all crons"
  echo "  0) back"
  local r
  read -r -p "select: " r
  case "$r" in
    1) cron_install health "*/5 * * * *" "root $station health >> $KCV_LOG_DIR/health.log 2>&1" ;;
    2)
      kcv_require_env
      [[ -n "${BACKUP_TARGET:-}" ]] || die "BACKUP_TARGET empty in $KCV_ENV_FILE - set it first (menu 6)"
      cron_install backup "17 4 * * *" "root sleep \$((RANDOM % 3600)); $station backup >> $KCV_LOG_DIR/backup.log 2>&1"
      ;;
    3) kcv_run_module ollama cron ;;
    4) kcv_run_module report cron ;;
    5) cron_remove health; cron_remove backup; cron_remove ollama-patch; cron_remove usage-report ;;
    *) : ;;
  esac
}

kcv_module_status() {
  if [[ "${1:-}" == "logs" ]]; then
    logs_view
    return 0
  fi
  if [[ "${1:-}" == "cron" ]]; then
    shift || true
    cron_menu_run "$@"
    return 0
  fi
  status_board
  log "running health checks now..."
  kcv_run_module health || warn "health reported active failures (see above)"
}

kcv_module_cron() {
  cron_menu_run "$@"
}