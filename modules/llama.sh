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
  (
    cd "$LLAMA_DIR" || die "cannot enter $LLAMA_DIR"
    git fetch --tags --force 2>/dev/null || true
    if [[ -n "${LLAMA_CPP_REF:-}" ]]; then
      git checkout "$LLAMA_CPP_REF" || die "checkout $LLAMA_CPP_REF failed"
    fi
    cmake -B build -DGGML_RPC=ON -DGGML_NATIVE=ON >/dev/null || die "cmake configure failed"
    cmake --build build -j"$(nproc)" >/dev/null || die "build failed"
  )
  local b
  for b in rpc-server llama-server; do
    [[ -x "$LLAMA_DIR/build/bin/$b" ]] || die "build did not produce $b"
  done
  ok "llama: build complete ($(nproc) cores)"
}

rpc_start() {
  require_root
  [[ -x "$LLAMA_DIR/build/bin/rpc-server" ]] || { llama_build; }
  log "rpc: starting rpc-server on 0.0.0.0:$RPC_PORT"
  systemctl stop "${KCV_PREFIX}-rpc-server" 2>/dev/null || true
  svc_write "rpc-server" "[Unit]
Description=korvarix llama.cpp RPC server
After=network.target
[Service]
Type=simple
ExecStart=$LLAMA_DIR/build/bin/rpc-server -p $RPC_PORT -H 0.0.0.0
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target"
  sleep 2
  systemctl is-active --quiet "${KCV_PREFIX}-rpc-server" || die "rpc-server failed - journalctl -u korvarix-rpc-server"
  fw_allow tcp "$RPC_PORT"
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
  [[ -n "${MODEL_FILE:-}" ]] || die "MODEL_FILE empty in $KCV_ENV_FILE (gguf filename inside ${MODELS_DIR:-/mnt/gv0/models})"
  local model="${MODELS_DIR:-/mnt/gv0/models}/$MODEL_FILE"
  [[ -f "$model" ]] || die "model not found: $model"
  local rpc_args=""
  if [[ -n "${RPC_PEERS:-}" ]]; then
    rpc_args="--rpc $RPC_PEERS"
    log "llama-server: merged-RAM mode, peers: $RPC_PEERS"
  else
    log "llama-server: solo mode (RPC_PEERS empty - this node's RAM only)"
  fi
  log "llama-server: ctx ${N_CTX:-8192}, threads ${N_THREADS:-auto}"
  systemctl stop "${KCV_PREFIX}-llama-server" 2>/dev/null || true
  svc_write "llama-server" "[Unit]
Description=korvarix llama-server (OpenAI-compatible)
After=network.target
[Service]
Type=simple
ExecStart=$LLAMA_DIR/build/bin/llama-server -m $model $rpc_args -ngl 0 -c ${N_CTX:-8192} ${N_THREADS:+-t $N_THREADS} --host 127.0.0.1 --port $LLAMA_PORT
Restart=always
RestartSec=5
Environment=LD_LIBRARY_PATH=$LLAMA_DIR/build/bin
[Install]
WantedBy=multi-user.target"
  sleep 2
  systemctl is-active --quiet "${KCV_PREFIX}-llama-server" || die "llama-server failed - journalctl -u korvarix-llama-server"
  curl -fsS --max-time 5 "http://127.0.0.1:$LLAMA_PORT/health" >/dev/null 2>&1 \
    || warn "health not answering yet (model may still be loading - normal for big models on 1Gbps)"
  ok "llama-server: http://127.0.0.1:$LLAMA_PORT/v1 (proxy this from korvarix-llm frontend)"
}

llama_server_stop() {
  systemctl stop "${KCV_PREFIX}-llama-server" 2>/dev/null || true
  ok "llama-server stopped"
}

llama_model_set() {
  require_root
  local mf="$1"
  if [[ -z "$mf" ]] && kcv_tty; then
    ls -lh "${MODELS_DIR:-/mnt/gv0/models}"/*.gguf 2>/dev/null | awk '{print "  " $NF " (" $5 ")"}'
    read -r -p "gguf filename: " mf || die "input failed"
  fi
  [[ -n "$mf" ]] || die "usage: llama set-model <filename.gguf>"
  [[ -f "${MODELS_DIR:-/mnt/gv0/models}/$mf" ]] || die "not found: ${MODELS_DIR:-/mnt/gv0/models}/$mf"
  sed -i "s/^MODEL_FILE=.*/MODEL_FILE=$mf/" "$KCV_ENV_FILE" 2>/dev/null || echo "MODEL_FILE=$mf" >> "$KCV_ENV_FILE"
  ok "MODEL_FILE=$mf set - use menu 4 -> start llama-server"
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
    menu)
      echo "  1) build llama.cpp       2) set model     3) start llama-server"
      echo "  4) stop llama-server     5) start rpc     6) stop rpc  0) back"
      local r; read -r -p "select: " r
      case "$r" in
        1) llama_build ;;
        2) llama_model_set "" ;;
        3) llama_server_start ;;
        4) llama_server_stop ;;
        5) rpc_start ;;
        6) rpc_stop ;;
        *) : ;;
      esac
      ;;
    *) die "usage: llama build|start|stop|rpc-start|rpc-stop|set-model <file>" ;;
  esac
}