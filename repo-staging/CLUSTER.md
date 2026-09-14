# korvarix-llm-ai — LLM cluster (command station + modules)

AI base for `korvarix-llm` (Open WebUI panel): a pool of VPSes that grows
**one RAM donor at a time**, wired into the Open WebUI frontend.

## The baseline (as decided)

| Machine | Spec | Role |
|---|---|---|
| Interface box | 4c / 4GB / 25GB | **WireGuard hub** + SSH jump. Tiny on purpose — it anchors cluster identity across node rebuilds/upgrades. Single point of failure for cluster traffic (health cron watches it) |
| Hub (frontend) | 4c / 8GB / 50GB | korvarix-llm: Open WebUI + SSO gate + nginx. Owns all chat data (OWUI docker volume) |
| node1 (master) | 16c / 128GB / 2TB | llama-server + ollama + ALL models on **local disk** (`/data/models`) |
| node2+ (donors) | 8c / 128GB / 25GB | rpc-server only — pure RAM donors. No storage duties, no models. Added **one at a time** |

- **Storage:** none shared. Models live on the master's own disk — donors never
  touch model files (llama.cpp RPC streams tensor layers to them at load time).
  Models are re-downloadable; irreplaceable data (chat DB, uploads, configs)
  is covered by the nightly restic backup (frontend role includes the OWUI
  data volume).
- **RAM:** merged for inference. llama.cpp **RPC** splits one model's layers
  across nodes proportionally to free RAM. Day one: master solo (`RPC_PEERS=`
  empty) — ≤110GB models run at full local speed. Each donor adds ~110GB:
  2 boxes ≈ 220GB (Qwen3 235B q4), 3 boxes ≈ 330GB (405B q4 territory).
- **Network:** WireGuard is the **only transport** — llama RPC, ollama,
  policy push and SSH all ride the tunnel (10.8.0.0/24, static per-box IPs).
  1Gbps is the baseline bandwidth tier: token generation doesn't need more.
  5Gbps is a deferred, formulaic upgrade (see tiers below).
- **Cores:** 16c on the master (prefill/time-to-first-token scales with cores —
  the one spec donors can never add), 8c floor on donors (decode is
  memory-bandwidth-bound, not core-bound).

## Why these choices (one-paragraph physics)

Token generation ≈ memory bandwidth ÷ active model size — cores stop mattering
past ~8. Prefill, however, is compute-bound and scales with cores, and it is
serialized layer-by-layer across RPC peers — so the master carries the big
core count and donors stay lean. RAM is the spec that sets the model ceiling,
and donors are the only growth axis (VPS specs are frozen at purchase).
Bandwidth only matters when moving weights (model downloads, RPC pushes at
load time) — hence 5Gbps as a deferred tier, not a baseline.

## Deferred upgrades (real prices, on purpose)

Bandwidth is the only spec upgradeable later without touching data — and this
provider prices every tier linearly, so there is no value sweet spot. 1Gbps is
free and sufficient for launch: token streaming is KB/s per user.

| Tier | Lifetime +$/box | Monthly +$/mo | Break-even |
|---|---|---|---|
| 2Gbps | $86.62 | $7.89 | 11.0 mo |
| 3Gbps | $175.17 | $15.94 | 11.0 mo |
| 4Gbps | $263.72 | $23.99 | 11.0 mo |
| 5Gbps | $352.27 | $32.04 | 11.0 mo |

**Chain rule:** an RPC weight push (master → Interface → donor) runs at
min(NICs in the chain) — a fast donor behind a 1Gbps Interface buys nothing.
Donor bandwidth only speeds the donor's OWN pulls (model hosts pulling from
the public CDN). Upgrades are therefore bought in sets, never per-box:

1. **Now:** 1Gbps everywhere (free) — 5-7 clients never feel it
2. **When big-model switch latency annoys:** coordinated 2Gbps on master +
   Interface + hot donors ($86.62 × 3 = $259.86 one-time, ~2× switch speed)
3. **Only by demonstrated need:** step 3-5G, same slope, exact speed bought

## Scaling & budget (rented vs owned)

The provider sells the same SKUs two ways. Lifetime never discounts and never
migrates from a rental (no credit — going lifetime means buying a NEW VPS and
moving in yourself; the station makes that cheap for donors/hosts, painful
only for the Interface, which must never be rented anyway). Monthly SKUs take
term discounts off the FINAL price (base + addons):

