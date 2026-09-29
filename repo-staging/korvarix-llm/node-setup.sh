#!/usr/bin/env bash
# korvarix LLM slave node setup - converts a node to N single-slot Ollama
# instances (1 request each, concurrency comes from the instance count).
#
# What it does (idempotent - safe to re-run):
#   1. stops/disables the OLD single-daemon korvarix-ollama.service (if present)
#   2. frees the target ports (kills orphan ollama squatters)
#   3. writes the template unit korvarix-ollama@.service (sandboxed, hardened)
#   4. enables + starts korvarix-ollama@<port> for every port in the range
#   5. verifies each instance answers /api/version
#   6. prints the exact OLLAMA_NODES line to add on the frontend
#
# Usage (root, on an LLM node):
#   ./node-setup.sh                              # autodetect 10.8.0.x IP, 8 instances
#   ./node-setup.sh --ip 10.8.0.15 --instances 8 --retire-legacy
#   ./node-setup.sh --restart                    # restart all instances (clears running tasks)
#
# Flags:
#   --ip IP          VPN IP to bind instances to        (default: autodetect 10.8.0.*)
#   --instances N    number of Ollama instances         (default: 8)
#   --base-port P    first port, ports are consecutive  (default: 11430)
#   --num-parallel N OLLAMA_NUM_PARALLEL per instance   (default: 1)
#   --keep-alive S   OLLAMA_KEEP_ALIVE                  (default: -1 = never unload)
#   --ctx N          OLLAMA_CONTEXT_LENGTH (KV cap)     (default: 16384)
#   --warm-cron      install the hourly warm-keeper self-heal cron (warm-keeper.sh)
#   --warm-model N   model the warm-keeper pins         (default: oroboros-labs/claude-fable5:latest)
#   --warm-ports "L" ports the warm-keeper watches     (default: derived from
#                    --instances/--base-port; use this in maint-only mode to
#                    match an EXISTING fleet, e.g. --warm-ports "11430 11431 11432 11433")
#   --retire-legacy  also disable --now korvarix-llama-server (the 64-thread RPC llama-server)
#   --firewall       open the port range for the VPN subnet via ufw (only if ufw exists)
#   --restart        just restart the existing instances (config unchanged)
#   --dry-run        print the actions without executing
set -euo pipefail

# VERSION: bump on every script change; print it early so a stale upload is
# visible in one glance (the stale-upload problem has bitten repeatedly).
NODE_SETUP_VERSION="2026-09-28.8"
# folder this script lives in (warm-keeper.sh must sit next to it)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# warm-keeper.sh must sit next to this script; if it's missing the upload was
# partial even for runs that don't need it (warn, don't die - --restart etc.
# legitimately run on minimal installs)
REPO_SELF_CHECK() {
  if [[ ! -f "$HERE/warm-keeper.sh" ]]; then
    printf '\033[1;33mwarn:\033[0m warm-keeper.sh not found in %s - the upload is PARTIAL or STALE\n' "$HERE"
    printf '      (--warm-cron will fail; re-upload the full korvarix-llm folder)\n'
  fi
}

SVC_BASE="korvarix-ollama"
DEF_HOME="/var/lib/korvarix-cluster/ollama"
BIND_IP=""
INSTANCES=8
INSTANCES_SET=0   # 1 = --instances given (topology intent)
BASE_PORT=11430
BASE_PORT_SET=0
NUM_PARALLEL=1
KEEP_ALIVE="-1"
CTX=16384
WARM_CRON=0
WARM_MODEL="oroboros-labs/claude-fable5:latest"
WARM_PORTS=""   # empty = derive from INSTANCES/BASE_PORT
RETIRE_LEGACY=0
FIREWALL=0
RESTART_ONLY=0
DRY_RUN=0

