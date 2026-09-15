#!/usr/bin/env bash
# module: ollama
# Sandboxed Ollama serving + model allowlist + daily patch pulls + policy build.
# Everything the public AI endpoint offers flows through here:
#
#   MODELS_ALLOWLIST     - the ONLY models clients may call (space-separated)
#   OLLAMA_PULL_MODELS   - models the daily patch job keeps current (subset of
#                          the allowlist; the daily pull never adds new models)
#   OLLAMA_DAILY_PULL    - "1" installs the daily cron (default 1)
#   OLLAMA_SANDBOX       - dedicated unprivileged user + nohup-less systemd
#                          hardening for the ollama daemon (default 1)
#   OLLAMA_NUM_PARALLEL  - max concurrent generate slots per model (default 2)
#   OLLAMA_MAX_LOADED    - max models kept loaded in RAM at once (default 2)
#   KORVARIX_POLICY_*    - request-guardrail knobs baked into policy.json and
#                          pushed to the frontend gate (rate limits, param
#                          clamps, web lookup, safety filter)
#
# Legal posture for a public endpoint: allowlist-only models, clamped
# parameters, per-IP+per-key rate limits, in-flight caps, and an optional
# blocklist filter (refuses obvious CSAM / violent-extremism style prompts
# before they ever reach the model). See CLUSTER.md "Public API policy".

ollama_user() { echo "korvarix-ollama"; }

ollama_install() {
  require_root
  log "ollama: installing (vendored binary, sandboxed)"
  kcv_virt_check
  kcv_base_tools
  dep_ensure "curl:curl" "useradd:passwd"
  net_gate "https://ollama.com/download/ollama-linux-amd64.tgz"

  local dir="${KCV_LIB_DIR}/ollama"
  mkdir -p "$dir/bin" "${OLLAMA_MODELS:-$dir/models}"
  if [[ ! -x "$dir/bin/ollama" ]]; then
    fetch "https://ollama.com/download/ollama-linux-amd64.tgz" "/tmp/ollama.tgz"
    tar -xzf /tmp/ollama.tgz -C "$dir" --strip-components=0 bin/ollama 2>/dev/null \
      || tar -xzf /tmp/ollama.tgz -C "$dir"
    rm -f /tmp/ollama.tgz
  fi
  "$dir/bin/ollama" --version || die "ollama binary failed to run"

  # ---- sandbox: dedicated unprivileged system user owns models + daemon ----
  if [[ "${OLLAMA_SANDBOX:-1}" == "1" ]] && ! id korvarix-ollama >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin korvarix-ollama
    log "ollama: created unprivileged user korvarix-ollama"
  fi
  local owner="korvarix-ollama"
  [[ "${OLLAMA_SANDBOX:-1}" == "1" ]] || owner="root"
  chown -R "$owner":"$owner" "$dir" "${OLLAMA_MODELS:-$dir/models}" 2>/dev/null || true
  state_set ollama_dir "$dir"
  ok "ollama: installed at $dir (models: ${OLLAMA_MODELS:-$dir/models})"
}

