#!/usr/bin/env bash
# module: health
# Non-interactive health check for cron + menu 2. Flip-detection: reports only
# state CHANGES (ok<->fail) so cron stays silent unless something changes.
# Optional HEALTH_WEBHOOK receives every flip as JSON.

HEALTH_STATE="${KCV_LIB_DIR}/health.state"
HEARTBEAT_S="${HEARTBEAT_S:-3600}"

h_get() { grep "^$1=" "$HEALTH_STATE" 2>/dev/null | tail -1 | cut -d= -f2-; }
h_set() {
  grep -v "^$1=" "$HEALTH_STATE" 2>/dev/null > "${HEALTH_STATE}.t" || true
  printf '%s=%s\n' "$1" "$2" >> "${HEALTH_STATE}.t"
  mv "${HEALTH_STATE}.t" "$HEALTH_STATE"
}

h_alert() {
  local key="$1" status="$2" msg="${3:-}"
  local prev now epoch text
  epoch="$(date +%s)"
  now="fail"; [[ "$status" == "ok" ]] && now="ok"
  prev="$(h_get "$key")"
  [[ "$prev" == "$now" ]] && { h_set "${key}_ts" "$epoch"; return 0; }
  h_set "$key" "$now"
  h_set "${key}_ts" "$epoch"
  text="[${now}] korvarix ${key} on $(hostname): ${msg:-state changed}"
  printf '%s\n' "$text"
  if [[ -n "${HEALTH_WEBHOOK:-}" ]]; then
    curl -fsS --max-time 10 -H 'Content-Type: application/json' \
      -d "{\"content\": \"${text//\"/\\\"}\"}" "$HEALTH_WEBHOOK" >/dev/null 2>&1 || true
  fi
}

check_port() { curl -fsS --max-time 5 -o /dev/null "$1" 2>/dev/null; }
check_tcp() { timeout 5 bash -c "</dev/tcp/$1/$2" 2>/dev/null; }

# ping every RPC peer (merged-RAM donors) - a down peer silently drops its
# layers, so this catches the "model loads at 1/N capacity" class proactively
health_rpc_peers() {
  local entries entry ip pt
  [[ -n "${RPC_PEERS:-}" ]] || return 0
  IFS=',' read -ra entries <<<"$RPC_PEERS"
  for entry in "${entries[@]}"; do
    ip="${entry%%:*}"; pt="${entry##*:}"
    if check_tcp "$ip" "$pt"; then
      h_alert "rpc_peer_$ip" ok
    else
      h_alert "rpc_peer_$ip" fail "peer $entry not answering (layers lost - rpc-server down on that node?)"
      failures=$((failures+1))
    fi
  done
}

health_run() {
  kcv_init
  mkdir -p "$(dirname "$HEALTH_STATE")"
  local failures=0

  # ---- vpn (wireguard) ----
  if systemctl is-active --quiet "wg-quick@wg0" 2>/dev/null; then
    if ip -4 addr show wg0 2>/dev/null | grep -q '10\.8\.0\.'; then
      h_alert vpn ok "tunnel up"
    else
      h_alert vpn fail "wg-quick active but wg0 has no 10.8.0.x"
      failures=$((failures+1))
    fi
  elif ip link show wg0 >/dev/null 2>&1; then
    # hub role: interface up even if wg-quick unit shows inactive
    h_alert vpn ok "hub interface up"
  elif [[ "$(state_get vpn_expected)" == "1" ]]; then
    h_alert vpn fail "no wireguard service active"
    failures=$((failures+1))
  fi

  # ---- master reachability (donor + frontend roles) ----
  if [[ -n "${MASTER_VPN_IP:-}" ]]; then
    if ping -c1 -W5 "$MASTER_VPN_IP" >/dev/null 2>&1; then
      h_alert master ok
    else
      h_alert master fail "master $MASTER_VPN_IP unreachable (tunnel up but master down?)"
      failures=$((failures+1))
    fi
  fi

  # ---- llama / rpc / peers ----
  if systemctl list-unit-files 2>/dev/null | grep -q korvarix-llama-server; then
    if systemctl is-active --quiet korvarix-llama-server; then
      if check_port "http://127.0.0.1:${LLAMA_PORT:-8080}/health"; then
        h_alert llama ok
      else
        h_alert llama fail "service up but port ${LLAMA_PORT:-8080} not answering"
        failures=$((failures+1))
      fi
      health_rpc_peers
    else
      h_alert llama fail "service down"
      failures=$((failures+1))
    fi
  fi
  if systemctl list-unit-files 2>/dev/null | grep -q korvarix-rpc-server; then
    if systemctl is-active --quiet korvarix-rpc-server; then
      h_alert rpc ok
    else
      h_alert rpc fail "rpc-server down"
      failures=$((failures+1))
    fi
  fi

  # ---- ollama (when installed) ----
  if systemctl list-unit-files 2>/dev/null | grep -q korvarix-ollama; then
    if systemctl is-active --quiet korvarix-ollama; then
      h_alert ollama ok
    else
      h_alert ollama fail "ollama service down"
      failures=$((failures+1))
    fi
  fi

  # ---- disk / mem ----
  local diskpct mempct
  diskpct="$(df -P "${MODELS_DIR:-/}" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
  [[ -n "$diskpct" ]] || diskpct="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
  mempct="$(free | awk '/Mem:/{printf "%d", $3/$2*100}')"
  if [[ "${diskpct:-0}" -ge "${DISK_ALERT_PCT:-85}" ]]; then
    h_alert disk fail "disk ${diskpct}% used (threshold ${DISK_ALERT_PCT:-85}%)"
    failures=$((failures+1))
  else
    h_alert disk ok "${diskpct}% used"
  fi
  if [[ "${mempct:-0}" -ge "${MEM_ALERT_PCT:-90}" ]]; then
    h_alert mem fail "mem ${mempct}% used (threshold ${MEM_ALERT_PCT:-90}%)"
    failures=$((failures+1))
  else
    h_alert mem ok "${mempct}% used"
  fi

  # ---- heartbeat (proves cron is alive even when all is well) ----
  local lasthb epoch
  lasthb="$(h_get hb_ts)"
  epoch="$(date +%s)"
  if [[ -z "$lasthb" || $((epoch - lasthb)) -ge "$HEARTBEAT_S" ]]; then
    h_set hb_ts "$epoch"
    log "health: heartbeat (active failures: $failures)"
  fi
  return "$failures"
}

kcv_module_health() {
  health_run
}