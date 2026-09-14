# korvarix-llm-ai — LLM cluster (command station + modules)

AI base for `korvarix-llm` (Open WebUI panel): a pool of VPSes that grows
**one node at a time**, never touching existing storage, wired into the
Open WebUI frontend.

## The baseline (as decided)

| Machine | Spec | Role |
|---|---|---|
| VPN box | 1c / 1GB | OpenVPN hub + CA + SSH jump. Tiny on purpose — it anchors cluster identity across node rebuilds/upgrades |
| node1 (master) | 8c / 128GB / 1TB | llama-server + k3s server + first storage brick |
| node2+ | 8c / 128GB / 1TB | k3s agent + rpc-server + +1 storage brick each. Added **one at a time** |

- **Storage:** GlusterFS **distributed** (RAID 0 semantics). Full raw pool, zero
  parity tax, grows +1 brick per node **online, no wipe, ever**. Tradeoff: no
  redundancy — models are re-downloadable; irreplaceable data (chat logs,
  uploads, configs) is covered by the nightly restic backup.
- **CPU/RAM:** k3s pools them (cluster capacity = sum of nodes; a single
  process still caps at one node's RAM — except LLM inference, below).
- **LLM RAM merge:** llama.cpp **RPC** splits one model's layers across nodes
  proportionally to free RAM. Heterogeneous nodes are fine. Day one: master
  solo (`RPC_PEERS=` empty) — ≤110GB models run at full local speed. As nodes
  join, the merged ceiling grows ~30GB/node (2 nodes ≈ 220GB → Qwen3 235B q4
  territory).
- **Network:** OpenVPN is the **default transport** — k3s, gluster, RPC and
  SSH all ride the tunnel (10.8.0.0/24, static per-node IPs via CCD). 1Gbps
  is the baseline bandwidth tier: token generation doesn't need more; 5Gbps
  only speeds up model loads into RPC and rebalances.
- **Cores:** 8c/node is the value floor for 128GB nodes (token generation is
  memory-bandwidth-bound, not core-bound; more cores only speed prefill).

## Why these choices (one-paragraph physics)

Token generation ≈ memory bandwidth ÷ active model size — cores stop mattering
past ~8. So RAM is the spec that sets the model ceiling, cores are bought
lean, and bandwidth only matters when moving weights (loads, rebalances).
The VPN box exists because VPS resizes change IPs; a $5 anchor box means a
rebuild never breaks cluster identity or the CA.

## Quickstart (the wizard drives everything)

```bash
# 1. Buy the VPN mini-box + first two nodes (KVM! same region! see checklist)
# 2. Upload korvarix-cluster.sh to each machine, then per machine:

./korvarix-cluster.sh            # menu

# On the VPN box:   1) wizard → VPN box
#                   3) VPN management → issue a client for EVERY node
# On node1 (master):1) wizard → First node (walks VPN join → storage → k3s
#                      → llama build+serve → cron; prompts for the .ovpn)
# On each new node: 1) wizard → Additional node (VPN join → pool join →
#                   brick add + rebalance → k3s agent → rpc-server)
#                   (needs the master's k3s token: master menu 2 shows it)
```

Non-interactive entrypoints (what cron and scripts call):

```bash
./korvarix-cluster.sh health     # health check (cron calls this)
./korvarix-cluster.sh backup     # nightly restic backup
./korvarix-cluster.sh update     # refresh modules from the repo (manual)
./korvarix-cluster.sh gluster add-brick <host>   # grow the pool (on master)
./korvarix-cluster.sh vpn issue <name>           # new client cert (on VPN box)
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
modules/{vpn,gluster,k3s,llama,health,backup,status,uninstall,wizard}.sh
```

- Every download is sha256-verified against the manifest; mismatch = refused
- Menu 8 (`update`) is the only thing that refreshes modules
- To change the repo: set `KCV_REPO_URL` (see `.env.example`)

## Publishing modules (you, once)

The repo `Korvarix/install` needs this layout on `main`:

```
install/
└── modules/
    ├── manifest.txt
    ├── lib.sh
    ├── vpn.sh  gluster.sh  k3s.sh  llama.sh
    └── health.sh  backup.sh  status.sh  uninstall.sh  wizard.sh
```

Push `korvarix-llm-ai/modules/*` there as-is. Until the first push, the
station falls back to its local cache — pre-seed a node by copying
`modules/` to `/var/lib/korvarix-cluster/modules/` manually.

## Dependency self-check (every step)

Each module step verifies its own binaries first (e.g. gluster step →
`glusterd`; RPC step → `cmake`/`git`/`g++`), prompts before installing missing
ones via the distro-agnostic installer (apt/dnf/yum/zypper/pacman/apk),
re-verifies after install, and fails loudly with manual instructions if still
missing — nothing half-done, re-runs are safe (idempotent). Network sources
(get.k3s.io, github.com, package repos) are reachability-gated before any
download.

## Daily driving

| Task | Where |
|---|---|
| Add a node (storage + compute) | wizard on the new box → "Additional node" |
| Bigger merged model after adding nodes | master `.env`: append `10.8.0.x:50052` to `RPC_PEERS`, restart llama-server |
| Serve a different model | master menu 4 → set model → start |
| Check cluster health | any box: menu 2 (or `health` for cron-view) |
| View logs | menu 9 (llama/rpc/vpn/k3s/health/backup) |
| Restore data | menu 6 → restore (snapshots listed) |

## Wiring into korvarix-llm (Open WebUI frontend)

On the frontend box (`korvarix-llm/.env`), point at the master:

```
OPENAI_API_BASE_URL=http://<MASTER_VPN_IP or public>:8080/v1
OPENAI_API_KEY=sk-none
```

llama-server binds to 127.0.0.1 by default — put it behind the existing
korvarix-llm nginx/gate pattern (reverse-proxy hop), don't expose the port.

## Model fit (what you can actually run)

| Class | RAM need | 1× 128GB master | +nodes merged |
|---|---|---|---|
| 8–14B (Qwen3, Llama 3.1 8B) | 5–16GB | fast, no RPC | — |
| 32B dense (Qwen3 32B q4) | ~20GB | good | — |
| 70B q4 / q8 | 43–80GB | good (~8–15 tok/s local) | fine |
| **Qwen3 235B-A22B q4 (MoE)** | ~133GB | ❌ | ✅ 2+ nodes (~2–6 tok/s) |
| 405B / DeepSeek 671B | 230GB+ | ❌ | keep adding nodes |

MoE models are the CPU-cluster sweet spot (only active params compute).

## Purchase checklist (before buying a node)

1. `systemd-detect-virt` → must be `kvm`/`qemu` (OpenVZ/LXC = walk away)
2. Same provider + region as the rest; `ping` other nodes < 5ms
3. 1Gbps baseline bandwidth is fine (5Gbps = load-time QoL only)
4. 8c/128GB is the sweet spot; RAM > cores always for LLM inference
5. Disk size is the "decide once" spec (bricks should stay equal-size; the
   +1-node growth path keeps them equal forever)

## Triage

| Symptom | Cause |
|---|---|
| wizard fails at VPN join | wrong .ovpn, or VPN box's udp/1194 closed |
| gluster probe fails | VPN down between nodes (ping 10.8.0.x first) |
| k3s agent NotReady | flannel iface wrong (should be tun0) or token stale |
| rpc-server down | llama.cpp ref mismatch between nodes — rebuild all with same `LLAMA_CPP_REF` |
| model loads but 1/3 the layers | a peer's rpc-server is down — check health on each node |
| tokens very slow with RPC | cross-region latency or a node on different CPU flags |
| disk alerts but pool has space | check brick-local disk vs pool: `df -h /data/brick $GLUSTER_MOUNT` |

## What lives where

```
/etc/korvarix-cluster/korvarix.env   # config (wizard writes it)
/var/lib/korvarix-cluster/state      # runtime state (tokens, VPN IPs, role)
/var/lib/korvarix-cluster/modules/   # cached modules (sha256-verified)
/var/lib/korvarix-cluster/pki/       # VPN CA (VPN box only)
/var/log/korvarix/                   # health/backup logs
/etc/cron.d/korvarix-*               # health 5min, backup nightly
```