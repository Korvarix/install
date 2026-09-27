#!/usr/bin/env bash
# korvarix LLM frontend updater - adds a slave node's instance URLs to the
# gate's load-balancer list in korvarix-llm/.env.
#
# Behavior:
#   - reads/creates the OLLAMA_NODES line (the gate's variable; the legacy
#     misspelling "OLLAMA_BASE_URLS=" is renamed automatically)
#   - if the node's IP already appears in the list, its entries are REPLACED
#     with a fresh <ip>:<port> range (e.g. after re-running node-setup.sh
#     with a different instance count)
#   - a node whose IP is new gets its 8 URLs appended
#   - --remove strips every URL of that IP (single-node retirement)
#
# Usage (root, on the FRONTEND box, in /opt/korvarix-llm):
#   ./add-node.sh 10.8.0.15            # show what WOULD change (no write)
#   ./add-node.sh 10.8.0.15 --apply    # write .env + recreate gate & OWUI
#   ./add-node.sh 10.8.0.15 --remove --apply
#
# Flags:
#   IP            the slave node's VPN IP (10.8.0.*)
#   --instances N how many ports to add/refresh for this IP   (default: 8)
#   --base-port P first port of the range                     (default: 11430)
#   --remove      delete this IP's URLs instead of adding
#   --apply       actually write .env and re-run the installers
#   (without --apply the script only prints the new list - safe preview)
set -euo pipefail

IP="" INSTANCES=8 BASE_PORT=11430 REMOVE=0 APPLY=0

die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*"; }

[[ $(id -u) -eq 0 ]] || die "run as root"

while (($#)); do
  case "$1" in
    --instances) INSTANCES="$2"; shift 2 ;;
    --base-port) BASE_PORT="$2"; shift 2 ;;
    --remove)    REMOVE=1; shift ;;
    --apply)     APPLY=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) if [[ -z "$IP" && "$1" =~ ^10\.8\.[0-9]+\.[0-9]+$ ]]; then IP="$1"; shift; else die "unknown arg: $1"; fi ;;
  esac
done
[[ -n "$IP" ]] || die "usage: ./add-node.sh <ip> [--instances N] [--base-port P] [--remove] [--apply]"

cd "$(dirname "$0")"
[[ -f .env ]] || die "no .env here - run this from the korvarix-llm folder"

# --- build the IP's URL list ---------------------------------------------------
urls=()
for ((i = 0; i < INSTANCES; i++)); do urls+=("http://$IP:$((BASE_PORT + i))"); done
new_urls="$(IFS=,; echo "${urls[*]}")"

# --- read + normalize the current line -----------------------------------------
# gate reads OLLAMA_NODES; older typo OLLAMA_BASE_URLS is renamed in place
if grep -q '^OLLAMA_BASE_URLS=' .env; then
  sed -i 's/^OLLAMA_BASE_URLS=/OLLAMA_NODES=/' .env
  log "renamed legacy OLLAMA_BASE_URLS= to OLLAMA_NODES= in .env"
fi

current="$(grep -E '^OLLAMA_NODES=' .env 2>/dev/null | head -1 | cut -d= -f2- || true)"
current="${current#${current%%[![:space:]]*}}"   # ltrim
current="${current%${current##*[![:space:]]}}"   # rtrim

# --- merge ----------------------------------------------------------------------
declare -A seen=()
out=""
for u in ${current//,/ }; do
  [[ -n "$u" ]] || continue
  host="$(echo "$u" | cut -d/ -f3 | cut -d: -f1)"
  [[ "$host" == "$IP" ]] && continue   # old entries for this IP are replaced
  [[ -n "${seen[$u]:-}" ]] && continue
  seen["$u"]=1
  out+="${out:+,}$u"
done
if ((REMOVE)); then
  log "removing $IP from OLLAMA_NODES"
else
  out+="${out:+,}$new_urls"
  log "adding $new_urls"
fi

printf '\033[1;36m==>\033[0m new OLLAMA_NODES:\n  OLLAMA_NODES=%s\n' "$out"
if ((REMOVE)) && [[ "$out" == "$current" ]]; then
  warn "IP not present - nothing to change"
  exit 0
fi

if ((!APPLY)); then
  log "dry run only - re-run with --apply to write .env and reload the stack"
  exit 0
fi

# --- write ----------------------------------------------------------------------
if grep -q '^OLLAMA_NODES=' .env; then
  sed -i "s|^OLLAMA_NODES=.*|OLLAMA_NODES=$out|" .env
else
  printf 'OLLAMA_NODES=%s\n' "$out" >> .env
fi
log ".env updated"

# --- reload the stack -------------------------------------------------------------
log "rebuilding gate (bakes OLLAMA_NODES into the container)"
./install.sh gate
log "recreating Open WebUI (dials the gate LB via OLLAMA_BASE_URL)"
./install.sh

# --- verify -----------------------------------------------------------------------
sleep 2
if curl -m 3 -s "http://127.0.0.1:${GATE_LB_PORT:-8212}/api/version" | grep -q version; then
  log "LB on :8212 answers - nodes reachable"
else
  warn "LB :8212 did not answer - check: docker logs korvarix-llm-gate | grep lb"
fi
log "done. node list now:"
grep '^OLLAMA_NODES=' .env