| Term | Discount | Effective on final monthly price |
|---|---|---|
| 1mo | 0% | full price |
| 3mo | 10% | e.g. donor $104.33 → $93.90 |
| 6mo | 20% | → $83.46 |
| 1yr | 30% | → $73.03 |
| 2yr | 40% | → $62.60 (never use — see rules) |
| 5yr | 50% | → $52.17 (never — $3,130 total vs $1,099 lifetime) |

Add-on pricing is linear: storage ≈ $0.032/GB/mo from a 25GB base, bandwidth
≈ $8/Gbps/mo. Base-box break-evens vs lifetime: master 10.9 mo, Hub 9.3 mo,
donor 10.5 mo — add-ons 11.0 mo.

### The commitment ladder (elastic capacity only)

1. **Months 0-3, unproven:** month-to-month, cancel anytime. No terms on
   speculation.
2. **Proven ~3 months of continuous need:** re-commit on a **6mo term (20%)**.
3. **Proven ~9-12 months:** 1yr term (30%) — beats lifetime for year one
   ($876 vs $1,099 donor).
4. **Horizon > ~15 months:** buy a NEW lifetime VPS (same spec or better) and
   retire the rental. Never let cumulative rent on one unit exceed its
   lifetime price; never terms beyond 1yr on elastic capacity.

### Donor tiers (rented, monthly, real prices — 8c/128GB base)

| Role | Storage | Total/mo | Use |
|---|---|---|---|
| Pure RPC donor | 25GB | $104.33 | Merged-RAM ceiling only (+~110GB), stores nothing |
| Model host | 100GB | $109.00 | Own ollama, 5-8 small/14B models on disk |
| Heavy host | 200GB | $112.22 | 70B + 32B rotation (~2× its RAM ceiling) |
| Warm standby | 1TB | $137.98 | Half-library mirror + ollama |
| Full mirror | 2TB | $170.18 | Full library copy — can become master if it dies |

Storage addons: +$3.06/50GB, +$4.67/100GB, +$7.89/200GB, +$17.55/500GB,
+$33.65/1TB, +$65.85/2TB (linear ~$0.032/GB/mo, no tier jumps).

### Burst triggers (rent capacity on signal, never on guess)

Rent the next donor the day one of these happens:

1. **Queue delays at peak** (health/status shows streams waiting) → model host
   ($109.00) — adds a whole second ollama instance
2. **A client regularly loads the 235B-class model** → RAM donor ($104.33) +
   `add-peer` (merged ceiling → ~330GB)
3. **Client #5-6 signs** → model host for concurrency

Each is a same-hour action (vpn issue → join → add-peer / ollama subset).
Each rented donor then follows the commitment ladder.

### Rented → owned replacement runbook (per role)

| Role | Replacement effort |
|---|---|
| Donor (RPC) | `vpn issue` on Interface → `vpn join` on new box → master `llama add-peer` → `vpn revoke` old. Minutes. |
| Model host | Same + re-pull its model subset (allowlist drives it) |
| Hub | Reinstall korvarix-llm + restore OWUI volume/config from restic |
| **Interface** | **Never rented** — WG identity/peer state can't migrate; always lifetime |

### Rules & warnings

- `BACKUP_TARGET` is NEVER a rented box (elastic churn must not hold backups)
- "/30 Tage" = per-30-days billing label (German provider); confirm whether
  bandwidth tiers carry a monthly TRAFFIC cap before model-host-heavy renting
- Rented donors convert at the ladder; lifetime is bought only for boxes
  whose identity or data must never churn (Interface, eventually master)

### Budget ladder (master 16c/2TB in every tier — confirmed $2,024.73)

**ACTIVE PLAN: $1,500 — validate cheap, burst on signal.**

| Budget | Own (lifetime) | Rent (monthly) | Day-1 | Burn/mo |
|---|---|---|---|---|
| **$1,500 ← ACTIVE** | Interface $103.04 | Master $186.28 + Hub $18.68 + RAM donor $104.33 | ~$412 | ~$309 |
| $2,500 | Core 3-box $2,301.33 | 1 RAM donor | $2,405.66 | $104.33 |
| $3,000 | Core 3-box $2,301.33 | RAM + model host | $2,514.66 | $213.33 |
| $4,500 | Full 5-box build $4,499.95 | — | $4,499.95 | $0 |
| $5,000 | Full 5-box build | + model host $109.00 | $4,608.95 | $109 |

