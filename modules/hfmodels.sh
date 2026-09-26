#!/usr/bin/env bash
# module: hfmodels
# Hugging Face trending-model tracker for the Ollama serving node.
#
# ollama.com's library lags hf.co by weeks. This module closes that gap:
#
#   hfmodels trending   - one newest/trending model per developer company,
#                         straight from the same ranking as
#   hf.co/models?apps=vllm&base_model_relation=base&sort=trending
#   hfmodels add        - pull one (or the auto-picked) model as a GGUF quant
#   hfmodels daily      - cron job: re-pull tracked models ONLY when the
#                         upstream repo sha changed (no blind re-downloads),
#                         then optionally auto-adopt the newest trending model
#                         per company not yet installed (HF_AUTO_DISCOVER).
#
# Everything pulled lands in MODELS_ALLOWLIST in $KCV_ENV_FILE - required,
# because the ollama module's daily prune deletes non-allowlisted models.
# Budget guardrails keep a trending 2.8T monster off the node: a quant must
# fit HF_MAX_MODEL_GB and leave HF_MIN_FREE_GB disk free.
#
#   HF_TRACKED_MODELS   - hf.co/<repo>:<quant> names the daily job keeps fresh
#   HF_AUTO_DISCOVER    - "1" = daily job auto-adds newest-per-company (default 1)
#   HF_MAX_MODELS       - max NEW models adopted per daily run (default 1)
#   HF_MAX_MODEL_GB     - max download size per model, GB (default 24)
#   HF_MIN_FREE_GB      - keep this much disk free after pull (default 30)
#   HF_QUANT_CHAIN      - quant fallback order, first that fits wins
#                         (default "Q4_K_M Q4_K_S Q4_0 Q3_K_M Q8_0")
#   HF_ORG_BLOCKLIST    - orgs to never adopt (default "jinaai")
#   HF_DISCOVER_LIMIT   - how deep into trending to look (default 100)
#
# The gate only serves MODELS_ALLOWLIST models after a policy rebuild:
#   korvarix-cluster.sh ollama policy && korvarix-cluster.sh ollama push

HF_API="https://huggingface.co/api"

hfmodels_defaults() {
  HF_QUANT_CHAIN="${HF_QUANT_CHAIN:-Q4_K_M Q4_K_S Q4_0 Q3_K_M Q8_0}"
  HF_MAX_MODEL_GB="${HF_MAX_MODEL_GB:-24}"
  HF_MIN_FREE_GB="${HF_MIN_FREE_GB:-30}"
  HF_AUTO_DISCOVER="${HF_AUTO_DISCOVER:-1}"
  HF_MAX_MODELS="${HF_MAX_MODELS:-1}"
  HF_ORG_BLOCKLIST="${HF_ORG_BLOCKLIST:-jinaai}"
  HF_DISCOVER_LIMIT="${HF_DISCOVER_LIMIT:-100}"
}

# the ollama module owns the daemon + the _ollama_cli sandbox wrapper; reuse
# it instead of duplicating user/ HOME/ OLLAMA_HOST handling
hfmodels_load_ollama() {
  [[ -f "${KCV_MODULES_DIR}/ollama.sh" ]] || die "ollama module missing - run: korvarix-cluster.sh ollama install"
  # shellcheck disable=SC1091  # cached module path
  source "${KCV_MODULES_DIR}/ollama.sh"
  local dir
  dir="$(state_get ollama_dir)"
  [[ -n "$dir" && -x "$dir/bin/ollama" ]] || die "ollama not installed - run: korvarix-cluster.sh ollama install"
}

_hf_api() { curl -fsSL --retry 3 --max-time 90 "$HF_API$1"; }

# HF search with URL-encoded query (model ids contain "/")
_hf_search() {
  curl -fsSL --retry 3 --max-time 90 -G "$HF_API/models" \
    --data-urlencode "search=$1" \
    --data-urlencode "sort=trendingScore" \
    --data-urlencode "limit=5"
}

hf_safe() { tr -c 'A-Za-z0-9' '_' <<<"$1"; }

