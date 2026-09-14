#!/usr/bin/env bash
# module: status
# Human-readable status board + health check runner + logs viewer.

status_board() {
  kcv_init
  echo
  log "status: $(hostname) (role: $(state_get role))"
  printf '%-14s %s\n' "vpn" "$(systemctl is-active openvpn-client@korvarix 2>/dev/null || systemctl is-active korvarix-vpn-server 2>/dev/null || echo 'n/a') $(ip -4 addr show tun0 2>/dev/null | grep -oE '10\.8\.0\.[0-9]+' | head -1)"
  command -v gluster >/dev/null 2>&1 && gluster volume info "${GLUSTER_VOLUME:-gv0}" 2>/dev/null | grep -E 'Volume Name|Status|Number of Bricks|Brick[0-9]' | sed 's/^/  /'
  mountpoint -q "${GLUSTER_MOUNT:-/mnt/gv0}" 2>/dev/null && echo "  mount: ok" || echo "  mount: not mounted"
  k3s_status
  svc_active llama-server && echo "  llama-server: running (port ${LLAMA_PORT:-8080})" || echo "  llama-server: stopped"
  svc_active rpc-server && echo "  rpc-server: running (port $(state_get rpc_port))" || echo "  rpc-server: stopped"
  echo "  disk: $(df -Ph "${GLUSTER_MOUNT:-/}" | awk 'NR==2{print $5" used"}')  mem: $(free | awk '/Mem:/{printf "%d%%", $3/$2*100}')"
  local token
  token="$(state_get k3s_token)"
  [[ -n "$token" && "$(state_get role)" == "master" ]] && { echo "  k3s_token: $token"; warn "agents need this in their .env"; }
}

logs_view() {
  kcv_init
  echo "  1) llama-server  2) rpc-server  3) vpn  4) k3s  5) health  6) backup"
  local r n=100
  read -r -p "select: " r
  case "$r" in
    1) journalctl -u korvarix-llama-server -n "$n" --no-pager ;;
    2) journalctl -u korvarix-rpc-server -n "$n" --no-pager ;;
    3) journalctl -u korvarix-vpn-server -n "$n" --no-pager 2>/dev/null || journalctl -u "openvpn-client@korvarix" -n "$n" --no-pager ;;
    4) journalctl -u k3s -n "$n" --no-pager 2>/dev/null || journalctl -u k3s-agent -n "$n" --no-pager ;;
    5) tail -"$n" "$KCV_LOG_DIR/health.log" 2>/dev/null || warn "no health log" ;;
    6) tail -"$n" "$KCV_LOG_DIR/backup.log" 2>/dev/null || warn "no backup log" ;;
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
  echo "  3) remove both crons"
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
    3) cron_remove health; cron_remove backup ;;
    *) : ;;
  esac
}

kcv_module_status() {
  if [[ "${1:-}" == "logs" ]]; then
    logs_view
    return 0
  fi
  status_board
  log "running health checks now..."
  kcv_run_module health || warn "health reported active failures (see above)"
}

kcv_module_cron() {
  cron_menu_run "$@"
}