Lifetime price book (1Gbps): Interface $103.04 · Hub (4c/8GB/50GB) $173.56 ·
Master (16c/128GB/2TB) $2,024.73 · donor (8c/128GB/25GB) $1,099.31 ·
monthly: master $186.28 · Hub $18.68 · donor $104.33.

$1,500 notes: ~3.5 months runway on founding revenue alone ($300-600/mo from
3 clients covers $309 burn); extra donors are bought on the burst triggers
above, never upfront; the master is the rental to convert to lifetime FIRST
(10.9 mo break-even, and the library must not churn).

## Quickstart (the wizard drives everything)

```bash
# 1. Buy the interface mini-box + master + donors (KVM! same region! checklist)
# 2. Upload korvarix-cluster.sh to each machine, then per machine:

./korvarix-cluster.sh            # menu

# On the interface box:  1) wizard → Interface box
#                        3) VPN management → issue a peer for EVERY box
#                           (hub + node1 + each donor + frontend)
# On node1 (master):     1) wizard → First node (walks VPN join → llama build
#                           + rpc → set model + serve → cron)
# On each donor:         1) wizard → Additional node (VPN join → rpc-server;
#                           prints the add-peer command to run on the master)
# On the frontend box:   1) wizard → Frontend box (VPN join → korvarix-llm)
```

Non-interactive entrypoints (what cron and scripts call):

```bash
./korvarix-cluster.sh health     # health check (cron calls this)
./korvarix-cluster.sh backup     # nightly restic backup
./korvarix-cluster.sh update     # refresh modules from the repo (manual)
./korvarix-cluster.sh llama add-peer <vpn-ip>    # register donor (on master)
./korvarix-cluster.sh vpn issue <name>           # new peer config (interface)
./korvarix-cluster.sh llama start|stop|rpc-start|set-model <file>
```

## The module system

`korvarix-cluster.sh` is a thin **command station**: menu, wizard, downloader.
Logic lives in modules fetched from `KCV_REPO_URL` (public GitHub
`Korvarix/install`, `modules/` subfolder, manual update policy — cron never
touches the network; everything runs from cache at
`/var/lib/korvarix-cluster/modules/`).

```
modules/manifest.txt   # name + version + sha256 per module (integrity gate)
modules/lib.sh         # shared engine: deps, prompts, pkg_install, state, cron, fw
modules/{vpn,llama,ollama,health,backup,status,uninstall,wizard}.sh
modules/korvarix-llm.sh  # frontend deploy wrapper
```

- Every download is sha256-verified against the manifest; mismatch = refused
- Menu 8 (`update`) is the only thing that refreshes modules
- To change the repo: set `KCV_REPO_URL` (see `.env.example`)

## Publishing modules (you, once)

The repo `Korvarix/install` needs this layout on `main`:

```
install/
├── modules/                 # station modules (fetched + sha256-verified)
│   ├── manifest.txt
│   ├── lib.sh
│   ├── vpn.sh  llama.sh  ollama.sh
│   └── health.sh  backup.sh  status.sh  uninstall.sh  wizard.sh  korvarix-llm.sh
└── korvarix-llm/            # the deployable frontend folder (menu 11 clones it)
    ├── install.sh  install.ps1  Dockerfile.gate  package.json  README.md
    ├── .env.example         # template ONLY - never commit a real .env
    ├── .gitignore           # blocks .env
    ├── gate/  (Dockerfile, gate.js)
    └── lib/@korvarix/shared/  (env.js)
```

**Secrets rule:** only ever push `.env.example` (values empty). The real `.env`
(lives on the frontend box, holds WEBUI_SECRET_KEY / LLM_SSO_KEY /
OPEN_WEBUI_API_KEY) is blocked by the folder's `.gitignore` — keep it that way.

Push `korvarix-llm-ai/modules/*` and `korvarix-llm/*` (minus real .env) there.
Until the first push, the station falls back to its local cache — pre-seed a
box by copying `modules/` to `/var/lib/korvarix-cluster/modules/` manually.