ollama_service() {
  require_root
  local dir
  dir="$(state_get ollama_dir)"
  [[ -n "$dir" ]] || { ollama_install; dir="$(state_get ollama_dir)"; }
  local owner="root"
  [[ "${OLLAMA_SANDBOX:-1}" == "1" ]] && owner="korvarix-ollama"
  local models_dir="${OLLAMA_MODELS:-$dir/models}"
  mkdir -p "$KCV_LOG_DIR"
svc_write "ollama" "[Unit]
Description=korvarix sandboxed Ollama (allowlist-served models)
After=network.target
[Service]
Type=simple
User=$owner
Group=$owner
# OLLAMA_BIND: 127.0.0.1 (default) = local only; set to this node's VPN IP
# (NODE_VPN_IP) so the frontend's Open WebUI can reach the one shared daemon
ExecStart=$dir/bin/ollama serve
Environment=OLLAMA_HOST=${OLLAMA_BIND:-127.0.0.1}:${OLLAMA_PORT:-11434}
Environment=OLLAMA_MODELS=${models_dir}
Environment=OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL:-2}
Environment=OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED:-2}
Environment=OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE:-10m}
# sandbox hardening: no writable syscalls beyond /tmp, no new privileges,
# private tmp, protect kernel/housekeeping paths (systemd eBPF-free set)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
ReadWritePaths=${models_dir} $dir
LimitMEMLOCK=64M
LimitNOFILE=65536
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target"
  sleep 2
  systemctl is-active --quiet korvarix-ollama || die "ollama failed to start - journalctl -u korvarix-ollama"
  state_set ollama_port "${OLLAMA_PORT:-11434}"
  # bind != loopback: the port must be reachable - open it ONLY from the VPN
  # subnet (the VPN is the reachability boundary; never a public interface)
  if [[ "${OLLAMA_BIND:-127.0.0.1}" != "127.0.0.1" ]]; then
    fw_allow_from "${VPN_NET:-10.8.0.0}/24" tcp "${OLLAMA_PORT:-11434}"
    warn "ollama: reachable on ${OLLAMA_BIND}:${OLLAMA_PORT:-11434} - keep OLLAMA_BIND at the VPN IP, never a public IP"
  fi
  ok "ollama: serving on ${OLLAMA_BIND:-127.0.0.1}:${OLLAMA_PORT:-11434} (user $owner, hardened)"
}

# pull exactly the allowlisted models (never auto-extends the list)
ollama_pull() {
  require_root
  [[ -n "${MODELS_ALLOWLIST:-}" ]] || die "MODELS_ALLOWLIST empty in $KCV_ENV_FILE (e.g. 'qwen2.5:7b llama3.1:8b')"
  local m
  for m in $MODELS_ALLOWLIST; do
    log "ollama: ensuring $m (this can take a while on first pull)"
    "$(state_get ollama_dir)/bin/ollama" pull "$m" || warn "pull failed: $m (check disk space)"
  done
  ok "ollama: allowlist models present"
}

# ---- model picker -------------------------------------------------------------
# Curated CPU-friendly catalog, TWO sections:
#   OFFICIAL   - ollama.com/library models (maintained by Ollama Inc. / the
#                model's own vendor: Meta, Qwen/Alibaba, Google, Microsoft,
#                Mistral, IBM, NVIDIA, DeepSeek...). CPU sizes only (<= ~40GB
#                q4_K_M); cloud-tagged models (gpt-oss:120b-cloud etc.) are
#                EXCLUDED - they execute on Ollama's servers, not our nodes.
#   COMMUNITY  - publisher-uploaded models (ollama.com/<publisher>/<model>).
#                Fine-tunes/abliterations for roleplay, storytelling, coding.
#                Verified individual sizes where listed; treat pull sizes as
#                approximate and watch the pull output.
# RAM guidance vs this cluster: 128GB nodes, OLLAMA_MAX_LOADED bounds how many
# models co-reside in memory. Q2_K/Q4_K_M quants are the CPU sweet spot.
# Format: slug|Label|~N GB RAM|description|section(O=official,C=community)|category
#   Categories drive the paged picker: CHAT REASON CODE RP UNC SMALL.

