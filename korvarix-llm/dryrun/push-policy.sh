#!/usr/bin/env bash
# push-policy.sh — install the dry-run policy on the server (run ON THE SERVER).
# You upload korvarix-policy.json anywhere (e.g. /root or /tmp), then run this
# script: it normalizes line endings, computes the sha256 sidecar where the
# file lands (byte-exact), and installs both into /etc/korvarix-llm/.
# The gate hot-reloads within 60s — no container restart needed.
#
# Usage:  ./push-policy.sh [path-to-korvarix-policy.json]
#         (default: korvarix-policy.json next to this script)

set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")" && pwd)/korvarix-policy.json}"
DEST_DIR="/etc/korvarix-llm"

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok \033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mfail\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$SRC" ]] || die "policy file not found: $SRC (upload it first, or pass its path)"
[[ $EUID -eq 0 ]] || die "run as root (sudo)"

# sanity: the JSON must parse and carry at least one model
command -v python3 >/dev/null 2>&1 || command -v jq >/dev/null 2>&1 || true
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; d=json.load(open('$SRC')); assert d.get('models'), 'empty models list'" \
    || die "korvarix-policy.json is not valid JSON (or has an empty models list)"
fi

mkdir -p "$DEST_DIR"

# normalize: strip CR (Windows uploads), write final copy
# perms 644: the gate container runs as the non-root "node" user — 640 would
# leave the file root-only and the gate would report "no policy file"
tr -d '\r' < "$SRC" > "${DEST_DIR}/korvarix-policy.json"
chmod 644 "${DEST_DIR}/korvarix-policy.json"

# compute the checksum HERE (where the gate will read it) — byte-exact by construction
sha256sum "${DEST_DIR}/korvarix-policy.json" | awk '{print $1}' > "${DEST_DIR}/korvarix-policy.json.sha256"
chmod 644 "${DEST_DIR}/korvarix-policy.json.sha256"

# usage-log dir: the gate (uid 1000 = "node" in node:22-alpine) appends to it
mkdir -p /var/log/korvarix
chown -R 1000:1000 /var/log/korvarix 2>/dev/null || chmod 777 /var/log/korvarix

SUM="$(cat "${DEST_DIR}/korvarix-policy.json.sha256")"
log "installed: ${DEST_DIR}/korvarix-policy.json"
ok "sha256: ${SUM:0:16}..."

# verify the gate can actually read the path (mount check)
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^korvarix-llm-gate$'; then
  if docker exec korvarix-llm-gate test -r /etc/korvarix-llm/korvarix-policy.json 2>/dev/null; then
    ok "gate container can read the policy (mount verified)"
  else
    log "WARNING: gate container cannot see /etc/korvarix-llm/korvarix-policy.json"
    log "  check the mount:  docker inspect korvarix-llm-gate --format '{{json .Mounts}}'"
  fi
  log "watch the flip (60s window):"
  log "  docker logs korvarix-llm-gate --tail 5 -f"
  log "expected:  policy loaded v... (models: 1, rpm/ip=10, web_lookup=false, safety=true)"
else
  log "gate container not running yet — policy is in place for when it starts"
fi