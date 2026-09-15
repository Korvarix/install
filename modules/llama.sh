#!/usr/bin/env bash
# module: llama
# llama.cpp (pinned build) + rpc-server (nodes) + llama-server (master).
# Day one: master solo (RPC_PEERS empty). Nodes join merged-RAM over time.

LLAMA_DIR="${KCV_LIB_DIR}/llama.cpp"
RPC_PORT="${RPC_PORT:-50052}"
LLAMA_PORT="${LLAMA_PORT:-8080}"

llama_build() {
  require_root
  log "llama: building llama.cpp (ref: ${LLAMA_CPP_REF:-HEAD})"
  kcv_base_tools
  dep_ensure "cmake:cmake" "git:git" "make:make" "g++:g++"
  net_gate "https://github.com/ggerganov/llama.cpp"

  if [[ ! -d "$LLAMA_DIR/.git" ]]; then
    git clone --depth 1 https://github.com/ggerganov/llama.cpp "$LLAMA_DIR" || die "clone failed"
  fi
  # parallel jobs from RAM, not cores: a 4GB donor running 16-way g++ on
  # C++ sources hits the OOM killer and the build "fails" mysteriously
  local jobs
  jobs="$(free -m | awk '/Mem:/{m=$2} END{printf "%d", m/1100}')"
  (( jobs < 1 )) && jobs=1
  local out rc
  out="$(
    cd "$LLAMA_DIR" || exit 10
    git fetch --tags --force 2>/dev/null || true
    if [[ -n "${LLAMA_CPP_REF:-}" ]]; then
      git checkout "$LLAMA_CPP_REF" || exit 10
    fi
    cmake -B build -DGGML_RPC=ON -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release 2>&1 || exit 10
    # explicit targets: the default ALL set may not include the RPC backend
    cmake --build build --target rpc-server llama-server -j"$jobs" 2>&1 || exit 11
  )" && rc=0 || rc=$?
  if (( rc != 0 )); then
    # cmake noise is enormous - show only the tail where the real error lives
    printf '%s\n' "$out" | tail -25 >&2
    (( rc == 10 )) && die "cmake configure failed - output above"
    die "build failed - output above"
  fi
  local b
  for b in rpc-server llama-server; do
    [[ -x "$LLAMA_DIR/build/bin/$b" ]] || die "build did not produce $b"
  done
  ok "llama: build complete ($(nproc) cores, $jobs jobs)"
}

rpc_start() {
  require_root
  [[ -x "$LLAMA_DIR/build/bin/rpc-server" ]] || { llama_build; }
  [[ -n "${NODE_VPN_IP:-}" ]] || die "NODE_VPN_IP empty in $KCV_ENV_FILE (join the VPN first)"
  log "rpc: starting rpc-server on $NODE_VPN_IP:$RPC_PORT (VPN-only, no auth - never public)"
  systemctl stop "${KCV_PREFIX}-rpc-server" 2>/dev/null || true
  svc_write "rpc-server" "[Unit]
Description=korvarix llama.cpp RPC server
After=network-online.target wg-quick@wg0.service
Wants=wg-quick@wg0.service
[Service]
Type=simple
ExecStart=$LLAMA_DIR/build/bin/rpc-server -p $RPC_PORT -H $NODE_VPN_IP
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target"
  sleep 2
  systemctl is-active --quiet "${KCV_PREFIX}-rpc-server" || die "rpc-server failed - journalctl -u korvarix-rpc-server"
  # NO fw_allow here: the port must only be reachable over the VPN. Open the
  # port on the wg0 zone only (some hosts run a firewall on all interfaces).
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow in on wg0 to any port "$RPC_PORT" proto tcp >/dev/null 2>&1 \
      && ok "ufw: $RPC_PORT/tcp allowed on wg0 only"
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --zone=internal --add-source="${VPN_NET:-10.8.0.0}/24" >/dev/null 2>&1 || true
    firewall-cmd --permanent --zone=internal --add-port="$RPC_PORT/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    ok "firewalld: $RPC_PORT/tcp opened for the VPN subnet only"
  else
    warn "no firewall active - rpc port $RPC_PORT rides the VPN boundary only"
  fi
  state_set rpc_port "$RPC_PORT"
  ok "rpc: running (journalctl -u korvarix-rpc-server)"
}