# --- OFFICIAL (ollama.com/library, verified CPU-runnable sizes) ---
OLLAMA_CATALOG=(
  # all-round chat
  "qwen3:4b|Qwen 3 4B|~3|Google-rival small, fast|O|CHAT"
  "qwen3:8b|Qwen 3 8B|~5|all-round chat + thinking, fast|O|CHAT"
  "qwen2.5:3b|Qwen 2.5 3B|~2|tiny all-rounder|O|CHAT"
  "qwen2.5:7b|Qwen 2.5 7B|~5|proven all-rounder|O|CHAT"
  "qwen2.5:14b|Qwen 2.5 14B|~9|strong general|O|CHAT"
  "llama3.1:8b|Llama 3.1 8B|~5|Meta all-rounder, huge ecosystem|O|CHAT"
  "llama3.1:70b|Llama 3.1 70B|~40|top dense quality, slow on CPU|O|CHAT"
  "llama3.2:3b|Llama 3.2 3B|~2|Meta small|O|CHAT"
  "llama3.3:70b|Llama 3.3 70B|~40|newer 70B, 405B-class output|O|CHAT"
  "mistral:7b|Mistral 7B|~4|small + fast|O|CHAT"
  "mistral-nemo|Mistral Nemo 12B|~7|128k context, multilingual|O|CHAT"
  "mistral-small:22b|Mistral Small 22B|~13|strong mid-tier|O|CHAT"
  "gemma3:12b|Gemma 3 12B|~8|Google mid-tier|O|CHAT"
  "gemma3:27b|Gemma 3 27B|~17|Google heavy|O|CHAT"
  "phi4-mini:3.8b|Phi-4 Mini 3.8B|~2.5|multilingual + function calling|O|CHAT"
  "phi3:3.8b|Phi-3 Mini 3.8B|~2.5|Microsoft lightweight|O|CHAT"
  "granite3.3:8b|Granite 3.3 8B|~5|IBM 128k context|O|CHAT"
  "olmo2:7b|OLMo 2 7B|~4|AI2 fully-open model|O|CHAT"
  "lfm2:24b|LFM2 24B|~14|on-device hybrid architecture|O|CHAT"
  "command-r:35b|Command R 35B|~20|Cohere long-context RAG|O|CHAT"
  "glm4:9b|GLM-4 9B|~5.5|multilingual, Llama-3 competitive|O|CHAT"
  "yi:9b|Yi 1.5 9B|~5|bilingual strong|O|CHAT"
  "aya-expanse:8b|Aya Expanse 8B|~5|Cohere 23-language|O|CHAT"
  # reasoning
  "qwen3:14b|Qwen 3 14B|~9|stronger reasoning tier|O|REASON"
  "qwen3:30b-a3b|Qwen 3 30B-A3B (MoE)|~19|MoE - only 3B active params, near-8B speed at 30B quality|O|REASON"
  "qwen3:32b|Qwen 3 32B|~20|dense heavy reasoning|O|REASON"
  "qwen2.5:32b|Qwen 2.5 32B|~20|heavy reasoning|O|REASON"
  "phi4:14b|Phi-4 14B|~9|Microsoft reasoning|O|REASON"
  "phi4-reasoning:14b|Phi-4 Reasoning 14B|~9|complex reasoning focused|O|REASON"
  "deepseek-r1:8b|DeepSeek R1 8B|~5|reasoning, thinks step-by-step|O|REASON"
  "deepseek-r1:14b|DeepSeek R1 14B|~9|deeper reasoning|O|REASON"
  "deepseek-r1:32b|DeepSeek R1 32B|~20|deep reasoning, slower|O|REASON"
  "qwq:32b|QwQ 32B|~20|Qwen reasoning model|O|REASON"
  "falcon3:7b|Falcon 3 7B|~4|TII science/math|O|REASON"
  "gpt-oss:20b|GPT-OSS 20B|~12|OpenAI open-weight reasoning (local build)|O|REASON"
  # coding
  "qwen2.5-coder:7b|Qwen 2.5 Coder 7B|~5|code generation/completion|O|CODE"
  "qwen2.5-coder:14b|Qwen 2.5 Coder 14B|~9|stronger code model|O|CODE"
  "qwen2.5-coder:32b|Qwen 2.5 Coder 32B|~20|heavy code model|O|CODE"
  "granite4:3b|Granite 4 3B|~2|IBM enterprise tool-calling|O|CODE"
  # lightweight
  "gemma3:1b|Gemma 3 1B|~1|Google, featherweight|O|SMALL"
  "gemma3:4b|Gemma 3 4B|~3|Google light, vision-capable|O|SMALL"
  "gemma3n:e2b|Gemma 3n E2B|~2|efficient everyday-device model|O|SMALL"
  "gemma3n:e4b|Gemma 3n E4B|~3|efficient everyday-device model|O|SMALL"
  "granite3.1-moe:3b|Granite 3.1 MoE 3B|~2|IBM low-latency MoE|O|SMALL"
  "smollm2:1.7b|SmolLM2 1.7B|~1.8|compact + tools|O|SMALL"

  # --- COMMUNITY (publisher uploads - fine-tunes) ---
  # roleplay & story
  "oroboros-labs/claude-fable5|Claude Fable 5|~9.8|oroboros-labs Claude fine-tune, Q2_K, 256k ctx - your pick|C|RP"
  "oroboros-labs/claude-fable5-undecillion|Claude Fable 5 Undecillion|~12|oroboros-labs deep-reasoning variant, Q4_K_M, 1M ctx|C|RP"
  "oroboros-labs/claude-sonnet-7-undecillion|Claude Sonnet 7 Undecillion|~12|oroboros-labs Sonnet-line fine-tune, tools|C|RP"
  "oroboros-labs/claude-fable5u|Claude Fable 5U|~9.8|oroboros-labs fast daily-driver variant, Q2_K|C|RP"
  "LESSTHANSUPER/DARKEST_UNIVERSE-Mistral_Nemo-29b|Darkest Universe 29B|~17|DavidAU storytelling, uncensored|C|RP"
  "LESSTHANSUPER/RP-INK-Qwen2.5-32b|RP-INK Qwen2.5 32B|~20|highly-rated roleplay fine-tune|C|RP"
  "LESSTHANSUPER/DARK_PLANET_REBEL_FURY-Llama3-25b|Dark Planet Rebel Fury 25B|~15|storytelling MoE|C|RP"
  "RoseRudolph/rudy-nemo-12b-v1|Rudy Nemo 12B|~7|NeMo/Rocinante merge, long-context roleplay|C|RP"
  "nemotron-mini:4b|Nemotron Mini 4B|~3|NVIDIA roleplay/RAG/function-calling|O|RP"
  # uncensored
  "R4C3R/qwen3-8b-heretic|R4C3R Qwen3-8B Heretic|~5|uncensored creative writing/roleplay fine-tune|C|UNC"
  "R4C3R/gemma-3-12b-it-heretic|R4C3R Gemma-3-12B Heretic|~8|uncensored creative writing fine-tune|C|UNC"
  "R4C3R/mistral-7b-instruct-v0.3-heretic|R4C3R Mistral-7B Heretic|~4|uncensored creative writing fine-tune|C|UNC"
  "orcarouter/Qwen3.8-27B-Uncensored|Qwen3.8-27B Uncensored|~17|tensor-level abliteration, vision+tools+thinking, 262k ctx|C|UNC"
  "dolphin3:8b|Dolphin 3.0 8B|~5|Eric Hartford instruct uncensored|C|UNC"
  "dolphin-mistral:7b|Dolphin Mistral 7B|~4|uncensored coding|C|UNC"
  "dolphin-mixtral:8x7b|Dolphin Mixtral 8x7B|~26|uncensored MoE coding|C|UNC"
  "wizard-vicuna-uncensored:7b|Wizard Vicuna Unc. 7B|~4|classic uncensored chat|C|UNC"
  "llama2-uncensored:7b|Llama 2 Uncensored 7B|~4|classic uncensored chat|C|UNC"
  # coding
  "voytas26/openclaw-oss-20b-deterministic|OpenClaw OSS 20B|~12|deterministic tool-aware gpt-oss for agents|C|CODE"
  # chat
  "hermes3:8b|Hermes 3 8B|~5|Nous Research flagship tune|C|CHAT"
)

