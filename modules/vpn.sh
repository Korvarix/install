#!/usr/bin/env bash
# module: vpn
# WireGuard hub (dedicated mini interface box) + peer issue + join + revoke.
# Replaces the OpenVPN design: kernel-space crypto (parallel, multi-Gbps),
# lower latency (RPC round-trips ride the tunnel).
# Naming: EVERY box uses /etc/wireguard/wg0.conf -> interface wg0 everywhere
# (hub included), so health/status checks are uniform.
# Menu entrypoint: kcv_module_vpn

WG_DIR="${KCV_LIB_DIR}/wireguard"
WG_PORT="${WG_PORT:-51820}"
WG_NET="${VPN_NET:-10.8.0.0}"
WG_MASK="${VPN_MASK:-24}"
WG_IFACE="wg0"
WG_HUB_CONF="/etc/wireguard/${WG_IFACE}.conf"
WG_CLI_CONF="/etc/wireguard/${WG_IFACE}.conf"

# ---- helpers ------------------------------------------------------------------

# generate a WireGuard keypair to stdout: line1 private, line2 public
_wg_keypair() {
  local priv
  priv="$(wg genkey)" || die "wg genkey failed"
  printf '%s\n%s\n' "$priv" "$(wg pubkey <<<"$priv")"
}

# print the [Peer] block (if any) whose comment names $1 from the hub conf
_wg_peer_block() {
  awk -v n="$1" '
    /^\[Peer\]/ {inpeer=1; buf=$0"\n"; next}
    inpeer { buf=buf $0"\n"; if ($0=="# "n) { printf "%s", buf; exit } }
    /^\[Interface\]/,/^$/{next}
    {next}
  ' "$WG_HUB_CONF" 2>/dev/null
}

# remove the [Peer] block whose comment names $1 from the hub conf (in place)
_wg_peer_del() {
  local name="$1" tmp
  tmp="$(mktemp)"
  awk -v n="$name" '
    BEGIN{inpeer=0; drop=0; buf=""}
    /^\[Peer\]/ {
      if (inpeer && !drop) printf "%s", buf
      buf=$0"\n"; inpeer=1; drop=0; next
    }
    inpeer {
      buf=buf $0"\n"
      if ($0=="# "n) drop=1
      next
    }
    { if (inpeer && !drop) printf "%s", buf; inpeer=0; print }
    END{ if (inpeer && !drop) printf "%s", buf }
  ' "$WG_HUB_CONF" > "$tmp"
  if [[ ! -s "$tmp" ]]; then rm -f "$tmp"; die "rewrite produced empty config - aborting (nothing changed)"; fi
  mv "$tmp" "$WG_HUB_CONF"
}

_wg_hub_pubkey() {
  local priv
  priv="$(awk '/^PrivateKey/{print $3}' "$WG_HUB_CONF")"
  [[ -n "$priv" ]] || die "hub config has no PrivateKey"
  wg pubkey <<<"$priv"
}

_wg_sync() {
  wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_HUB_CONF") 2>/dev/null \
    || systemctl restart "wg-quick@${WG_IFACE}" 2>/dev/null || true
}

# bring wg0 up via systemd, surfacing the REAL error (a bare "Job failed" with
# swallowed output is undiagnosable - the journal holds the actual cause)
_wg_up() {
  local out
  if ! out="$(systemctl restart "wg-quick@${WG_IFACE}" 2>&1)"; then
    printf '%s\n' "$out" >&2
    journalctl -u "wg-quick@${WG_IFACE}" -n 15 --no-pager 2>/dev/null | sed 's/^/    /' >&2
    die "wg-quick@${WG_IFACE} failed - raw error + journal above"
  fi
  systemctl enable "wg-quick@${WG_IFACE}" >/dev/null 2>&1 || true
}

# a stale wg0 from a half-finished previous run makes wg-quick fail with
# "File exists" forever - the .conf file, not the interface, is the truth
_wg_stale_clear() {
  if ip link show "$WG_IFACE" >/dev/null 2>&1; then
    warn "stale $WG_IFACE interface found - removing it (config file is kept)"
    wg-quick down "$WG_IFACE" >/dev/null 2>&1 || ip link del "$WG_IFACE" 2>/dev/null || true
  fi
}

# ---- hub ----------------------------------------------------------------------

vpn_hub_setup() {
  require_root
  log "vpn: setting up the WireGuard hub (interface box)"
  wg_base
  net_gate "https://wireguard.com"

  mkdir -p "$WG_DIR"
  if [[ ! -f "$WG_HUB_CONF" ]]; then
    local kp priv
    kp="$(_wg_keypair)"
    priv="${kp%%$'\n'*}"
    cat > "$WG_HUB_CONF" <<EOF
[Interface]
PrivateKey = $priv
ListenPort = $WG_PORT
Address = ${WG_NET}.1/24

# peers are appended by 'vpn issue' - do not edit by hand
EOF
    chmod 600 "$WG_HUB_CONF"
  else
    warn "hub config exists - keeping it ($WG_HUB_CONF)"
  fi

  wg_ip_forward_on
  state_set role vpn
  state_set wg_hub_pubkey "$(_wg_hub_pubkey)"

  _wg_stale_clear
  _wg_up
  sleep 2
  wg show "$WG_IFACE" >/dev/null 2>&1 || die "wg hub failed - journalctl -u wg-quick@${WG_IFACE}"
  fw_allow udp "$WG_PORT"
  ok "vpn: hub up on udp/$WG_PORT ($(state_get wg_hub_pubkey))"
  ok "next: menu 3 -> issue a peer config for EVERY other box (hub + node1 + donors + frontend)"
}