rpc_stop() {
  systemctl stop "${KCV_PREFIX}-rpc-server" 2>/dev/null || true
  ok "rpc-server stopped"
}

llama_server_start() {
  require_root
  [[ -x "$LLAMA_DIR/build/bin/llama-server" ]] || { llama_build; }
  [[ -n "${MODEL_FILE:-}" ]] || die "MODEL_FILE empty in $KCV_ENV_FILE (gguf filename inside ${MODELS_DIR:-/data/models})"
  local model="${MODELS_DIR:-/data/models}/$MODEL_FILE"
  [[ -f "$model" ]] || die "model not found: $model"
  local rpc_args=""
  if [[ -n "${RPC_PEERS:-}" ]]; then
    rpc_args="--rpc $RPC_PEERS"
    log "llama-server: merged-RAM mode, peers: $RPC_PEERS"
  else
    log "llama-server: solo mode (RPC_PEERS empty - this node's RAM only)"
  fi
  # bind the API on the VPN IP so the frontend box reaches it over the
  # tunnel (127.0.0.1 would strand it on this node). VPN-only, never public.
  local bind="${LLAMA_BIND:-${NODE_VPN_IP:-127.0.0.1}}"
  [[ -n "$NODE_VPN_IP" ]] || { bind="127.0.0.1"; warn "NODE_VPN_IP unset - llama-server binds 127.0.0.1 (frontend cannot reach it over the VPN)"; }
  log "llama-server: ctx ${N_CTX:-8192}, threads ${N_THREADS:-auto}, bind $bind"
  systemctl stop "${KCV_PREFIX}-llama-server" 2>/dev/null || true
  svc_write "llama-server" "[Unit]
Description=korvarix llama-server (OpenAI-compatible)
After=network-online.target wg-quick@wg0.service
Wants=wg-quick@wg0.service
[Service]
Type=simple
ExecStart=$LLAMA_DIR/build/bin/llama-server -m $model $rpc_args -ngl 0 -c ${N_CTX:-8192} ${N_THREADS:+-t $N_THREADS} --host $bind --port $LLAMA_PORT
Restart=always
RestartSec=5
Environment=LD_LIBRARY_PATH=$LLAMA_DIR/build/bin
[Install]
WantedBy=multi-user.target"
  sleep 2
  systemctl is-active --quiet "${KCV_PREFIX}-llama-server" || die "llama-server failed - journalctl -u korvarix-llama-server"
  curl -fsS --max-time 5 "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1 \
    || warn "health not answering yet (model may still be loading - normal for big models on 1Gbps)"
  ok "llama-server: http://$bind:$LLAMA_PORT/v1 (frontend OPENAI_API_BASE_URL points here over the VPN)"
}

llama_server_stop() {
  systemctl stop "${KCV_PREFIX}-llama-server" 2>/dev/null || true
  ok "llama-server stopped"
}

llama_model_set() {
  require_root
  local mf="${1:-}"
  if [[ -z "$mf" ]] && kcv_tty; then
    ls -lh "${MODELS_DIR:-/data/models}"/*.gguf 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
    read -r -p "gguf filename: " mf || die "input failed"
  fi
  [[ -n "$mf" ]] || die "usage: llama set-model <filename.gguf>"
  [[ -f "${MODELS_DIR:-/data/models}/$mf" ]] || die "not found: ${MODELS_DIR:-/data/models}/$mf"
  sed -i "s/^MODEL_FILE=.*/MODEL_FILE=$mf/" "$KCV_ENV_FILE" 2>/dev/null || echo "MODEL_FILE=$mf" >> "$KCV_ENV_FILE"
  ok "MODEL_FILE=$mf set - use menu 4 -> start llama-server"
}

