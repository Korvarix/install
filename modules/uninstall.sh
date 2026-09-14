#!/usr/bin/env bash
# module: uninstall
# Removes korvarix pieces. Bricks are NEVER wiped automatically -
# only via explicit wipe-bricks. Menu entrypoint: kcv_module_uninstall.

uninstall_run() {
  kcv_init
  local scope="${1:-all}"
  log "uninstall: scope=$scope"

  if [[ "$scope" == "all" || "$scope" == "llama" ]]; then
    systemctl stop korvarix-llama-server korvarix-rpc-server 2>/dev/null || true
    systemctl disable korvarix-llama-server korvarix-rpc-server 2>/dev/null || true
    rm -f /etc/systemd/system/korvarix-llama-server.service /etc/systemd/system/korvarix-rpc-server.service
  fi

  if [[ "$scope" == "all" || "$scope" == "k3s" ]]; then
    /usr/local/bin/k3s-killall.sh 2>/dev/null || true
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
  fi

  if [[ "$scope" == "all" || "$scope" == "vpn" ]]; then
    systemctl stop korvarix-vpn-server 2>/dev/null || true
    systemctl disable korvarix-vpn-server 2>/dev/null || true
    systemctl stop "openvpn-client@korvarix" 2>/dev/null || true
    systemctl disable "openvpn-client@korvarix" 2>/dev/null || true
    rm -f /etc/systemd/system/korvarix-vpn-server.service
  fi

  if [[ "$scope" == "all" || "$scope" == "cron" ]]; then
    cron_remove health
    cron_remove backup
  fi

  systemctl daemon-reload
  ok "uninstall: done (gluster + brick data preserved)"

  if [[ "$scope" == "wipe-bricks" ]]; then
    kcv_confirm "REALLY wipe ${GLUSTER_BRICK:-/data/brick} and delete volume ${GLUSTER_VOLUME:-gv0}? UNRECOVERABLE." || { warn "wipe aborted"; return 0; }
    umount "${GLUSTER_MOUNT:-/mnt/gv0}" 2>/dev/null || true
    gluster volume stop "${GLUSTER_VOLUME:-gv0}" 2>/dev/null || true
    gluster volume delete "${GLUSTER_VOLUME:-gv0}" 2>/dev/null || true
    rm -rf "${GLUSTER_BRICK:?}"
    ok "brick wiped"
  else
    warn "brick ${GLUSTER_BRICK:-/data/brick} preserved - manual wipe:"
    warn "  umount ${GLUSTER_MOUNT:-/mnt/gv0}; gluster volume stop ${GLUSTER_VOLUME:-gv0}; gluster volume delete ${GLUSTER_VOLUME:-gv0}; rm -rf ${GLUSTER_BRICK:-/data/brick}"
  fi
}

kcv_module_uninstall() {
  local scope="${1:-menu}"
  if [[ "$scope" != "menu" ]]; then
    if kcv_tty; then
      kcv_confirm "uninstall korvarix pieces (scope: $scope)? gluster data is preserved" || return 0
    fi
    uninstall_run "$scope"
    return 0
  fi
  echo "  1) uninstall everything (keep brick data)  2) also wipe bricks  0) back"
  local r; read -r -p "select: " r
  case "$r" in
    1) uninstall_run all ;;
    2) uninstall_run wipe-bricks ;;
    *) : ;;
  esac
}