hfmodels_disk_free_gb() {
  local path="$1"
  df -BG --output=avail "$path" 2>/dev/null | tail -1 | tr -dc '0-9'
}

# resolve the GGUF repo for a model: the repo itself if it ships gguf tags,
# else <org>/<name>-GGUF, then unsloth/<name>-GGUF, then the top-trending
# "-GGUF" quantization of it. Echoes repo id or empty.
# Probe before search: HF search ranking sometimes puts a random mirror
# (DevQuasar etc.) above the canonical unsloth/vendor upload.
hfmodels_find_gguf() {
  local id="$1" cand tags_json base
  tags_json="$(_hf_api "/models/$id" 2>/dev/null | jq -c '{tags: (.tags // []), lib: (.library_name // "")}' 2>/dev/null)" || return 0
  if jq -e '.tags | index("gguf")' >/dev/null 2>&1 <<<"$tags_json"; then
    echo "$id"; return 0
  fi
  base="${id#*/}"
  for cand in "$id-GGUF" "unsloth/$base-GGUF"; do
    # 200 = exists; 401/404 = gated or absent - move on
    curl -fsS -o /dev/null --max-time 30 "$HF_API/models/$cand" 2>/dev/null && { echo "$cand"; return 0; }
  done
  cand="$(_hf_search "$id-GGUF" 2>/dev/null | jq -r '[.[] | select((.id | endswith("-GGUF")) or ((.tags // []) | index("gguf")))][0].id // empty' 2>/dev/null)" || return 0
  echo "$cand"
}

# pick the largest-quality quant from HF_QUANT_CHAIN whose total download
# (shards summed from the repo tree) fits the size budget. Echoes
# "<quant> <total_bytes>" or empty when nothing fits / exists.
hfmodels_pick_quant() {
  local repo="$1" budget
  budget="$(awk -v g="$HF_MAX_MODEL_GB" 'BEGIN{printf "%.0f", g*1024*1024*1024}')"
  local tree q total
  tree="$(_hf_api "/models/$repo/tree/main" 2>/dev/null)" || return 0
  [[ -n "$tree" ]] || return 0
  for q in $HF_QUANT_CHAIN; do
    # jq test(): no shell->awk regex escaping pitfalls; end-anchored so quants
    # sharded into subfolders match too (Name-Q4_K_M.gguf, ...-00001-of-00002.gguf)
    total="$(jq -r --arg q "$q" --argjson budget "$budget" \
      '[.[] | select(.type=="file") | select(.path | test("[^/]*-" + $q + "(-[0-9]{5}-of-[0-9]{5})?\\.gguf$")) | ((.lfs.size // .size) // 0)] as $s
       | ($s | add) // 0
       | if . > 0 and . <= $budget then . else empty end' 2>/dev/null <<<"$tree" | head -1)" || total=""
    if [[ -n "$total" && "$total" != "0" ]]; then
      echo "$q $total"; return 0
    fi
  done
  return 0
}

# add the ollama model name to MODELS_ALLOWLIST + HF_TRACKED_MODELS in the
# env file (same sed-or-append pattern the ollama picker uses)
hfmodels_env_add() {
  local name="$1"
  local allow="${MODELS_ALLOWLIST:-}"
  [[ " $allow " == *" $name "* ]] || allow="$allow $name"
  allow="$(xargs <<<"$allow")"
  MODELS_ALLOWLIST="$allow"
  local tracked="${HF_TRACKED_MODELS:-}"
  [[ " $tracked " == *" $name "* ]] || tracked="$tracked $name"
  tracked="$(xargs <<<"$tracked")"
  HF_TRACKED_MODELS="$tracked"
  # sed alone no-ops (exit 0) when the key is absent - grep first, then
  # replace or append; same for the allowlist
  # quote on write: the .env is sourced as shell - an unquoted multi-word
  # value runs the second word as a command (bash: command not found)
  if grep -q '^MODELS_ALLOWLIST=' "$KCV_ENV_FILE" 2>/dev/null; then
    sed -i "s|^MODELS_ALLOWLIST=.*|MODELS_ALLOWLIST=\"$allow\"|" "$KCV_ENV_FILE"
  else
    printf 'MODELS_ALLOWLIST="%s"\n' "$allow" >> "$KCV_ENV_FILE"
  fi
  if grep -q '^HF_TRACKED_MODELS=' "$KCV_ENV_FILE" 2>/dev/null; then
    sed -i "s|^HF_TRACKED_MODELS=.*|HF_TRACKED_MODELS=\"$tracked\"|" "$KCV_ENV_FILE"
  else
    printf 'HF_TRACKED_MODELS="%s"\n' "$tracked" >> "$KCV_ENV_FILE"
  fi
  # re-source so later calls in this run see the new values
  set -a
  # shellcheck disable=SC1090
  source "$KCV_ENV_FILE"
  set +a
}

