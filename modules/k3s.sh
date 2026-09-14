#!/usr/bin/env bash
# module: k3s
# Cluster CPU/RAM pool. server = master (node1), agent = every other node.
# Entry: k3s-server / k3s-agent (called by wizard and station).

k3s_server() {
  require_root
  log "k3s: installing server"
  kcv_virt_check
  kcv_base_tools
  net_gate "https://get.k3s.io"
  [[ -n "${NODE_VPN_IP:-}" ]] || die "NODE_VPN_IP empty in $KCV_ENV_FILE"
  local iface
  iface="$(state_get vpn_iface)"; iface="${iface:-tun0}"

  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_CHANNEL=stable sh -s - server \
      --node-name="$(hostname)" \
      --node-ip="$NODE_VPN_IP" \
      --node-external-ip="$NODE_VPN_IP" \
      --flannel-iface="$iface" \
      --disable traefik || die "k3s server install failed"
  sleep 5
  k3s kubectl get nodes -o wide 2>/dev/null || die "k3s not answering"
  local token
  token="$(cat /var/lib/rancher/k3s/server/node-token 2>/dev/null)" || die "no node-token found"
  state_set k3s_token "$token"
  ok "k3s: server up - token saved (view via menu 2 -> status on this master)"
}

k3s_agent() {
  require_root
  log "k3s: installing agent"
  kcv_virt_check
  kcv_base_tools
  net_gate "https://get.k3s.io"
  [[ -n "${K3S_TOKEN:-}" ]] || die "K3S_TOKEN empty in $KCV_ENV_FILE (get it from the master: menu 2 -> status)"
  [[ -n "${MASTER_VPN_IP:-}" ]] || die "MASTER_VPN_IP empty in $KCV_ENV_FILE"
  [[ -n "${NODE_VPN_IP:-}" ]] || die "NODE_VPN_IP empty in $KCV_ENV_FILE"
  local iface
  iface="$(state_get vpn_iface)"; iface="${iface:-tun0}"

  curl -sfL https://get.k3s.io | \
    K3S_TOKEN="$K3S_TOKEN" sh -s - agent \
      --server "https://$MASTER_VPN_IP:6443" \
      --node-name="$(hostname)" \
      --node-ip="$NODE_VPN_IP" \
      --node-external-ip="$NODE_VPN_IP" \
      --flannel-iface="$iface" || die "k3s agent install failed"
  sleep 3
  systemctl is-active --quiet k3s-agent || die "k3s-agent not active - journalctl -u k3s-agent"
  ok "k3s: agent joined ($MASTER_VPN_IP:6443)"
}

k3s_status() {
  if command -v k3s >/dev/null 2>&1; then
    k3s kubectl get nodes -o wide 2>/dev/null || echo "k3s: installed, no nodes visible"
  else
    echo "k3s: not installed"
  fi
}