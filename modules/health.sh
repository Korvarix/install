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

health_run() {
  kcv_init
  mkdir -p "$(dirname "$HEALTH_STATE")"
  local failures=0

  # ---- vpn ----
  if systemctl is-active --quiet "openvpn-client@korvarix" 2>/dev/null; then
    if ip -4 addr show tun0 2>/dev/null | grep -q '10\.8\.0\.'; then
      h_alert vpn ok "tunnel up"
    else
      h_alert vpn fail "openvpn active but tun0 has no 10.8.0.x"
      failures=$((failures+1))
    fi
  elif systemctl is-active --quiet korvarix-vpn-server 2>/dev/null; then
    h_alert vpn ok "hub running"
  elif [[ "$(state_get vpn_expected)" == "1" ]]; then
    h_alert vpn fail "no openvpn service active"
    failures=$((failures+1))
  fi

  # ---- gluster ----
  if command -v gluster >/dev/null 2>&1 && gluster volume info "${GLUSTER_VOLUME:-gv0}" >/dev/null 2>&1; then
    local total online
    total="$(gluster volume status "${GLUSTER_VOLUME:-gv0}" 2>/dev/null | grep -c ' Y ' || echo 0)"
    online="$(gluster volume status "${GLUSTER_VOLUME:-gv0}" 2>/dev/null | awk '/ Y /{n++} END{print n+0}')"
    if [[ "$online" -lt "$total" ]]; then
      h_alert gluster fail "bricks degraded: $online/$total online"
      failures=$((failures+1))
    else
      h_alert gluster ok "bricks: $online/$total"
    fi
    if mountpoint -q "${GLUSTER_MOUNT:-/mnt/gv0}"; then
      h_alert gluster-mount ok
    else
      h_alert gluster-mount fail "${GLUSTER_MOUNT:-/mnt/gv0} not mounted"
      failures=$((failures+1))
    fi
  fi

  # ---- k3s ----
  if command -v k3s >/dev/null 2>&1; then
    local notready
    notready="$(k3s kubectl get nodes --no-headers 2>/dev/null | grep -cv ',Ready' || echo 0)"
    if [[ "$notready" -gt 0 ]]; then
      h_alert k3s fail "$notready node(s) not Ready"
      failures=$((failures+1))
    else
      h_alert k3s ok
    fi
  fi

  # ---- llama / rpc ----
  if systemctl list-unit-files 2>/dev/null | grep -q korvarix-llama-server; then
    if systemctl is-active --quiet korvarix-llama-server; then
      if check_port "http://127.0.0.1:${LLAMA_PORT:-8080}/health"; then
        h_alert llama ok
      else
        h_alert llama fail "service up but port ${LLAMA_PORT:-8080} not answering"
        failures=$((failures+1))
      fi
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

  # ---- disk / mem ----
  local diskpct mempct
  diskpct="$(df -P "${GLUSTER_MOUNT:-/}" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
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