# family = the upstream base model (from the gguf repo's base_model tag);
# one family + one org per node is what "competitive coverage" means here
hfmodels_family_of() {
  local repo="$1"
  _hf_api "/models/$repo" 2>/dev/null | jq -r '
    .tags // [] | map(select(startswith("base_model:"))) | if length > 0
    then .[0] | sub("^base_model:quantized:"; "") | sub("^base_model:"; "")
    else empty end' 2>/dev/null
}

hfmodels_org_of() { printf '%s' "${1%%/*}"; }

# pull one gguf repo at the best fitting quant; records sha + family in state,
# env-registers it, and echoes the ollama model name on success
hfmodels_pull_repo() {
  local repo="$1" quiet="${2:-}"
  local pick quant bytes gb name sha family
  pick="$(hfmodels_pick_quant "$repo")"
  if [[ -z "$pick" ]]; then
    [[ "$quiet" != "1" ]] && warn "hf: no quant within ${HF_MAX_MODEL_GB}GB budget for $repo - skipped" >&2
    return 1
  fi
  read -r quant bytes <<<"$pick"
  gb="$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b/1073741824}')"
  local free
  free="$(hfmodels_disk_free_gb "${OLLAMA_MODELS:-$(state_get ollama_dir)/models}")"
  # awk not (( )): gb is a float, bash arithmetic dies on it
  if ! awk -v f="$free" -v g="$gb" -v m="$HF_MIN_FREE_GB" 'BEGIN{exit !(f-g >= m)}'; then
    [[ "$quiet" != "1" ]] && warn "hf: $repo needs ~${gb}GB, only ${free:-0}GB free (keep ${HF_MIN_FREE_GB}GB) - skipped" >&2
    return 1
  fi
  name="hf.co/$repo:$quant"
  # log/ok/warn AND the pull progress to stderr: callers capture this
  # function's stdout as the name; ollama's progress bar would end up in it
  log "hf: pulling $name (~${gb}GB)" >&2
  if ! _ollama_cli "$(state_get ollama_dir)" pull "$name" >&2; then
    warn "hf: pull failed: $name" >&2
    return 1
  fi
  sha="$(_hf_api "/models/$repo" 2>/dev/null | jq -r '.sha // "unknown"' 2>/dev/null)"
  state_set "hfsha_$(hf_safe "$name")" "$sha"
  family="$(hfmodels_family_of "$repo")"
  # value = the raw family id ("Org/Name") - the daily org-coverage check
  # awk-matches its first path component against the candidate's org
  [[ -n "$family" ]] && state_set "hffamily_$(hf_safe "$family")" "$family"
  hfmodels_env_add "$name"
  ok "hf: installed $name (upstream sha ${sha:0:12})" >&2
  echo "$name"
}