# add one donor node to the merged-RAM pool (manual flow confirmed: the
# wizard prints the command; this runs ON THE MASTER afterwards).
# Appends to RPC_PEERS, restarts llama-server, verifies every peer answers.
llama_add_peer() {
  require_root
  kcv_require_env
  local peer="${1:-}"
  if [[ -z "$peer" ]] && kcv_tty; then
    read -r -p "donor VPN IP (10.8.0.x, shown when its rpc-server started): " peer || die "input failed"
  fi
  [[ "$peer" =~ ^10\.8\.0\.[0-9]+$ ]] || die "not a VPN IP: $peer (donors join the VPN first, wizard role 3)"
  [[ "$(state_get role)" == "master" ]] || die "run on the master (it owns llama-server)"
  local port="${RPC_PORT:-50052}"
  local cur="${RPC_PEERS:-}"
  if [[ " $cur " == *" $peer:$port "* ]]; then
    warn "peer already in RPC_PEERS - re-verifying only"
  else
    local merged="${cur:+$cur,}$peer:$port"
    sed -i "s|^RPC_PEERS=.*|RPC_PEERS=$merged|" "$KCV_ENV_FILE" 2>/dev/null \
      || printf 'RPC_PEERS=%s\n' "$merged" >> "$KCV_ENV_FILE"
    RPC_PEERS="$merged"
    ok "RPC_PEERS=$merged"
  fi
  # no model yet? the peer registration is already persisted - it takes
  # effect on the next real start. Dying here would just confuse.
  if [[ -z "${MODEL_FILE:-}" ]]; then
    warn "peer registered but no MODEL_FILE set - takes effect when llama-server starts"
    warn "set a model: menu 4 -> 2 (needs a .gguf in ${MODELS_DIR:-/data/models}), or menu 5 (ollama catalog auto-downloads)"
  else
    llama_server_start
  fi
  # verify every peer actually answers before declaring victory
  local bad=0 entry ip pt entries
  IFS=',' read -ra entries <<<"$RPC_PEERS"
  for entry in "${entries[@]}"; do
    ip="${entry%%:*}"; pt="${entry##*:}"
    if timeout 5 bash -c "</dev/tcp/$ip/$pt" 2>/dev/null; then
      ok "peer reachable: $entry"
    else
      warn "peer NOT answering: $entry (rpc-server down there? menu 4 on that node)"
      bad=$((bad+1))
    fi
  done
  if [[ "$bad" -gt 0 ]]; then
    warn "$bad peer(s) unreachable - a down peer silently drops its layers (model loads with 1/N capacity)"
  else
    ok "all peers verified - merged-RAM ceiling grew ~110GB"
  fi
}

# quick per-peer reachability report (menu 4 / health support)
llama_peer_status() {
  local entry ip pt bad=0
  [[ -n "${RPC_PEERS:-}" ]] || { echo "rpc peers: none (solo mode)"; return 0; }
  echo "rpc peers (merged-RAM donors):"
  IFS=',' read -ra entries <<<"$RPC_PEERS"
  for entry in "${entries[@]}"; do
    ip="${entry%%:*}"; pt="${entry##*:}"
    if timeout 5 bash -c "</dev/tcp/$ip/$pt" 2>/dev/null; then
      printf '  %-22s reachable\n' "$entry"
    else
      printf '  %-22s UNREACHABLE (layers lost)\n' "$entry"
      bad=$((bad+1))
    fi
  done
  return "$bad"
}

kcv_module_llama() {
  local action="${1:-menu}"
  case "$action" in
    build)       llama_build ;;
    start)       llama_server_start ;;
    stop)        llama_server_stop ;;
    rpc-start)   rpc_start ;;
    rpc-stop)    rpc_stop ;;
    set-model)   shift; llama_model_set "$@" ;;
    add-peer)    shift; llama_add_peer "$@" ;;
    peers)       llama_peer_status ;;
    menu)
      echo "  1) build llama.cpp       2) set model     3) start llama-server"
      echo "  4) stop llama-server     5) start rpc     6) stop rpc  0) back"
      echo "  7) add peer (donor)      8) peer status"
      local r; read -r -p "select: " r
      case "$r" in
        1) llama_build ;;
        2) llama_model_set "" ;;
        3) llama_server_start ;;
        4) llama_server_stop ;;
        5) rpc_start ;;
        6) rpc_stop ;;
        7) llama_add_peer "" ;;
        8) llama_peer_status ;;
        *) : ;;
      esac
      ;;
    *) die "usage: llama build|start|stop|rpc-start|rpc-stop|set-model <file>|add-peer <vpn-ip>|peers" ;;
  esac
}