vpn_issue() {
  require_root
  kcv_require_env
  local name="$1"
  if [[ -z "$name" ]] && kcv_tty; then
    read -r -p "peer name (NODE_NAME of the box): " name || die "input failed"
  fi
  [[ -n "$name" ]] || die "usage: korvarix-cluster.sh vpn issue <node-name>"
  [[ -f "$WG_HUB_CONF" ]] || die "no hub config - run vpn setup (interface box) first"

  local kp priv pub vpn_ip
  kp="$(_wg_keypair)"
  priv="${kp%%$'\n'*}"
  pub="${kp#*$'\n'}"
  vpn_ip="$(wg_next_ip)" || die "VPN pool exhausted"

  mkdir -p "$WG_DIR"
  printf '%s\n' "$priv" > "$WG_DIR/$name.private"
  chmod 600 "$WG_DIR/$name.private"

  # idempotent: replace any existing peer block for this name, then append
  _wg_peer_del "$name"
  cat >> "$WG_HUB_CONF" <<EOF
[Peer]
# $name
PublicKey = $pub
AllowedIPs = $vpn_ip/32
EOF
  _wg_sync

  # client config: every box receives this shape (joins as wg0)
  local out="${WG_DIR}/peers"
  mkdir -p "$out"
  {
    echo "[Interface]"
    echo "PrivateKey = $priv"
    echo "Address = $vpn_ip/32"
    echo ""
    echo "[Peer]"
    echo "PublicKey = $(_wg_hub_pubkey)"
    echo "Endpoint = $(state_get VPN_PUBLIC_IP):$WG_PORT"
    echo "AllowedIPs = ${WG_NET}/${WG_MASK}"
    echo "PersistentKeepalive = 25"
  } > "$out/$name.conf"
  chmod 600 "$out/$name.conf"
  state_set "vpn_ip_${vpn_ip##*.}" "$name"
  ok "issued $out/$name.conf -> static VPN IP $vpn_ip"
  ok "copy this file to $name and run: korvarix-cluster.sh vpn join /path/$name.conf"
}

vpn_join() {
  require_root
  kcv_require_env
  local conf_file="$1"
  if [[ -z "$conf_file" ]] && kcv_tty; then
    read -r -p "path to peer .conf file: " conf_file || die "input failed"
  fi
  [[ -n "$conf_file" && -f "$conf_file" ]] || die "peer config not found: $conf_file"
  log "vpn: joining the korvarix WireGuard network"
  wg_base
  if grep -q '^\[Peer\]' "$WG_CLI_CONF" 2>/dev/null; then
    warn "existing peer config - replacing"
  fi
  cp "$conf_file" "$WG_CLI_CONF"
  chmod 600 "$WG_CLI_CONF"
  _wg_stale_clear
  _wg_up
  sleep 2
  systemctl is-active --quiet "wg-quick@${WG_IFACE}" || die "wg-quick failed - journalctl -u wg-quick@${WG_IFACE}"
  local tun_ip
  tun_ip="$(ip -4 addr show "$WG_IFACE" 2>/dev/null | grep -oE '10\.8\.0\.[0-9]+' | head -1)"
  [[ -n "$tun_ip" ]] || die "$WG_IFACE has no 10.8.0.x address"
  state_set vpn_local_ip "$tun_ip"
  state_set vpn_expected 1
  ok "vpn: joined as $tun_ip"
}

vpn_list() {
  local dir="$WG_DIR/peers"
  if [[ ! -d "$dir" ]] || [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
    warn "no peers issued yet"
    return 0
  fi
  log "issued peers (static VPN IPs):"
  local f
  for f in "$dir"/*.conf; do
    [[ -f "$f" ]] || continue
    printf '  %-20s %s\n' "$(basename "$f" .conf)" "$(awk '/^Address/{print $3}' "$f")"
  done
}

# drop one peer from the hub config + tracking (box rebuilt/retired)
vpn_revoke() {
  require_root
  local name="$1"
  if [[ -z "$name" ]] && kcv_tty; then
    read -r -p "peer name to revoke: " name || die "input failed"
  fi
  [[ -n "$name" ]] || die "usage: korvarix-cluster.sh vpn revoke <node-name>"
  [[ -f "$WG_HUB_CONF" ]] || die "no hub config"
  grep -q "^# $name\$" "$WG_HUB_CONF" || die "peer '$name' not found in hub config"
  _wg_peer_del "$name"
  _wg_sync
  rm -f "$WG_DIR/peers/$name.conf" "$WG_DIR/$name.private"
  local ip
  for ip in $(seq 10 250); do
    [[ "$(state_get "vpn_ip_$ip")" == "$name" ]] && state_set "vpn_ip_$ip" ""
  done
  ok "revoked $name (peer removed, VPN IP freed)"
}

kcv_module_vpn() {
  local action="${1:-menu}"
  case "$action" in
    setup)  vpn_hub_setup ;;
    issue)  shift; vpn_issue "$@" ;;
    join)   shift; vpn_join "$@" ;;
    list)   vpn_list ;;
    revoke) shift; vpn_revoke "$@" ;;
    menu)
      if [[ "$(state_get role)" == "vpn" ]]; then
        echo "  1) issue peer config  2) list peers  3) revoke peer  0) back"
        local r; read -r -p "select: " r
        case "$r" in 1) vpn_issue "" ;; 2) vpn_list ;; 3) vpn_revoke "" ;; *) : ;; esac
      else
        echo "  1) join as peer (this box)  2) list peers (hub only)  0) back"
        local r; read -r -p "select: " r
        case "$r" in 1) vpn_join "" ;; 2) vpn_list ;; *) : ;; esac
      fi
      ;;
    *) die "usage: vpn setup|issue <name>|join <file>|revoke <name>|list" ;;
  esac
}