# trending board, newest per company: same signal as the vllm+base+trending
# page. Shows GGUF availability so you know what is adoptable right now.
hfmodels_trending() {
  dep_ensure "curl:curl" "jq:jq"
  log "hf trending - newest model per company (limit $HF_DISCOVER_LIMIT)"
  local entries seen="" line id ts likes dls repo orgid
  entries="$(_hf_api "/models?sort=trendingScore&limit=$HF_DISCOVER_LIMIT" 2>/dev/null)" \
    || die "cannot reach $HF_API - check network"
  printf ' %-36s %-20s %-7s %-7s %-9s %s\n' "MODEL" "ORG" "SCORE" "LIKES" "DOWNLOADS" "GGUF"
  while IFS=$'\t' read -r id ts likes dls; do
    [[ -n "$id" ]] || continue
    orgid="$(hfmodels_org_of "$id")"
    [[ " $seen " == *" $orgid "* ]] && continue
    seen="$seen $orgid"
    repo="$(hfmodels_find_gguf "$id")"
    line="-"; [[ -n "$repo" ]] && line="$repo"
    printf ' %-36s %-20s %-7s %-7s %-9s %s\n' "$id" "$orgid" "$ts" "$likes" "$dls" "$line"
  done < <(jq -r '.[] | select((.pipeline_tag == "text-generation") or (.pipeline_tag == "image-text-to-text")) | [.id, (.trendingScore // 0), (.likes // 0), (.downloads // 0)] | @tsv' <<<"$entries")
  echo
  echo "adopt one:  korvarix-cluster.sh hfmodels add <hf-repo-id>"
}

# manual adoption: base model id or gguf repo id (quant picked automatically)
hfmodels_add() {
  require_root
  dep_ensure "curl:curl" "jq:jq"
  hfmodels_load_ollama
  hfmodels_defaults
  local target="${1:-}"
  [[ -n "$target" ]] || die "usage: korvarix-cluster.sh hfmodels add <hf-repo-id>  (e.g. Qwen/Qwen3.8-27B)"
  local repo
  if [[ "$target" == *GGUF* || "$target" == *.gguf ]]; then
    repo="$target"
  else
    log "hf: resolving GGUF quantization for $target"
    repo="$(hfmodels_find_gguf "$target")"
    [[ -n "$repo" ]] || die "no GGUF quantization found for $target (yet) - check back or quantize it yourself"
  fi
  local name
  name="$(hfmodels_pull_repo "$repo")" || die "adoption failed for $repo"
  warn "gate policy not rebuilt - run: korvarix-cluster.sh ollama policy && korvarix-cluster.sh ollama push"
  echo "$name"
}

# freshen tracked models ONLY when upstream changed (sha compare = no wasted
# multi-GB re-pulls), then optionally adopt trending newcomers
hfmodels_daily() {
  require_root
  dep_ensure "curl:curl" "jq:jq"
  hfmodels_load_ollama
  hfmodels_defaults
  local name repo sha prev key
  for name in ${HF_TRACKED_MODELS:-}; do
    repo="${name#hf.co/}"; repo="${repo%%:*}"
    sha="$(_hf_api "/models/$repo" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null)"
    [[ -n "$sha" ]] || { warn "hf: cannot check $repo (api unreachable?) - skipping"; continue; }
    key="hfsha_$(hf_safe "$name")"
    prev="$(state_get "$key")"
    if [[ "$sha" == "$prev" ]]; then continue; fi
    log "hf: upstream changed for $name (${prev:0:12} -> ${sha:0:12})"
    if _ollama_cli "$(state_get ollama_dir)" pull "$name" >> "$KCV_LOG_DIR/hfmodels.log" 2>&1; then
      state_set "$key" "$sha"
      ok "hf: updated $name"
    else
      warn "hf: update pull failed: $name (see $KCV_LOG_DIR/hfmodels.log)"
    fi
  done

  if [[ "$HF_AUTO_DISCOVER" != "1" ]]; then return 0; fi
  # adopt: newest trending model per company we do not serve yet
  local adopted=0 entries
  entries="$(_hf_api "/models?sort=trendingScore&limit=$HF_DISCOVER_LIMIT" 2>/dev/null)" || return 0
  local id org repo name
  while IFS=$'\t' read -r id _ts _likes _dls; do
    (( adopted < HF_MAX_MODELS )) || break
    [[ -n "$id" ]] || continue
    org="$(hfmodels_org_of "$id")"
    [[ " $HF_ORG_BLOCKLIST " == *" $org "* ]] && continue
    # company already on the node? adopted models record their base family
    # id ("Org/Name") as the VALUE of hffamily_* state keys; matching the
    # candidate's org against the family's first path component = exact
    # company comparison (no substring false positives between org names)
    if grep '^hffamily_' "$KCV_STATE_FILE" 2>/dev/null | cut -d= -f2 | \
       awk -F/ -v o="$org" '$1 == o { found=1 } END { exit !found }'; then
      continue
    fi
    repo="$(hfmodels_find_gguf "$id")" || repo=""
    [[ -n "$repo" ]] || continue
    local family
    family="$(hfmodels_family_of "$repo")"
    [[ -n "$family" ]] || continue
    if grep -q "^hffamily_$(hf_safe "$family")=" "$KCV_STATE_FILE" 2>/dev/null; then continue; fi
    log "hf: adopting newest trending model for new company $org: $id"
    if name="$(hfmodels_pull_repo "$repo" 1)"; then
      warn "hf: auto-adopted $name - rebuild policy: korvarix-cluster.sh ollama policy && korvarix-cluster.sh ollama push"
      adopted=$((adopted+1))
    fi
  done < <(jq -r '.[] | select((.pipeline_tag == "text-generation") or (.pipeline_tag == "image-text-to-text")) | [.id, (.trendingScore // 0), (.likes // 0), (.downloads // 0)] | @tsv' <<<"$entries")
  (( adopted == 0 )) || log "hf: daily run complete - $adopted new model(s) adopted"
}