## Public AI endpoint policy (menu 5: Ollama)

The public-facing API (clients pulling from `llm.korvarix.com`) is governed by
a policy file the station builds from `.env` knobs and pushes to the frontend
gate (`korvarix-policy.json`, checksum-verified, re-read by the gate every 60s).
Four kinds of parameters, all defaults chosen for a legal public posture:

| Kind | Knobs | Behavior |
|---|---|---|
| **Smart request parameters** | `POLICY_MAX_OUT`, `POLICY_TEMP_MAX`, `POLICY_TOPP_MAX`, `POLICY_MAX_CTX`, `POLICY_MAX_PROMPT_CHARS` | Client-supplied sampling params are **clamped down** (never trusted): output token cap, temperature/top-p ceilings, context + prompt-size limits |
| **No-attacking parameters** | `POLICY_RPM_IP`, `POLICY_RPM_KEY`, `POLICY_INFLIGHT_IP`, `POLICY_KEYS_PER_IP_DAY` | Per-IP + per-key rate limits, concurrency caps (streams can't stack into a DoS), key-mint budget per IP/day (slows key farming) |
| **Internet lookup** | `POLICY_WEB_LOOKUP` | `false` = the gate strips tool/web-search fields from every request (model can't fetch third-party content = no legal exposure). `true` = passed through |
| **Kind parameters** | `POLICY_SAFETY_FILTER`, `POLICY_LOCK_SYSTEM_PROMPT` | Safety filter refuses CSAM/weapons/violent-extremism solicitations **before any model sees them** (legal floor for a public service); system-prompt lock drops client system messages so the persona stays yours |

**Model allowlist:** `MODELS_ALLOWLIST` is the ONLY list clients may call.
Everything else gets `403 model_not_allowed` at the gate — clients can call
any model *on the list*, nothing else, and there's no way to add models via
the API (the daily job also prunes non-allowlisted strays).

**Sandboxing:** ollama runs as a dedicated unprivileged user under systemd
hardening (`NoNewPrivileges`, `ProtectSystem=strict`, `PrivateTmp`, kernel
protections) with a hard capacity budget (`OLLAMA_NUM_PARALLEL`,
`OLLAMA_MAX_LOADED`, `OLLAMA_KEEP_ALIVE`). Models live in the sandbox user's
own directory; the daemon cannot write outside its paths.

**Daily patches:** menu 5 → install daily cron runs at 05:23 — re-pulls every
allowlisted model (quant/patch updates land automatically) and prunes anything
not on the list. Manual anytime: `korvarix-cluster.sh ollama daily` (log:
`/var/log/korvarix/ollama-pull.log`).

**Model catalog (menu 5 → 4 "add models (picker)"):** two sections —
- **OFFICIAL** (`ollama.com/library`): vendor-maintained models (Meta, Qwen,
  Google, Microsoft, Mistral, IBM, NVIDIA, DeepSeek, OpenAI's gpt-oss...) —
  only CPU-runnable sizes are listed; `cloud`-tagged builds are excluded
  (they execute on Ollama's servers, not our nodes)
- **COMMUNITY** (`ollama.com/<publisher>/<model>`): fine-tunes/abliterations
  for roleplay, storytelling, and uncensored variants — incl. your
  `oroboros-labs/claude-fable5*` and `claude-sonnet-7-undecillion` picks.
  Community pull sizes are approximate — watch the pull output.

Pick by numbers (`1 8 42`), `all`, `official`, or `community`; the picker
merges into `MODELS_ALLOWLIST`, pulls, and offers to rebuild+push the policy.
Catalog edits: one line per model in `OLLAMA_CATALOG` (top of
`modules/ollama.sh`, format `slug|Label|~N GB RAM|description|O-or-C`).

**Setup flow (master):**
```bash
./korvarix-cluster.sh                # menu
# 5) Ollama:
#   1 install → 2 serve → edit .env MODELS_ALLOWLIST → 3 pull
#   5 build policy → 6 push policy to frontend → 7 install daily cron
```

**One location, many models:** clients always hit the single public endpoint
(`llm.korvarix.com`). The frontend's Open WebUI **merges** every connected
backend into one model list, so adding capacity or models is invisible to
clients — no client config changes ever:

1. Set `MODELS_ALLOWLIST="model1 model2 model3"` in the station `.env`
   (space-separated ollama names, e.g. `qwen2.5:7b llama3.1:8b mistral-nemo`)
2. Menu 5: `3` pull (downloads all of them)
3. Set `OLLAMA_BIND=<NODE_VPN_IP>` (e.g. `10.8.0.11`) so the daemon is
   reachable over the VPN — never a public IP
4. The frontend wizard auto-wires the frontend's `korvarix-llm/.env`:
   `OLLAMA_BASE_URL=http://<MASTER_VPN_IP>:11434` — or re-run
   `./install.sh` after setting it manually
5. Menu 5: `5` build policy → `6` push (the gate now guards all of them)

More models later = add to `MODELS_ALLOWLIST` → `3` pull → `5`+`6`. More
capacity later = buy a donor, run its wizard, then on the master:
`llama add-peer <its-vpn-ip>` (one command; RAM merges, models don't move).

**Legal notes for a public endpoint:** the combination above (allowlist-only
models, clamped params, rate limits, pre-model refusal of illegal-content
solicitations, entitlement-checked keys) is the standard reasonable-care
posture. It does not make you immune — keep the ToS updated to cover AI
output, log refusals (they're evidence of enforcement), and review the
blocklist if your jurisdiction requires more.

## External API (the provider surface: /v1)

Clients authenticate with an OWUI API key (Settings → Account → API Keys):

```
Base URL: https://llm.korvarix.com/v1     # /api/v1 also accepted
API key:  sk-...
```

The **gate enforces the full policy on both paths** (browser panel AND API
key): allowlist, RPM/IP + RPM/key, in-flight cap, param clamps, safety
filter, refusal logging. `GET /v1/models` returns ONLY allowlisted models.
Key validation = OWUI probe (owner email) → subscription re-check via the
base site's `/api/sso/llm/entitlement` (cached 5 min) — API access dies with
the subscription exactly like panel access.

**Usage visibility (menu 12: report)** — the gate appends one JSONL line per
completion + refusal to `/var/log/korvarix/llm-usage.jsonl` on the frontend
box; the station's `report` module rsyncs it nightly, aggregates per-user /
per-model / totals, posts a one-line summary to `HEALTH_WEBHOOK`, and writes
the full breakdown to `/var/log/korvarix/usage-report.log`. Observation only
— unlimited plans are bounded by the policy clamps, not token budgets.

Launch policy defaults (coding-first): `POLICY_MAX_CTX=32768`,
`POLICY_MAX_OUT=8192`, `POLICY_RPM_KEY=60`, `POLICY_INFLIGHT_IP=2`,
`POLICY_MAX_PROMPT_CHARS=128000`.

## Dependency self-check (every step)

Each module step verifies its own binaries first (e.g. llama build →
`cmake`/`git`/`g++`), prompts before installing missing ones via the
distro-agnostic installer (apt/dnf/yum/zypper/pacman/apk), re-verifies after
install, and fails loudly with manual instructions if still missing — nothing
half-done, re-runs are safe (idempotent). Network sources (github.com,
ollama.com, package repos) are reachability-gated before any download.

## Daily driving

| Task | Where |
|---|---|
| Add a RAM donor | wizard on the new box → "Additional node", then on master: `llama add-peer <vpn-ip>` |
| Bigger merged model after adding donors | master `.env` RPC_PEERS grows automatically via add-peer; restart llama-server |
| Serve a different model | master menu 4 → set model → start |
| Check cluster health | any box: menu 2 (or `health` for cron-view) |
| Peer status (merged-RAM donors) | master menu 4 → 8 (or `llama peers`) |
| View logs | menu 9 (llama/rpc/wireguard/ollama/health/backup) |
| Restore data | menu 6 → restore (snapshots listed) |

## Wiring into korvarix-llm (Open WebUI frontend)

**Menu 11 / wizard role 4 (recommended)** — run the station on the frontend
box and pick `4) Frontend box`. It joins the VPN, clones the korvarix-llm
folder from `Korvarix/install` into `/opt/korvarix-llm`, auto-wires both
model endpoints from the cluster config, then drives the box's own
`install.sh` (`install` → `gate` → `nginx`) with `check` after each step.

**Manual** — deploy `korvarix-llm/install.sh` yourself, then in its `.env`:

```
OPENAI_API_BASE_URL=http://<MASTER_VPN_IP>:8080/v1
OPENAI_API_KEY=sk-none
OLLAMA_BASE_URL=http://<MASTER_VPN_IP>:11434
```

llama-server binds to the master's VPN IP (`LLAMA_BIND`) — reachable only over
the tunnel, never a public IP. All frontend secrets (SSO keys, OWUI API key)
stay in the frontend box's `korvarix-llm/.env` — the cluster never needs them.

## Model fit (what you can actually run)

| Class | RAM need | 1× 128GB master | +donors merged |
|---|---|---|---|
| 8–14B (Qwen3, Llama 3.1 8B) | 5–16GB | fast, no RPC | — |
| 32B dense (Qwen3 32B q4) | ~20GB | good | — |
| 70B q4 / q8 | 43–80GB | good (~8–15 tok/s local) | fine |
| **Qwen3 235B-A22B q4 (MoE)** | ~133GB | ❌ | ✅ 2 boxes ~2–6 tok/s; 3 boxes ~3–8 |
| Llama 3.1 405B q4 | ~231GB | ❌ | ✅ 3 boxes (~330GB) |
| DeepSeek 671B q4 | ~404GB | ❌ | needs a 4th donor |

MoE models are the CPU-cluster sweet spot (only active params compute).
Each donor adds ~110GB merged RAM. Decode speed scales with donors (memory
bandwidth pools); prefill does not (compute-bound, serialized per layer —
that's why the master carries 16c).

## Purchase checklist (before buying a box)

1. `systemd-detect-virt` → must be `kvm`/`qemu` (OpenVZ/LXC = walk away —
   WireGuard and the plain-systemd services need a real kernel)
2. Same provider + region as the rest; `ping` other boxes < 5ms
3. 1Gbps baseline bandwidth is fine (see "Deferred upgrades" ladder — rented
   donors can add bandwidth tiers monthly and convert later; never per-box
   alone: the chain rule governs)
4. Master: 16c/128GB + storage for the whole model library (2TB here);
   donors: 8c/128GB + minimum storage (25GB — they hold no models). On the
   rental path donors can be model hosts instead (100GB+, see donor tiers)
5. RAM ceiling per box is 128GB → donors are the ONLY growth path for the
   merged model ceiling. Cores: 16c master is a buy-now item (donors can
   never add prefill speed to the pool)
6. Lifetime is never discounted and never migrates from a rental — buy
   lifetime only for identity/data boxes; rent everything elastic and follow
   the commitment ladder (Scaling & budget section)

## Triage

| Symptom | Cause |
|---|---|
| wizard fails at VPN join | wrong peer .conf, or interface box's udp/51820 closed |
| master unreachable from donor | WG handshake down — `wg show` on both, check endpoint |
| rpc-server down | llama.cpp ref mismatch between nodes — rebuild all with same `LLAMA_CPP_REF` |
| model loads but 1/3 the layers | a peer's rpc-server is down — master menu 4 → 8 (or `llama peers`) |
| tokens very slow with RPC | cross-region latency or a node on different CPU flags |
| frontend can't reach llama-server | LLAMA_BIND not set to master's VPN IP, or WG down |
| policy push fails | FRONTEND_VPN_IP not set (or frontend not joined to the VPN) |
| disk alerts but models dir is small | ollama pull churn — check `ollama list` + prune via menu 5 |

## What lives where

```
/etc/korvarix-cluster/korvarix.env   # config (wizard writes it)
/var/lib/korvarix-cluster/state      # runtime state (WG IPs, peers, role)
/var/lib/korvarix-cluster/modules/   # cached modules (sha256-verified)
/var/lib/korvarix-cluster/wireguard/ # peer configs + private keys (interface box)
/etc/wireguard/korvarix-hub.conf     # WG hub config (interface box)
/etc/wireguard/korvarix.conf         # WG peer config (every other box)
/data/models                         # master-local model library
/var/log/korvarix/                   # health/backup logs
/etc/cron.d/korvarix-*               # health 5min, backup nightly, ollama daily
```