# rough GB number from the catalog RAM label
catalog_ram_gb() { tr -dc '0-9.' <<<"$1" | head -c 4; }

# paged model picker: category upfront, 9 rows per page.
# Numbers are GLOBAL across the whole browse session (a pick on page 1 keeps
# its number on page 7), so selection stays unambiguous while paging.
CATALOG_CATEGORIES=(CHAT REASON CODE RP UNC SMALL)
CATALOG_PAGES=9

ollama_pick_models() {
  require_root
  echo
  log "model catalog - CPU-friendly picks - current allowlist: ${MODELS_ALLOWLIST:-none}"
  local picks=() sel
  sel="$(ollama_pick_browse)" || { warn "cancelled - allowlist unchanged"; return 1; }
  # resolve selection (numbers = global indices; keywords pass through)
  if [[ "$sel" == "@ALL" ]]; then
    local e
    for e in "${OLLAMA_CATALOG[@]}"; do picks+=("${e%%|*}"); done
  else
    local n
    for n in $sel; do
      [[ "$n" =~ ^[0-9]+$ ]] || continue
      (( n >= 1 && n <= ${#OLLAMA_CATALOG[@]} )) || continue
      picks+=("${OLLAMA_CATALOG[$((n-1))]%%|*}")
    done
  fi
  [[ ${#picks[@]} -gt 0 ]] || { warn "nothing selected - allowlist unchanged"; return 1; }
  _picks_apply "${picks[@]}"
}

# browse UI: returns "NUM NUM ..." on stdout, or "@ALL"; return 1 = cancel
ollama_pick_browse() {
  local page=1 total=${#OLLAMA_CATALOG[@]}
  # separate line: a single `local a=1 b=$((a+1))` expands $a BEFORE a is
  # assigned, which dies under set -u ("total: unbound variable")
  local pages=$(( (total + CATALOG_PAGES - 1) / CATALOG_PAGES ))
  local chosen=() reply token
  while true; do
    echo
    printf '\033[1;35m== korvarix model catalog  page %d/%d ==\033[0m\n' "$page" "$pages" >&2
    printf '\033[1;36m  numbers are GLOBAL (same number = same model on every page)\033[0m\n' >&2
    local i start end
    start=$(( (page-1)*CATALOG_PAGES + 1 ))
    end=$(( start + CATALOG_PAGES - 1 ))
    for ((i=start; i<=end && i<=total; i++)); do
      local entry slug label ram desc sec cat
      entry="${OLLAMA_CATALOG[$((i-1))]}"
      IFS='|' read -r slug label ram desc sec cat <<<"$entry"
      local tag=" "
      local c
      for c in "${chosen[@]}"; do [[ "$c" == "$i" ]] && tag="*"; done
      # >&2: this function runs inside $( ) - stdout is the CAPTURED return
      # value; only the final selection line may go to stdout
      printf ' %s%2d) [%-7s] %-40s %-8s %s\n' "$tag" "$i" "$cat" "$slug" "$ram GB" "$desc" >&2
    done
    echo >&2
    if [[ ${#chosen[@]} -gt 0 ]]; then
      local names="" c
      for c in "${chosen[@]}"; do names+="${OLLAMA_CATALOG[$((c-1))]%%|*} "; done
      printf '\033[1;32m  picked: %s\033[0m\n' "${names% }" >&2
    else
      echo "  picked: (none yet)" >&2
    fi
    echo "  type numbers to ADD | n/p page | category (CHAT REASON CODE RP UNC SMALL) | done | x cancel" >&2
    read -r -e -p "> " reply || return 1
    reply="$(xargs <<<"$reply")"
    case "$reply" in
      x|X|0|q|quit) return 1 ;;
      done|d) [[ ${#chosen[@]} -eq 0 ]] && { warn "nothing picked yet - type model numbers first"; continue; }
              printf '%s\n' "${chosen[*]}"; return 0 ;;
      all) printf '@ALL\n'; return 0 ;;
      n|next) if (( page < pages )); then page=$((page+1)); else echo "  (last page)" >&2; fi ;;
      p|prev) if (( page > 1 )); then page=$((page-1)); else echo "  (first page)" >&2; fi ;;
      *)
        local had_any=0
        for token in $reply; do
          if [[ "$token" != [0-9]* && "${CATALOG_CATEGORIES[*]}" == *" $token "* ]]; then
            had_any=1
            # jump to the page holding this category's FIRST entry
            local e _s _c ei=0
            for e in "${OLLAMA_CATALOG[@]}"; do
              IFS='|' read -r _ _ _ _ _s _c <<<"$e"
              [[ "$_c" == "$token" ]] && break
              ei=$((ei+1))
            done
            page=$(( ei / CATALOG_PAGES + 1 ))
          elif [[ "$token" =~ ^[0-9]+$ ]] && (( token >= 1 && token <= total )); then
            had_any=1
            # add-only, duplicate-safe
            local have=0 c
            for c in "${chosen[@]}"; do [[ "$c" == "$token" ]] && have=1; done
            if (( ! have )); then chosen+=("$token"); fi
          else
            echo "  ? $token" >&2
          fi
        done
        (( had_any )) || warn "nothing valid in: $reply"
        ;;
    esac
  done
}

# shared tail of the picker: merge picks into the allowlist, write, pull
_picks_apply() {
  local merged="${MODELS_ALLOWLIST:-}"
  local seen=" $merged "
  local m
  for m in "$@"; do
    [[ "$seen" == *" $m "* ]] && continue
    merged="$merged $m"
    seen="$seen$m "
  done
  MODELS_ALLOWLIST="${merged# }"
  # xargs-trim + dedup whitespace
  MODELS_ALLOWLIST="$(xargs <<<"$MODELS_ALLOWLIST")"

  # disk estimate from catalog RAM labels (approx; unknown models count 0)
  local total=0
  for m in $MODELS_ALLOWLIST; do
    for entry in "${OLLAMA_CATALOG[@]}"; do
      [[ "${entry%%|*}" == "$m" ]] || continue
      IFS='|' read -r _slug _label ram _desc _s <<<"$entry"
      total="$(awk -v a="$total" -v b="$ram" 'BEGIN{printf "%.0f", a+b}')"
    done
  done
  warn "allowlist total pull size estimate: ~${total} GB disk (RAM use is bounded by OLLAMA_MAX_LOADED=${OLLAMA_MAX_LOADED:-2} loaded models)"
  kcv_confirm "write MODELS_ALLOWLIST to $KCV_ENV_FILE and pull now?" || { warn "cancelled - nothing written"; return 1; }

  sed -i "s|^MODELS_ALLOWLIST=.*|MODELS_ALLOWLIST=$MODELS_ALLOWLIST|" "$KCV_ENV_FILE" 2>/dev/null \
    || printf 'MODELS_ALLOWLIST=%s\n' "$MODELS_ALLOWLIST" >> "$KCV_ENV_FILE"
  # re-source so ollama_pull sees the new list
  # shellcheck source=/dev/null
  set -a
  # shellcheck disable=SC1090
  source "$KCV_ENV_FILE"
  set +a
  ok "MODELS_ALLOWLIST=$MODELS_ALLOWLIST"
  ollama_pull

  if kcv_confirm "rebuild + push the request policy (so the gate allows the new models)?"; then
    ollama_policy_build
    ollama_policy_push
  else
    warn "policy NOT updated - the gate will still refuse the new models until you run: ollama policy && ollama push"
  fi
}

# daily freshness: re-pull allowlisted models so quant patches / updates land
# automatically; ALSO prunes anything not on the allowlist (sandbox hygiene:
# nobody can smuggle a model in via the API and have it persist)
ollama_daily_maintenance() {
  local dir
  dir="$(state_get ollama_dir)"
  [[ -n "$dir" && -x "$dir/bin/ollama" ]] || exit 0
  local m
  for m in $MODELS_ALLOWLIST; do
    "$dir/bin/ollama" pull "$m" >> "$KCV_LOG_DIR/ollama-pull.log" 2>&1 || true
  done
  # prune non-allowlisted models (defense: API cannot install models, and any
  # stray model is removed so disk + RAM stay within the sandbox budget)
  local installed
  installed="$("$dir/bin/ollama" list 2>/dev/null | awk 'NR>1{print $1}')"
  for m in $installed; do
    local keep=0
    for a in $MODELS_ALLOWLIST; do [[ "$m" == "$a" ]] && keep=1; done
    if [[ "$keep" != "1" ]]; then
      "$dir/bin/ollama" rm "$m" >> "$KCV_LOG_DIR/ollama-pull.log" 2>&1 || true
      echo "$(date -Is) pruned non-allowlisted model: $m" >> "$KCV_LOG_DIR/ollama-pull.log"
    fi
  done
}

ollama_cron_install() {
  require_root
  local station
  station="$(state_get station_path)"
  [[ -n "$station" ]] || die "station path unknown"
  cron_install "ollama-patch" "23 5 * * *" "root $station ollama daily >> $KCV_LOG_DIR/ollama-pull.log 2>&1"
}

# ---- policy: the guardrails the frontend gate enforces -----------------------
# Built from .env knobs, checksummed, and fetched by the gate from the master.
# Values are CLAMPS (upper bounds) - the gate rewrites client-supplied
# parameters down to these limits rather than trusting them.
ollama_policy_build() {
  require_root
  local out="${KCV_LIB_DIR}/korvarix-policy.json"
  local now
  now="$(date +%s)"
  cat > "$out" <<EOF
{
  "version": $now,
  "models": [$(for m in $MODELS_ALLOWLIST; do printf '"%s",' "$m"; done | sed 's/,$//')],
  "limits": {
    "requests_per_min_per_ip": ${POLICY_RPM_IP:-10},
    "requests_per_min_per_key": ${POLICY_RPM_KEY:-60},
    "max_in_flight_per_ip": ${POLICY_INFLIGHT_IP:-2},
    "max_context_tokens": ${POLICY_MAX_CTX:-32768},
    "max_output_tokens": ${POLICY_MAX_OUT:-8192},
    "max_prompt_chars": ${POLICY_MAX_PROMPT_CHARS:-128000},
    "temperature_max": ${POLICY_TEMP_MAX:-1.0},
    "top_p_max": ${POLICY_TOPP_MAX:-1.0},
    "max_keys_per_ip_per_day": ${POLICY_KEYS_PER_IP_DAY:-5}
  },
  "features": {
    "web_lookup": ${POLICY_WEB_LOOKUP:-false},
    "safety_filter": ${POLICY_SAFETY_FILTER:-true},
    "system_prompt_locked": ${POLICY_LOCK_SYSTEM_PROMPT:-false}
  }
}
EOF
  local sum
  sum="$(sha256sum "$out" | awk '{print $1}')"
  printf '%s\n' "$sum" > "${out}.sha256"
  ok "policy built: $out (sha256 ${sum:0:12}...)"
  ok "policy knobs: rpm/ip=${POLICY_RPM_IP:-10} rpm/key=${POLICY_RPM_KEY:-60} in-flight=${POLICY_INFLIGHT_IP:-2} ctx<=${POLICY_MAX_CTX:-32768} out<=${POLICY_MAX_OUT:-8192} web_lookup=${POLICY_WEB_LOOKUP:-false} safety=${POLICY_SAFETY_FILTER:-true}"
}

# push policy + serving endpoint to the frontend gate (rsync over ssh). The
# gate never trusts its own copy beyond the checksum.
# FRONTEND_VPN_IP is the frontend box's VPN IP (set by the frontend wizard) -
# it must NOT default to the master: the master pushing to itself would
# strand the policy where the gate can never read it.
ollama_policy_push() {
  require_root
  kcv_require_env
  local host="${FRONTEND_VPN_IP:-${POLICY_PUSH_HOST:-}}"
  [[ -n "$host" ]] || die "FRONTEND_VPN_IP / POLICY_PUSH_HOST empty in $KCV_ENV_FILE (the frontend box's VPN IP)"
  command -v rsync >/dev/null 2>&1 || pkg_install rsync
  if [[ "$host" == "${MASTER_VPN_IP:-}" ]]; then
    warn "target == MASTER_VPN_IP - the policy belongs on the FRONTEND box; did you mean FRONTEND_VPN_IP?"
    kcv_confirm "push to $host anyway?" || return 1
  fi
  log "policy: pushing to $host"
  ssh_remote "$host" "mkdir -p /etc/korvarix-llm" || die "ssh to frontend failed"
  # perms 644: the gate container runs as the non-root "node" user — 640 leaves
  # the policy root-only and the gate reports "no policy file" (found in dry run)
  rsync -a --chmod=F644 "${KCV_LIB_DIR}/korvarix-policy.json" "root@${host}:/etc/korvarix-llm/korvarix-policy.json" || die "rsync policy failed"
  rsync -a --chmod=F644 "${KCV_LIB_DIR}/korvarix-policy.json.sha256" "root@${host}:/etc/korvarix-llm/korvarix-policy.json.sha256" || die "rsync checksum failed"
  ssh_remote "$host" "mkdir -p /var/log/korvarix && (chown -R 1000:1000 /var/log/korvarix 2>/dev/null || chmod 777 /var/log/korvarix)" || true
  ssh_remote "$host" "systemctl restart korvarix-gate 2>/dev/null || docker restart korvarix-llm-gate 2>/dev/null || true"
  ok "policy pushed + gate reloaded on $host"
}

ollama_status() {
  local dir
  dir="$(state_get ollama_dir)"
  svc_active ollama && echo "ollama: running (127.0.0.1:$(state_get ollama_port))" || echo "ollama: stopped"
  if [[ -n "$dir" && -x "$dir/bin/ollama" ]]; then
    "$dir/bin/ollama" list 2>/dev/null | sed 's/^/  /'
  fi
  echo "allowlist: ${MODELS_ALLOWLIST:-none set}"
  [[ -f "${KCV_LIB_DIR}/korvarix-policy.json" ]] && echo "policy: built ($(state_get policy_version))"
}

kcv_module_ollama() {
  local action="${1:-menu}"
  case "$action" in
    install) ollama_install ;;
    serve)   ollama_service ;;
    pull)    ollama_pull ;;
    add)     ollama_pick_models ;;
    daily)   ollama_daily_maintenance ;;
    cron)    ollama_cron_install ;;
    policy)  ollama_policy_build ;;
    push)    ollama_policy_push ;;
    status)  ollama_status ;;
    menu)
      echo "  1) install (sandboxed)   2) start service    3) pull allowlist models"
      echo "  4) add models (picker)   5) daily maintenance 6) build policy"
      echo "  7) push policy to frontend 8) daily cron     9) status  0) back"
      local r; read -r -p "select: " r
      case "$r" in
        1) ollama_install ;;
        2) ollama_service ;;
        3) ollama_pull ;;
        4) ollama_pick_models ;;
        5) ollama_daily_maintenance ;;
        6) ollama_policy_build ;;
        7) ollama_policy_push ;;
        8) ollama_cron_install ;;
        9) ollama_status ;;
        *) : ;;
      esac
      ;;
    *) die "usage: ollama install|serve|pull|add|daily|cron|policy|push|status" ;;
  esac
}