hfmodels_cron_install() {
  require_root
  local station
  station="$(state_get station_path)"
  [[ -n "$station" ]] || die "station path unknown"
  # offset from ollama's 05:23 patch window so the two pull jobs never race
  cron_install "hfmodels-patch" "47 5 * * *" "root $station hfmodels daily >> $KCV_LOG_DIR/hfmodels.log 2>&1"
}

hfmodels_status() {
  hfmodels_defaults
  if ! command -v jq >/dev/null 2>&1; then
    warn "jq missing - run: korvarix-cluster.sh hfmodels add (installs deps) or apt install jq"
  fi
  echo "tracked: ${HF_TRACKED_MODELS:-none}"
  echo "auto-discover: $HF_AUTO_DISCOVER (max ${HF_MAX_MODELS}/run, <=${HF_MAX_MODEL_GB}GB/model, orgs: ${HF_ORG_BLOCKLIST:-none})"
  local name repo sha prev key
  for name in ${HF_TRACKED_MODELS:-}; do
    repo="${name#hf.co/}"; repo="${repo%%:*}"
    key="hfsha_$(hf_safe "$name")"
    prev="$(state_get "$key")"
    sha="$(_hf_api "/models/$repo" 2>/dev/null | jq -r '.sha // "?"' 2>/dev/null)"
    if [[ "$sha" == "$prev" ]]; then
      echo "  up-to-date  $name (${sha:0:12})"
    elif [[ -z "$prev" ]]; then
      echo "  unverified  $name (no recorded upstream sha)"
    else
      echo "  STALE       $name (local ${prev:0:12} != upstream ${sha:0:12} - run: hfmodels daily)"
    fi
  done
}

kcv_module_hfmodels() {
  local action="${1:-menu}"
  case "$action" in
    trending) hfmodels_defaults; hfmodels_trending ;;
    add)      shift || true; hfmodels_defaults; hfmodels_add "$@" ;;
    daily)    hfmodels_daily ;;
    cron)     hfmodels_cron_install ;;
    status)   hfmodels_status ;;
    menu)
      echo "  1) trending board (newest per company)  2) add model  3) run daily job now"
      echo "  4) install daily cron  5) status  0) back"
      local r; read -r -p "select: " r
      case "$r" in
        1) hfmodels_defaults; hfmodels_trending ;;
        2) hfmodels_defaults; hfmodels_add ;;
        3) hfmodels_daily ;;
        4) hfmodels_cron_install ;;
        5) hfmodels_status ;;
        *) : ;;
      esac
      ;;
    *) die "usage: hfmodels trending|add <repo>|daily|cron|status" ;;
  esac
}