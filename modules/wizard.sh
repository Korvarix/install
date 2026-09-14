#!/usr/bin/env bash
# module: wizard
# Guided role wizards: VPN box / first node (master) / additional node.
# Generates .env interactively, then walks each step with explanations.
# Entry: kcv_module_wizard

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
  kcv_ask NODE_NAME "This machine's name (e.g. korvai-vpn, llm-node1)" "$(hostname)"
  wiz_env_set NODE_NAME "$NODE_NAME"
}

wiz_cron_offer() {
  kcv_confirm "install monitoring cron (health every 5 min)? backup cron is offered separately" || return 0
  local station
  station="$(state_get station_path)"
  cron_install health "*/5 * * * *" "root $station health >> $KCV_LOG_DIR/health.log 2>&1"
}

wiz_role_vpn() {
  wiz_header "setup - VPN box"
  log "role: dedicated VPN hub (OpenVPN + CA + SSH jump). Small box is fine (1c/1GB)."
  log "gets NO gluster/k3s/llama - it only anchors cluster identity across node rebuilds."
  wiz_env_reset
  wiz_common
  VPN_PUBLIC_IP="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  kcv_ask VPN_PUBLIC_IP "Public IP of THIS box (nodes reach udp/1194 here)" "$VPN_PUBLIC_IP"
  wiz_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  wiz_env_set VPN_NET "10.8.0.0"
  wiz_env_set VPN_MASK "255.255.255.0"
  state_set role vpn
  log "config saved - installing the hub..."
  kcv_run_module vpn setup
  ok "VPN box ready. Next: menu 3 -> issue client certs for EVERY node (use each node's NODE_NAME)."
}

wiz_role_master() {
  wiz_header "setup - first node (master)"
  log "role: node1 - k3s server + llama-server + first storage brick (storage never touched again)"
  wiz_env_reset
  wiz_common
  kcv_ask VPN_PUBLIC_IP "VPN box public IP" ""
  wiz_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  kcv_ask GLUSTER_BRICK "Local brick path (this disk you keep forever)" "/data/brick"
  kcv_ask GLUSTER_MOUNT "Shared pool mount point" "/mnt/gv0"
  kcv_ask GLUSTER_VOLUME "Volume name" "gv0"
  wiz_env_set MODELS_DIR "/mnt/gv0/models"
  state_set role master
  state_set vpn_expected 1

  log "step 1/5: join VPN (have the .ovpn file issued from the VPN box ready)"
  kcv_run_module vpn join
  NODE_VPN_IP="$(state_get vpn_local_ip)"
  wiz_env_set NODE_VPN_IP "$NODE_VPN_IP"
  wiz_env_set MASTER_VPN_IP "$NODE_VPN_IP"
  ok "step 1/5 - this master is $NODE_VPN_IP"

  log "step 2/5: storage pool (first brick)"
  kcv_run_module gluster init
  ok "step 2/5 - pool live at $GLUSTER_MOUNT"

  log "step 3/5: k3s control plane"
  kcv_run_module k3s-server
  ok "step 3/5"

  log "step 4/5: llama.cpp build + llama-server"
  kcv_run_module llama build
  local mf
  mf="$(state_get MODEL_FILE)"
  kcv_ask MODEL_FILE "gguf filename inside $GLUSTER_MOUNT/models (empty = skip serving for now)" ""
  mf="$MODEL_FILE"
  wiz_env_set MODEL_FILE "$mf"
  if [[ -n "$mf" ]]; then
    kcv_run_module llama start
  else
    warn "no model set - start later via menu 4 (set-model + start)"
  fi

  log "step 5/5: monitoring cron"
  wiz_cron_offer
  ok "MASTER COMPLETE. Next: on each new node run this script -> wizard -> Additional node."
}

wiz_role_node() {
  wiz_header "setup - additional node"
  log "role: node N - joins VPN, storage pool (+1 brick, no wipe), k3s, RPC"
  wiz_env_reset
  wiz_common
  kcv_ask VPN_PUBLIC_IP "VPN box public IP" ""
  wiz_env_set VPN_PUBLIC_IP "$VPN_PUBLIC_IP"
  kcv_ask MASTER_VPN_IP "Master VPN IP (10.8.0.x - see menu 2 on master)" ""
  wiz_env_set MASTER_VPN_IP "$MASTER_VPN_IP"
  kcv_ask K3S_TOKEN "k3s join token (menu 2 on master shows it)" ""
  kcv_ask GLUSTER_BRICK "Local brick path" "/data/brick"
  kcv_ask GLUSTER_MOUNT "Shared pool mount point" "/mnt/gv0"
  kcv_ask GLUSTER_VOLUME "Volume name" "gv0"
  wiz_env_set MODELS_DIR "/mnt/gv0/models"
  state_set role node
  state_set vpn_expected 1

  log "step 1/5: join VPN"
  kcv_run_module vpn join
  NODE_VPN_IP="$(state_get vpn_local_ip)"
  wiz_env_set NODE_VPN_IP "$NODE_VPN_IP"
  ok "step 1/5 - this node is $NODE_VPN_IP"

  log "step 2/5: join storage pool"
  kcv_run_module gluster join
  ok "step 2/5"

  log "step 3/5: register brick on master + online rebalance"
  if ssh_remote "$MASTER_VPN_IP" true 2>/dev/null; then
    local station
    station="$(state_get station_path)"
    ssh_remote "$MASTER_VPN_IP" "$station gluster add-brick $NODE_VPN_IP" || \
      warn "remote add-brick failed - run it manually on the master: menu 5 -> add brick -> $NODE_VPN_IP"
  else
    warn "no SSH key to master - on the MASTER run: menu 5 -> add brick -> $NODE_VPN_IP"
    warn "  (or: korvarix-cluster.sh gluster add-brick $NODE_VPN_IP)"
  fi
  ok "step 3/5"

  log "step 4/5: k3s agent"
  kcv_run_module k3s-agent
  ok "step 4/5"

  log "step 5/5: rpc-server (offers this node's RAM to merged-RAM models)"
  kcv_run_module llama rpc-start
  wiz_cron_offer
  ok "NODE JOINED. Pool grew by: 8c/32GB CPU+RAM, 1 brick storage, ~30GB merged model RAM."
}

kcv_module_wizard() {
  wiz_header "setup wizard"
  echo "  1) VPN box          - tiny hub (OpenVPN + CA + SSH jump)"
  echo "  2) First node       - master: llama-server + k3s + first storage brick"
  echo "  3) Additional node  - joins storage (+1 brick, no wipe) + k3s + RPC"
  echo "  0) cancel"
  local r
  read -r -p "role [1-3]: " r || die "input failed"
  case "$r" in
    1) wiz_role_vpn ;;
    2) wiz_role_master ;;
    3) wiz_role_node ;;
    *) echo "cancelled" ;;
  esac
}