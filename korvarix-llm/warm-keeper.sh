#!/usr/bin/env bash
# korvarix warm-keeper - hourly self-heal for the LLM worker pool.
#
# For every korvarix-ollama@<port> instance on THIS node:
#   1. daemon up?      (curl /api/version; start the unit if not)
#   2. model loaded?   (curl /api/ps, exact-name match)
#   3. not loaded  ->  warmup request (keep_alive=-1 pins it forever)
# Everything is logged to /var/log/korvarix/warm-keeper.log.
#
# Install (as root, on a worker):
#   install -m 755 warm-keeper.sh /usr/local/sbin/korvarix-warm-keeper.sh
#   mkdir -p /var/log/korvarix
#   printf '%s\n' '17 * * * * root /usr/local/sbin/korvarix-warm-keeper.sh >/dev/null 2>&1' \
#     > /etc/cron.d/korvarix-warm
# (the script writes its own log file - do NOT also redirect stdout to the
#  same file in the cron line, that double-logs every entry)
#
# Flags (optional - defaults fit the current fleet):
#   --model NAME      model to keep warm        (default: oroboros-labs/claude-fable5:latest)
#   --ports LIST      instances to watch, space-separated (default: "11430 11431 11432 11433")
#   --once            run one pass and exit     (the cron entry runs it this way hourly)
#   --watch           loop forever, checking every --interval minutes
#   --interval N      minutes between passes in --watch mode (default: 60)
#
# Design notes:
#   - dials the node's VPN IP, NOT 127.0.0.1: the daemons bind the wg0 address
#     only, so loopback probes would always fail and loop the keeper.
#   - flock: a slow NFS warm (>1h) must never overlap the next cron pass.
#   - exact model name match (grep -F "\"name\"") so claude-fable5u never
#     counts as claude-fable5.
#   - POSIX-sh compatible (no arrays): validates with `sh -n`, runs under
#     bash/dash/ash alike.
set -u

MODEL="oroboros-labs/claude-fable5:latest"
PORTS="11430 11431 11432 11433"
LOG_DIR="/var/log/korvarix"
LOG="$LOG_DIR/warm-keeper.log"
INTERVAL=60
ONCE=1
WATCH=0

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
# log() writes to the log FILE and mirrors to stdout (cron redirects stdout to
# the same file via >>, so entries appear exactly once there; manual runs show
# the pass live on the console as well)
log() { printf '%s\n' "$(date -Is) $*" | tee -a "$LOG"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --model)    MODEL="$2"; shift 2 ;;
    --ports)    PORTS="$2"; shift 2 ;;
    --once)     ONCE=1; WATCH=0; shift ;;
    --watch)    WATCH=1; ONCE=0; shift ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    *) die "unknown flag: $1 (see header comments)" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"

# --- the node's VPN IP (daemons bind it; loopback never reaches them) ----------
IP="$(ip -4 -o addr show wg0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep '^10\.8\.' | head -1 || true)"
[ -n "$IP" ] || die "no 10.8.0.* VPN IP on wg0 - is the tunnel up?"
mkdir -p "$LOG_DIR"
touch "$LOG"

# --- single-instance guard: a slow NFS warm must not overlap the next pass -----
exec 9>/run/korvarix-warm.lock
if ! flock -n 9; then
  log "previous warm-keeper pass still running - skipping"
  exit 0
fi

# loaded_count <port> -> prints how many entries match the exact model name
loaded_count() {
  curl -m 5 -s "http://$IP:$1/api/ps" | grep -cF "\"$MODEL\"" || true
}

warm_one() {
  p="$1"
  # daemon alive?
  if ! curl -m 5 -s "http://$IP:$p/api/version" | grep -q version; then
    log "$p daemon down - systemctl start korvarix-ollama@$p"
    systemctl start "korvarix-ollama@$p" || { log "$p start FAILED"; return 1; }
    sleep 5
  fi
  if [ "$(loaded_count "$p")" -gt 0 ]; then
    log "$p warm (no action)"
    return 0
  fi
  log "$p COLD - warming $MODEL"
  curl -s -m 900 "http://$IP:$p/api/generate" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"\",\"keep_alive\":-1}" >/dev/null
  if [ "$(loaded_count "$p")" -gt 0 ]; then
    log "$p warmed OK"
    return 0
  fi
  log "$p warmup FAILED (still cold) - check journalctl -u korvarix-ollama@$p"
  return 1
}

# --- one pass over every port ---------------------------------------------------
pass() {
  rc=0
  for p in $PORTS; do
    warm_one "$p" || rc=1
  done
  return $rc
}

if [ "$ONCE" -eq 1 ]; then
  pass
  exit $?
fi

# --- watch mode ------------------------------------------------------------------
log "warm-keeper watching [$PORTS] every ${INTERVAL}m (model: $MODEL)"
while true; do
  pass || true
  sleep "$((INTERVAL * 60))"
done