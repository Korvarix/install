#!/usr/bin/env bash
# module: report
# Nightly LLM usage summary from the frontend gate's JSONL log
# (/var/log/korvarix/llm-usage.jsonl on the frontend box) -> HEALTH_WEBHOOK.
# Pure observation: unlimited stays unlimited - this only surfaces who is
# using what, which models carry the load, and refusals. Menu entrypoint:
# kcv_module_report

REPORT_LOG="${KCV_LOG_DIR}/usage-report.log"

# fetch the usage JSONL from the frontend box over the VPN (rsync over ssh)
report_fetch() {
  kcv_require_env
  local host="${FRONTEND_VPN_IP:-${POLICY_PUSH_HOST:-}}"
  [[ -n "$host" ]] || die "FRONTEND_VPN_IP empty in $KCV_ENV_FILE (run this on the frontend box, or set FRONTEND_VPN_IP)"
  command -v rsync >/dev/null 2>&1 || pkg_install rsync
  mkdir -p "$KCV_LOG_DIR"
  rsync -a "root@${host}:/var/log/korvarix/llm-usage.jsonl*" "$KCV_LOG_DIR/" || die "rsync usage log from $host failed"
  ok "usage log fetched from $host -> $KCV_LOG_DIR/"
}

# aggregate one day: per-user tokens, per-model tokens, refusals, top caller
report_build() {
  local src="${1:-$KCV_LOG_DIR/llm-usage.jsonl}"
  [[ -f "$src" ]] || { warn "no usage log at $src"; return 1; }
  local yday
  yday="$(date -d 'yesterday' +%Y-%m-%dT 2>/dev/null || date -v-1d +%Y-%m-%dT 2>/dev/null)"
  # yesterday's lines only (ts starts with the date); usage+refusal kinds both count
  grep "^{\"ts\":\"$yday" "$src" 2>/dev/null > /tmp/kcv-usage-yday || true
  if [[ ! -s /tmp/kcv-usage-yday ]]; then
    echo "no usage recorded for $yday"
    return 0
  fi
  # POSIX-safe aggregation: sed-extract fields, then tally with awk
  local f=/tmp/kcv-usage-yday
  grep '"kind":"completion"' "$f" | sed -n 's/.*"subject":"\([^"]*\)".*"model":"\([^"]*\)".*"pt":\([0-9]*\).*"ct":\([0-9]*\).*/\1|\2|\3|\4/p' > /tmp/kcv-rows 2>/dev/null || : > /tmp/kcv-rows
  awk -F'|' '
    { up[$1] += $3; uc[$1] += $4; call[$1]++
      mp[$2] += $3; mc[$2] += $4; mcall[$2]++
      Tpt += $3; Tct += $4
    }
    END {
      for (u in up) printf "user|%s|%d|%d|%d\n", u, up[u], uc[u], call[u]
      for (m in mp) printf "model|%s|%d|%d|%d\n", m, mp[m], mc[m], mcall[m]
      printf "TOTAL|completion_calls|%d\n", NR
      printf "TOTAL|prompt_tokens|%d\n", Tpt
      printf "TOTAL|completion_tokens|%d\n", Tct
    }
  ' /tmp/kcv-rows
  printf 'TOTAL|refusals|%s\n' "$(grep -c '"kind":"refused"' "$f" 2>/dev/null || echo 0)"
  rm -f /tmp/kcv-rows /tmp/kcv-usage-yday
}

# human summary (Discord-friendly); posts to HEALTH_WEBHOOK when set
report_run() {
  kcv_require_env
  local yday
  yday="$(date -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null)"
  local agg
  agg="$(report_build "${1:-}")" || return 1
  local users total_calls tot_pt tot_ct refusals top
  users="$(grep '^user|' <<<"$agg" | wc -l)"
  total_calls="$(grep '^TOTAL|completion_calls|' <<<"$agg" | cut -d'|' -f3)"
  tot_pt="$(grep '^TOTAL|prompt_tokens|' <<<"$agg" | cut -d'|' -f3)"
  tot_ct="$(grep '^TOTAL|completion_tokens|' <<<"$agg" | cut -d'|' -f3)"
  refusals="$(grep '^TOTAL|refusals|' <<<"$agg" | cut -d'|' -f3)"
  top="$(grep '^user|' <<<"$agg" | sort -t'|' -k4 -rn | head -1 | cut -d'|' -f2,5)"
  echo "== korvarix LLM usage $yday =="
  echo " calls: ${total_calls:-0}   prompt tokens: ${tot_pt:-0}   completion tokens: ${tot_ct:-0}   refusals: ${refusals:-0}"
  echo " active users: ${users:-0}   top: ${top:-none}"
  echo " per-user:"
  grep '^user|' <<<"$agg" | sort -t'|' -k4 -rn | awk -F'|' '{printf "  %-32s out:%12d in:%12d calls:%d\n", $2, $4, $3, $5}'
  echo " per-model:"
  grep '^model|' <<<"$agg" | sort -t'|' -k4 -rn | head -10 | awk -F'|' '{printf "  %-32s out:%12d in:%12d calls:%d\n", $2, $4, $3, $5}'
  if [[ -n "${HEALTH_WEBHOOK:-}" ]]; then
    local payload
    payload="{\"content\": \"korvarix LLM usage $yday: ${total_calls:-0} calls, ${tot_ct:-0} completion tokens, ${users:-0} active users, ${refusals:-0} refusals (top: ${top:-none})\"}"
    curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$payload" "$HEALTH_WEBHOOK" >/dev/null 2>&1 \
      && ok "report posted to HEALTH_WEBHOOK" || warn "webhook post failed"
  fi
}

report_cron_install() {
  require_root
  local station
  station="$(state_get station_path)"
  [[ -n "$station" ]] || die "station path unknown"
  cron_install "usage-report" "43 5 * * *" "root $station report daily >> $REPORT_LOG 2>&1"
}

kcv_module_report() {
  local action="${1:-menu}"
  case "$action" in
    fetch)  report_fetch ;;
    daily)  report_run ;;
    cron)   report_cron_install ;;
    menu)
      echo "  1) fetch usage log (rsync from frontend)  2) build+post report now  3) install nightly cron  0) back"
      local r; read -r -p "select: " r
      case "$r" in
        1) report_fetch ;;
        2) report_run "" ;;
        3) report_cron_install ;;
        *) : ;;
      esac
      ;;
    *) die "usage: report fetch|daily|cron" ;;
  esac
}