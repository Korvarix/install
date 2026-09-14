#!/usr/bin/env bash
# module: gluster
# Distributed (RAID 0 semantics) storage pool. One brick per node, equal size,
# grows +1 brick per node online - never wiped. Menu entrypoint: kcv_module_gluster.

gluster_install_base() {
  kcv_virt_check
  kcv_base_tools
  dep_ensure "glusterd:glusterfs-server" "gluster:glusterfs-client"
  systemctl enable --now glusterd >/dev/null 2>&1 || true
  mkdir -p "$GLUSTER_BRICK" "$GLUSTER_MOUNT"
}

gluster_pool_init() {
  require_root
  log "gluster: installing + creating distributed volume (master/first node)"
  gluster_install_base
  net_gate "https://github.com/gluster/glusterfs"

  if ! gluster volume info "$GLUSTER_VOLUME" >/dev/null 2>&1; then
    log "gluster: creating distributed volume '$GLUSTER_VOLUME' (1 brick now - grows +1 per node)"
    gluster volume create "$GLUSTER_VOLUME" "$(hostname):$GLUSTER_BRICK" force || \
      die "volume create failed - is $GLUSTER_BRICK on a separate disk/filesystem? (single-node needs 'force')"
  fi
  gluster volume start "$GLUSTER_VOLUME" 2>/dev/null || true

  if ! mountpoint -q "$GLUSTER_MOUNT"; then
    log "gluster: mounting $GLUSTER_MOUNT"
    mount -t glusterfs "$(hostname):/$GLUSTER_VOLUME" "$GLUSTER_MOUNT" || die "mount failed"
    grep -q "glusterfs.*$GLUSTER_MOUNT" /etc/fstab 2>/dev/null || \
      echo "$(hostname):/$GLUSTER_VOLUME $GLUSTER_MOUNT glusterfs defaults,_netdev 0 0" >> /etc/fstab
  fi
  mkdir -p "$GLUSTER_MOUNT/models"
  state_set gluster_ready 1
  ok "gluster: pool live at $GLUSTER_MOUNT"
}

gluster_pool_join() {
  require_root
  log "gluster: joining the pool as a peer"
  gluster_install_base
  [[ -n "${MASTER_VPN_IP:-}" ]] || die "MASTER_VPN_IP empty in $KCV_ENV_FILE"
  log "gluster: probing master ($MASTER_VPN_IP)"
  gluster peer probe "$MASTER_VPN_IP" || die "probe failed - check VPN (ping $MASTER_VPN_IP)"
  sleep 2
  gluster volume info "$GLUSTER_VOLUME" >/dev/null 2>&1 || {
    sleep 5
    gluster volume info "$GLUSTER_VOLUME" >/dev/null 2>&1 || warn "volume not visible yet - master adds this brick via menu 5 (add-brick)"
  }
  gluster volume start "$GLUSTER_VOLUME" 2>/dev/null || true
  ok "gluster: peered (brick gets added to the volume from the master)"
}

gluster_add_brick() {
  require_root
  kcv_require_env
  local newhost="$1"
  if [[ -z "$newhost" ]] && kcv_tty; then
    read -r -p "new node hostname or VPN IP: " newhost || die "input failed"
  fi
  [[ -n "$newhost" ]] || die "usage: korvarix-cluster.sh gluster add-brick <host|vpn-ip>"
  gluster volume info "$GLUSTER_VOLUME" >/dev/null 2>&1 || die "volume $GLUSTER_VOLUME not here - run on master"
  if gluster volume info "$GLUSTER_VOLUME" 2>/dev/null | grep -q "$newhost:$GLUSTER_BRICK"; then
    warn "brick already in volume - skipping add"
  else
    gluster volume add-brick "$GLUSTER_VOLUME" "$newhost:$GLUSTER_BRICK" || \
      die "add-brick failed - is glusterd running on $newhost and peered?"
  fi
  log "gluster: online rebalance started (background, no downtime)"
  gluster volume rebalance "$GLUSTER_VOLUME" start 2>/dev/null || warn "rebalance already running"
  ok "gluster: brick $newhost added (progress: gluster volume rebalance $GLUSTER_VOLUME status)"
}

gluster_rebalance_status() {
  gluster volume rebalance "$GLUSTER_VOLUME" status 2>/dev/null || warn "rebalance not running"
}

kcv_module_gluster() {
  local action="${1:-menu}"
  case "$action" in
    init)        gluster_pool_init ;;
    join)        gluster_pool_join ;;
    add-brick)   shift; gluster_add_brick "$@" ;;
    rebalance)   gluster_rebalance_status ;;
    menu)
      echo "  1) add brick (grow pool)  2) rebalance status  0) back"
      local r; read -r -p "select: " r
      case "$r" in
        1) if [[ "$(state_get role)" == "master" ]]; then gluster_add_brick ""; else warn "add-brick runs on the master (it owns the volume)"; fi ;;
        2) gluster_rebalance_status ;;
        *) : ;;
      esac
      ;;
    *) die "usage: gluster init|join|add-brick <host>|rebalance" ;;
  esac
}