die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*"; }
run()  { if ((DRY_RUN)); then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

[[ $(id -u) -eq 0 ]] || die "run as root"

while (($#)); do
  case "$1" in
    --ip)           BIND_IP="$2"; shift 2 ;;
    --instances)    INSTANCES="$2"; INSTANCES_SET=1; shift 2 ;;
    --base-port)    BASE_PORT="$2"; BASE_PORT_SET=1; shift 2 ;;
    --num-parallel) NUM_PARALLEL="$2"; shift 2 ;;
    --keep-alive)   KEEP_ALIVE="$2"; shift 2 ;;
    --ctx)          CTX="$2"; shift 2 ;;
    --warm-cron)    WARM_CRON=1; shift ;;
    --warm-model)   WARM_MODEL="$2"; shift 2 ;;
    --warm-ports)   WARM_PORTS="$2"; shift 2 ;;
    --retire-legacy) RETIRE_LEGACY=1; shift ;;
    --firewall)     FIREWALL=1; shift ;;
    --restart)      RESTART_ONLY=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    *) die "unknown flag: $1 (see header comments)" ;;
  esac
done

ports=()
for ((i = 0; i < INSTANCES; i++)); do ports+=("$((BASE_PORT + i))"); done

log "node-setup v$NODE_SETUP_VERSION"
REPO_SELF_CHECK

# --- autodetect the VPN IP (10.8.0.*) unless given ---------------------------
if [[ -z "$BIND_IP" ]]; then
  BIND_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep '^10\.8\.' | head -1 || true)"
  [[ -n "$BIND_IP" ]] || die "could not autodetect a 10.8.0.* VPN IP - pass --ip"
fi

# --- live-fleet detection: trust what's INSTALLED over the default ------------
# The user-facing complaint: "instances=8" in the banner when only 4 exist.
# Root cause: INSTANCES/BASE_PORT are script defaults, not fleet state. The
# authoritative source is systemd - the korvarix-ollama@<port> units that are
# enabled/running on THIS box. Detection runs before the banner; a full
# topology run (with explicit --instances) overrides it.
detect_live_ports() {
  systemctl list-units --no-legend --plain 'korvarix-ollama@*' 2>/dev/null \
    | grep -oP 'korvarix-ollama@\K[0-9]+(?=\.service)' | sort -n | tr '\n' ' ' | sed 's/ $//'
}

