#!/usr/bin/env bash
# module: vpn
# OpenVPN hub (dedicated mini VPN box) + client join + cert management.
# Menu entrypoint: kcv_module_vpn

vpn_hub_setup() {
  require_root
  log "vpn: setting up the OpenVPN hub"
  kcv_virt_check
  kcv_base_tools
  dep_ensure "openvpn:openvpn" "easyrsa:easy-rsa"
  net_gate "https://github.com/OpenVPN/easy-rsa"

  local pki="${KCV_LIB_DIR}/pki"
  local conf="/etc/openvpn/server/${KCV_PREFIX}-server.conf"

  if [[ ! -f "$pki/ca.crt" ]]; then
    log "vpn: creating CA at $pki"
    mkdir -p "$pki"
    if [[ ! -d "$pki/easy-rsa" ]]; then
      cp -r /usr/share/easy-rsa "$pki/easy-rsa" 2>/dev/null || \
        { fetch "https://github.com/OpenVPN/easy-rsa/releases/download/v3.1.7/easy-rsa-3.1.7.tar.gz" "/tmp/easyrsa.tgz"; mkdir -p "$pki/easy-rsa"; tar -xzf /tmp/easyrsa.tgz -C "$pki/easy-rsa" --strip-components=1; }
    fi
    ( cd "$pki/easy-rsa" && EASYRSA_PKI="$pki/pki" ./easyrsa --batch init-pki nopass && EASYRSA_PKI="$pki/pki" ./easyrsa --batch build-ca nopass ) \
      || die "CA creation failed"
  fi
  if [[ ! -f "$pki/pki/issued/server.crt" ]]; then
    ( cd "$pki/easy-rsa" && EASYRSA_PKI="$pki/pki" ./easyrsa --batch build-server-full server nopass ) || die "server cert failed"
  fi
  if [[ ! -f "$pki/pki/dh.pem" ]]; then
    ( cd "$pki/easy-rsa" && EASYRSA_PKI="$pki/pki" ./easyrsa gen-dh ) || die "dh failed"
  fi
  if [[ ! -f "$pki/pki/ta.key" ]]; then
    openvpn --genkey secret "$pki/pki/ta.key"
  fi

  if [[ ! -f "$conf" ]]; then
    log "vpn: writing $conf (subnet ${VPN_NET:-10.8.0.0}/24)"
    mkdir -p "$pki/ccd" /var/log/korvarix
    cat > "$conf" <<EOF
port 1194
proto udp
dev tun
ca $pki/pki/ca.crt
cert $pki/pki/issued/server.crt
key $pki/pki/private/server.key
dh $pki/pki/dh.pem
tls-auth $pki/pki/ta.key 0
server ${VPN_NET:-10.8.0.0} ${VPN_MASK:-255.255.255.0}
ifconfig-pool-persist /var/log/korvarix/ipp.txt
client-config-dir $pki/ccd
keepalive 10 60
persist-key
persist-tun
verb 3
EOF
  fi

  dep_ensure "sysctl:procps"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

  svc_write "vpn-server" "[Unit]
Description=korvarix OpenVPN hub
After=network.target
[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --config $conf
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target"
  fw_allow udp 1194
  systemctl restart "${KCV_PREFIX}-vpn-server"
  sleep 2
  systemctl is-active --quiet "${KCV_PREFIX}-vpn-server" || die "vpn hub failed to start - journalctl -u korvarix-vpn-server"
  state_set vpn_expected 0
  ok "vpn: hub running on udp/1194 ($(state_get VPN_PUBLIC_IP))"
  ok "next: menu 3 -> issue a client cert for EVERY node (use its NODE_NAME)"
}

vpn_issue() {
  require_root
  kcv_require_env
  local name="$1"
  if [[ -z "$name" ]] && kcv_tty; then
    read -r -p "client name (NODE_NAME of the node): " name || die "input failed"
  fi
  [[ -n "$name" ]] || die "usage: korvarix-cluster.sh vpn issue <node-name>"
  local pki="${KCV_LIB_DIR}/pki"
  [[ -f "$pki/ca.crt" ]] || die "no CA - run vpn setup (server role) first"
  if [[ -f "$pki/pki/issued/$name.crt" ]]; then
    warn "client '$name' already issued - regenerating cert only"
    ( cd "$pki/easy-rsa" && EASYRSA_PKI="$pki/pki" ./easyrsa --batch build-client-full "$name" nopass ) || die "cert issue failed"
  else
    ( cd "$pki/easy-rsa" && EASYRSA_PKI="$pki/pki" ./easyrsa --batch build-client-full "$name" nopass ) || die "cert issue failed"
  fi
  local vpn_ip
  vpn_ip="$(kcv_next_vpn_ip)" || die "VPN pool exhausted"
  mkdir -p "$pki/ccd"
  echo "ifconfig-push $vpn_ip 255.255.255.0" > "$pki/ccd/$name"
  state_set "vpn_ip_${vpn_ip##*.}" "$name"

  local out="${KCV_LIB_DIR}/client-configs"
  mkdir -p "$out"
  {
    echo "client"; echo "dev tun"; echo "proto udp"
    echo "remote $(state_get VPN_PUBLIC_IP) 1194"
    echo "resolv-retry infinite"; echo "nobind"
    echo "persist-key"; echo "persist-tun"
    echo "remote-cert-tls server"; echo "verb 3"
    echo "<ca>";    cat "$pki/pki/ca.crt";    echo "</ca>"
    echo "<cert>";  cat "$pki/pki/issued/$name.crt"; echo "</cert>"
    echo "<key>";   cat "$pki/pki/private/$name.key"; echo "</key>"
    echo "<tls-auth>"; cat "$pki/pki/ta.key"; echo "</tls-auth>"
  } > "$out/$name.ovpn"
  chmod 600 "$out/$name.ovpn"
  ok "issued $out/$name.ovpn -> static VPN IP $vpn_ip"
  ok "copy this file to $name and run: korvarix-cluster.sh vpn join /path/$name.ovpn"
}

vpn_join() {
  require_root
  kcv_require_env
  local conf_file="$1"
  if [[ -z "$conf_file" ]] && kcv_tty; then
    read -r -p "path to .ovpn file: " conf_file || die "input failed"
  fi
  [[ -n "$conf_file" && -f "$conf_file" ]] || die ".ovpn file not found: $conf_file"
  log "vpn: joining the korvarix VPN"
  kcv_base_tools
  dep_ensure "openvpn:openvpn"
  mkdir -p /etc/openvpn/client
  cp "$conf_file" "/etc/openvpn/client/${KCV_PREFIX}.conf"
  chmod 600 "/etc/openvpn/client/${KCV_PREFIX}.conf"
  systemctl enable --now "openvpn-client@${KCV_PREFIX}" >/dev/null 2>&1 || true
  sleep 3
  systemctl is-active --quiet "openvpn-client@${KCV_PREFIX}" || die "openvpn client failed - journalctl -u openvpn-client@korvarix"
  local tun_ip
  tun_ip="$(ip -4 addr show tun0 2>/dev/null | grep -oE '10\.8\.0\.[0-9]+' | head -1)"
  [[ -n "$tun_ip" ]] || die "tun0 has no 10.8.0.x address"
  state_set vpn_local_ip "$tun_ip"
  state_set vpn_expected 1
  ok "vpn: joined as $tun_ip"
}

vpn_list() {
  local ccd="${KCV_LIB_DIR}/pki/ccd"
  if [[ ! -d "$ccd" ]] || [[ -z "$(ls -A "$ccd" 2>/dev/null)" ]]; then
    warn "no clients issued yet"
    return 0
  fi
  log "issued clients (static VPN IPs):"
  local f
  for f in "$ccd"/*; do
    [[ -f "$f" ]] || continue
    printf '  %-20s %s\n' "$(basename "$f")" "$(grep ifconfig-push "$f" | awk '{print $2}')"
  done
}

kcv_module_vpn() {
  local action="${1:-menu}"
  case "$action" in
    setup)  vpn_hub_setup ;;
    issue)  shift; vpn_issue "$@" ;;
    join)   shift; vpn_join "$@" ;;
    list)   vpn_list ;;
    menu)
      if state_get VPN_PUBLIC_IP >/dev/null 2>&1 && [[ "$(state_get role)" == "vpn" ]]; then
        echo "  1) issue client cert  2) list clients  0) back"
        local r; read -r -p "select: " r
        case "$r" in 1) vpn_issue "" ;; 2) vpn_list ;; *) : ;; esac
      else
        echo "  1) join as client (this node)  2) list clients (hub only)  0) back"
        local r; read -r -p "select: " r
        case "$r" in 1) vpn_join "" ;; 2) vpn_list ;; *) : ;; esac
      fi
      ;;
    *) die "usage: vpn setup|issue <name>|join <file>|list" ;;
  esac
}