LIVE_PORTS="$(detect_live_ports)"
# without --instances the script aligns its port list with the live fleet;
# --instances (topology intent) keeps the requested count for full setup runs
if (( !INSTANCES_SET )) && [[ -n "$LIVE_PORTS" ]]; then
  ports=($LIVE_PORTS)
  INSTANCES=${#ports[@]}
  BASE_PORT="${ports[0]}"
  log "detected running instances: $LIVE_PORTS (aligning to the live fleet)"
fi

log "node config: ip=$BIND_IP instances=${#ports[@]} ports=${ports[0]}-${ports[-1]} num_parallel=$NUM_PARALLEL warm_targets=${WARM_PORTS:-${ports[*]}}"

# --- restart-only shortcut ---------------------------------------------------
if ((RESTART_ONLY)); then
  for p in "${ports[@]}"; do
    systemctl status "korvarix-ollama@$p" >/dev/null 2>&1 || die "korvarix-ollama@$p not installed - run without --restart first"
    run systemctl restart "korvarix-ollama@$p"
  done
  log "restarted ${#ports[@]} instances (all in-flight tasks cleared)"
  exit 0
fi

# --- maint-only detection: --warm-cron without ANY topology intent -----------
# topology intent = --instances/--base-port given, or non-default overrides
MAINT_ONLY=0
if ((WARM_CRON)) && (( !INSTANCES_SET )) && (( !BASE_PORT_SET )) \
   && [[ "$KEEP_ALIVE" == "-1" ]] && [[ "$CTX" == "16384" ]] \
   && [[ "$NUM_PARALLEL" == 1 ]] && (( !RETIRE_LEGACY )) && (( !FIREWALL )); then
  # only --warm-cron (+ its own knobs) was given: defaults untouched
  MAINT_ONLY=1
  log "maint-only mode: --warm-cron without topology flags - installing cron ONLY (instances/template untouched)"
fi

HOME_DIR="${OLLAMA_HOME:-$DEF_HOME}"

# full topology pipeline as a FUNCTION: no giant if-wrap, maint-only simply
# never calls it (the failure mode this guards against: `--warm-cron` alone
# resurrecting disabled instances / rewriting the template)
topology_pipeline() {

# --- 1. old single-daemon unit -----------------------------------------------
if [[ -f /etc/systemd/system/korvarix-ollama.service ]]; then
  log "old single-daemon unit found - stopping, disabling, archiving"
  run systemctl disable --now korvarix-ollama || true
  run mv /etc/systemd/system/korvarix-ollama.service /etc/systemd/system/korvarix-ollama.service.archived
  run systemctl daemon-reload
fi

# --- 2. free the ports -------------------------------------------------------
for p in "${ports[@]}"; do
  pid="$(ss -tlnpH "sport = :$p" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -1 || true)"
  if [[ -n "$pid" ]]; then
    if grep -qs "korvarix-ollama@$p" "/proc/$pid/cgroup" 2>/dev/null; then
      log "port $p already served by korvarix-ollama@$p - leaving it"
    else
      warn "port $p held by pid $pid ($(cat /proc/$pid/comm 2>/dev/null)) - killing it"
      run kill "$pid" || true
      sleep 1
    fi
  fi
done

# --- 3. template unit ---------------------------------------------------------
UNIT=/etc/systemd/system/korvarix-ollama@.service
log "writing $UNIT (%i = port)"
if ((DRY_RUN)); then
  log "[dry-run] would write the template unit (see heredoc below in source)"
else
cat > "$UNIT" <<EOF
[Unit]
Description=korvarix sandboxed Ollama (port %i, 1 request / ${NUM_PARALLEL} parallel)
After=network.target

[Service]
Type=simple
User=korvarix-ollama
Group=korvarix-ollama
ExecStart=$HOME_DIR/bin/ollama serve
Environment=OLLAMA_HOST=$BIND_IP:%i
Environment=OLLAMA_MODELS=$HOME_DIR/models
Environment=HOME=$HOME_DIR
Environment=OLLAMA_NUM_PARALLEL=$NUM_PARALLEL
Environment=OLLAMA_MAX_LOADED_MODELS=1
# -1 = models never unload (an idle instance must not trigger a 20GB NFS reload)
Environment=OLLAMA_KEEP_ALIVE=$KEEP_ALIVE
# KV-cache cap: bounds prompt-eval time + RAM per runner (131k default was fatal)
Environment=OLLAMA_CONTEXT_LENGTH=$CTX
# read-only models mount: boot-time prune would fail + crash-loop the daemon
Environment=OLLAMA_NOPRUNE=true
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=$HOME_DIR/models $HOME_DIR
LimitMEMLOCK=64M
LimitNOFILE=65536
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemd-analyze verify "$UNIT" || die "unit verification failed - inspect $UNIT"
fi

run systemctl daemon-reload

# --- 4. enable + start the instances -----------------------------------------
for p in "${ports[@]}"; do
  run systemctl enable "korvarix-ollama@$p" >/dev/null
  run systemctl restart "korvarix-ollama@$p"
done

# --- 5. verify ----------------------------------------------------------------
log "waiting for instances to bind..."
sleep 3
failed=()
for p in "${ports[@]}"; do
  ok=""
  for _ in 1 2 3 4 5; do
    if curl -m 2 -s "http://$BIND_IP:$p/api/version" | grep -q version; then ok=1; break; fi
    sleep 2
  done
  if [[ -n "$ok" ]]; then log "  $p ok"; else failed+=("$p"); warn "  $p NOT responding (journalctl -u korvarix-ollama@$p -n 20)"; fi
done
((${#failed[@]} == 0)) || die "instances failed: ${failed[*]}"

# --- optional: firewall --------------------------------------------------------
if ((FIREWALL)); then
  if command -v ufw >/dev/null 2>&1; then
    run ufw allow from 10.8.0.0/24 to any port "${ports[0]}:${ports[-1]}" proto tcp
  else
    warn "--firewall requested but ufw is not installed - open the ports manually"
  fi
fi

# --- optional: retire the legacy 64-thread llama-server ------------------------
if ((RETIRE_LEGACY)); then
  if systemctl list-unit-files korvarix-llama-server.service >/dev/null 2>&1; then
    log "retiring legacy korvarix-llama-server (n_threads=64 RPC server)"
    run systemctl disable --now korvarix-llama-server || true
    warn "if OTHER nodes host its --rpc peer, retire that unit there too"
  else
    log "no legacy korvarix-llama-server unit found - nothing to retire"
  fi
fi

}

# --- maint-only path: install the cron, exit; topology is never touched --------
if ((MAINT_ONLY)); then
  [[ -f "$HERE/warm-keeper.sh" ]] || die "--warm-cron needs warm-keeper.sh in $HERE (upload the full repo folder)"
  [[ -x "$HOME_DIR/bin/ollama" ]] || die "ollama binary not found at $HOME_DIR/bin/ollama (is the korvarix-cluster layout present?)"
  WARM_CRON_INSTALL=1
else
  [[ -x "$HOME_DIR/bin/ollama" ]] || die "ollama binary not found at $HOME_DIR/bin/ollama (is the korvarix-cluster layout present?)"
  id korvarix-ollama >/dev/null 2>&1 || die "user 'korvarix-ollama' does not exist - create it first (cluster installer normally does)"
  topology_pipeline
  WARM_CRON_INSTALL=$((WARM_CRON))
fi

# --- optional: hourly warm-keeper self-heal cron (BOTH paths) -------------------
# requires warm-keeper.sh next to this script (uploaded with the repo folder).
# maint-only mode: installs the cron ONLY (topology untouched, exits below).
# full topology runs: installs it as part of the pipeline.
# Ports: --warm-ports wins; otherwise derived from --instances/--base-port.
KEEPER_PORTS="$WARM_PORTS"
if [[ -z "$KEEPER_PORTS" ]]; then
  KEEPER_PORTS="${ports[*]}"
fi
if ((WARM_CRON_INSTALL)); then
  [[ -f "$HERE/warm-keeper.sh" ]] || die "--warm-cron needs warm-keeper.sh in $HERE (upload the full repo folder)"
  log "installing warm-keeper (hourly cron, model: $WARM_MODEL, ports: $KEEPER_PORTS)"
  run install -m 755 "$HERE/warm-keeper.sh" /usr/local/sbin/korvarix-warm-keeper.sh
  run mkdir -p /var/log/korvarix
  if ((DRY_RUN)); then
    log "[dry-run] would write /etc/cron.d/korvarix-warm (hourly, ports $KEEPER_PORTS)"
  else
    cat > /etc/cron.d/korvarix-warm <<EOF
# korvarix warm-keeper: reload any instance whose model went cold (hourly)
# (the script writes /var/log/korvarix/warm-keeper.log itself; stdout is dropped)
17 * * * * root /usr/local/sbin/korvarix-warm-keeper.sh --model "$WARM_MODEL" --ports "$KEEPER_PORTS" >/dev/null 2>&1
EOF
    chmod 644 /etc/cron.d/korvarix-warm
  fi
  log "warm-keeper installed - first pass will run at minute 17 of the next hour (or run it now: /usr/local/sbin/korvarix-warm-keeper.sh --model \"$WARM_MODEL\" --ports \"$KEEPER_PORTS\")"
fi

# --- maint-only path ends here (no frontend registration needed) ---------------
if ((MAINT_ONLY)); then
  log "maint-only run complete - instance topology untouched"
  exit 0
fi

# --- 6. what to add on the frontend (full topology runs only) -------------------
nodes_list=""
for p in "${ports[@]}"; do nodes_list+="${nodes_list:+,}http://$BIND_IP:$p"; done
log "node is ready. On the FRONTEND box run:"
printf '  ./add-node.sh %s --apply\n' "$BIND_IP"
printf '  (adds: %s)\n' "$nodes_list"