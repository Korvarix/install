// korvarix-llm gate - korvarix.com SSO + entitlement + avatar bridge for
// Open WebUI. Sits between nginx and the Open WebUI container:
//
//   nginx (TLS, llm.korvarix.com) -> THIS (127.0.0.1:8211) -> open-webui (127.0.0.1:8210)
//
// Login flow (mirrors the ModDB SSO pattern):
//   1. user clicks "LLM Panel" on korvarix.com -> POST /api/sso/llm/request
//      (mint gated on the LLM access package / staff) -> redirect to
//      llm.korvarix.com/sso/complete?code=<one-time code>
//   2. this gate fetches the code from the URL and redeems it server-to-server
//      at the base site (POST /api/sso/llm/redeem, shared LLM_SSO_KEY)
//   3. identity is stored in a signed session cookie; all later requests are
//      proxied to Open WebUI with the trusted headers it expects
//      (WEBUI_AUTH_TRUSTED_EMAIL_HEADER / _NAME_HEADER), so Open WebUI
//      auto-provisions the matching account on first sign-in
//   4. avatars: the korvarix avatar URL is synced into Open WebUI's
//      profile_image_url per user - Open WebUI's gravatar fallback is never
//      shown because every provisioned user carries our avatar reference
//
// Zero dependencies (node:crypto HMAC sessions, fetch for upstream calls).
// Run: node gate.js  (env from .env: see install.sh)
import { createServer } from "node:http";
import { createHmac, timingSafeEqual } from "node:crypto";
import { pipeline } from "node:stream/promises";
import { envString, envNumber } from "../lib/@korvarix/shared/env.js";

const PORT = envNumber("GATE_PORT", 8211);
// Open WebUI upstream: "open-webui" hostname inside the docker network when
// the gate runs containerized; 127.0.0.1 when it runs on the host.
// NOTE the port: the container LISTENS on 8080 (its internal port); WEBUI_PORT
// (8210) is only the HOST-published mapping. Container-to-container must use
// the internal port - WEBUI_INTERNAL_PORT covers both run modes.
const WEBUI_HOST = envString("WEBUI_HOST", "127.0.0.1");
const WEBUI_INTERNAL_PORT = envNumber("WEBUI_INTERNAL_PORT", 8080);
const OWUI_BASE = `http://${WEBUI_HOST}:${WEBUI_INTERNAL_PORT}`;
const SITE_URL = envString("SITE_URL", "https://korvarix.com").replace(/\/$/, "");
const PUBLIC_URL = envString("LLM_PUBLIC_URL", "https://llm.korvarix.com").replace(/\/$/, "");
const GATE_KEY = envString("LLM_SSO_KEY", "");
const SESSION_SECRET = envString("WEBUI_SECRET_KEY", "");
const SESSION_TTL_S = envNumber("GATE_SESSION_TTL_S", 30 * 86400);
// logger FIRST: loadPolicy() runs at module init and calls this from its
// catch path - declaring it later would be a TDZ ReferenceError that kills
// the process at boot whenever no policy file exists yet (crash loop).
const log = (...a) => console.log(new Date().toISOString(), "[gate]", ...a);
// Entitlement re-check: on every document load the gate asks the base site
// whether this account still holds LLM access (subscription active / package /
// staff). This is what makes "auto-approve" safe: no manual approval, no fixed
// session wall - access lives exactly as long as the subscription does.
const ENTITLEMENT_CHECK_S = envNumber("GATE_ENTITLEMENT_CHECK_S", 300);
const entitlementCache = new Map(); // email -> {ok, exp, checkAt}
const entCacheMs = ENTITLEMENT_CHECK_S * 1000;

// ---- request policy (built + pushed by the korvarix-cluster station) --------
// /etc/korvarix-llm/korvarix-policy.json + .sha256: model allowlist, rate
// limits, parameter clamps, web-lookup toggle, safety filter. Checksum-
// verified at load; a missing/invalid policy falls back to the BUILT-IN
// defaults below so the gate never runs wide open by accident.
import { readFileSync, existsSync, appendFileSync, mkdirSync, renameSync, statSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname } from "node:path";

const DEFAULT_POLICY = {
  version: 0,
  models: [],
  limits: {
    requests_per_min_per_ip: 10,
    requests_per_min_per_key: 30,
    max_in_flight_per_ip: 2,
    max_context_tokens: 8192,
    max_output_tokens: 2048,
    max_prompt_chars: 32000,
    temperature_max: 1.0,
    top_p_max: 1.0,
    max_keys_per_ip_per_day: 5,
  },
  features: {
    web_lookup: false,
    safety_filter: true,
    system_prompt_locked: false,
  },
};
let POLICY = { ...DEFAULT_POLICY, limits: { ...DEFAULT_POLICY.limits }, features: { ...DEFAULT_POLICY.features } };
// Paths are env-overridable: containerized runs bind-mount /etc/korvarix-llm
// (policy) + a writable usage dir; host runs use the station's real paths.
const POLICY_PATH = envString("KORVARIX_POLICY_PATH", "/etc/korvarix-llm/korvarix-policy.json");
const USAGE_LOG_PATH = envString("KORVARIX_USAGE_LOG", "/var/log/korvarix/llm-usage.jsonl");
const USAGE_LOG_MAX = 50 * 1024 * 1024; // rotate at ~50MB -> .1

function loadPolicy() {
  // self-contained logger: loadPolicy must never depend on declaration order
  const say = (...a) => console.log(new Date().toISOString(), "[gate]", ...a);
  try {
    const p = POLICY_PATH;
    if (!existsSync(p)) throw new Error("no policy file");
    const raw = readFileSync(p, "utf8");
    const want = existsSync(`${p}.sha256`) ? readFileSync(`${p}.sha256`, "utf8").trim() : "";
    const got = createHash("sha256").update(raw).digest("hex");
    if (want && got !== want) throw new Error(`checksum mismatch (want ${want.slice(0, 8)}, got ${got.slice(0, 8)})`);
    const parsed = JSON.parse(raw);
    POLICY = {
      version: Number(parsed.version) || 0,
      models: Array.isArray(parsed.models) ? parsed.models.map(String) : [],
      limits: { ...DEFAULT_POLICY.limits, ...(parsed.limits ?? {}) },
      features: { ...DEFAULT_POLICY.features, ...(parsed.features ?? {}) },
    };
    say(`policy loaded v${POLICY.version} (models: ${POLICY.models.length}, rpm/ip=${POLICY.limits.requests_per_min_per_ip}, web_lookup=${POLICY.features.web_lookup}, safety=${POLICY.features.safety_filter})`);
  } catch (err) {
    POLICY = { ...DEFAULT_POLICY, limits: { ...DEFAULT_POLICY.limits }, features: { ...DEFAULT_POLICY.features } };
    say(`policy NOT loaded (${err?.message ?? err}) - running BUILT-IN defaults (allowlist empty = all model calls refused)`);
  }
}
loadPolicy();
setInterval(loadPolicy, 60 * 1000).unref(); // re-read every minute (cheap) so pushes land without restarts

// ---- rate limiting + in-flight caps + key-per-IP budget --------------------
const rateBuckets = new Map(); // key -> {count, windowStart}
function rateLimitHit(id, limit, windowMs = 60000) {
  const now = Date.now();
  const b = rateBuckets.get(id);
  if (!b || now - b.windowStart > windowMs) {
    rateBuckets.set(id, { count: 1, windowStart: now });
    return true;
  }
  b.count++;
  return b.count <= limit;
}
const inFlight = new Map(); // ip -> count
function inflightBegin(ip, cap) {
  const n = (inFlight.get(ip) ?? 0) + 1;
  if (n > cap) return false;
  inFlight.set(ip, n);
  return true;
}
function inflightEnd(ip) {
  const n = (inFlight.get(ip) ?? 0) - 1;
  if (n <= 0) inFlight.delete(ip);
  else inFlight.set(ip, n);
}
// key-mint budget: OWUI's signup/API-key endpoints, per source IP per day
const keyMintDays = new Map(); // "ip:day" -> count
function keyMintAllowed(ip, maxPerDay) {
  const day = new Date().toISOString().slice(0, 10);
  const k = `${ip}:${day}`;
  const n = (keyMintDays.get(k) ?? 0) + 1;
  keyMintDays.set(k, n);
  if (keyMintDays.size > 5000) {
    const cutoff = new Date(Date.now() - 86400_000).toISOString().slice(0, 10);
    for (const kk of keyMintDays.keys()) if (kk.endsWith(cutoff)) keyMintDays.delete(kk);
  }
  return n <= maxPerDay;
}

// ---- safety filter (pre-model blocklist) ------------------------------------
// Coarse, high-precision patterns only - this is a LEGAL floor for a public
// endpoint (refuse CSAM and violent-extremism solicitation outright), not a
// general content judge. Blocks the REQUEST before any model sees it; the
// model-side guardrails remain the model's own alignment.
const BLOCKLIST = [
  /\b(?:csam|child\s*(?:porn|sexual|sex)\w*|preteen\s*(?:nude|sex|porn)|loli(?:con)?\s*(?:porn|sex)|shota)\b/i,
  /\b(?:how\s+to\s+(?:build|make|construct)\s+(?:a\s+)?(?:bomb|explosive|ied)|pipe\s*bomb\s*(?:instructions|tutorial))\b/i,
  /\b(?:mass\s*shooting\s*(?:plan|guide)|how\s+to\s+commit\s+(?:a\s+)?(?:terror(?:ism|ist)\s*attack))\b/i,
  /\b(?:synthesize|manufacture)\s+(?:sarin|vx|anthrax|ricin|nerve\s*agent)\b/i,
];
function safetyBlocked(text) {
  if (!POLICY.features.safety_filter) return false;
  if (typeof text !== "string") return false;
  return BLOCKLIST.some((re) => re.test(text));
}
// walk the OpenAI message array
function messagesText(body) {
  try {
    const arr = body?.messages;
    if (Array.isArray(arr)) return arr.map((m) => (typeof m?.content === "string" ? m.content : "")).join("\n");
  } catch {}
  return "";
}

// ---- usage + refusal log (JSONL; the nightly report module aggregates it) ---
// One line per completed/failed completion call + every policy refusal:
//   {ts, kind, subject, via, model, pt, ct, status, reason}
// subject = email (api-key + panel flows) | ip (anonymous/asset) ; never the
// raw key. Rotates at USAGE_LOG_MAX to keep the disk flat.
let usageOpen = false;
function usageRotate() {
  try {
    if (existsSync(USAGE_LOG_PATH) && statSync(USAGE_LOG_PATH).size > USAGE_LOG_MAX) {
      renameSync(USAGE_LOG_PATH, `${USAGE_LOG_PATH}.1`);
    }
  } catch {}
}
function usageLog(entry) {
  if (usageOpen) return;
  try {
    mkdirSync(dirname(USAGE_LOG_PATH), { recursive: true });
    usageRotate();
    appendFileSync(USAGE_LOG_PATH, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n");
  } catch (err) {
    usageOpen = true; // logging must never break serving; retry on next policy reload
    log(`usage log disabled (${err?.message ?? err}) - re-enabling on next policy reload`);
    setTimeout(() => { usageOpen = false; }, 60 * 1000).unref();
  }
}
// completion endpoints whose bodies carry model + usage semantics
const COMPLETION_RE = /\/(chat\/completions|completions|generate|api\/generate|api\/chat)$/;
const isCompletionPath = (p) => COMPLETION_RE.test(p);

// ---- models auto-discovery ---------------------------------------------------
// OpenAI-compatible clients (opencode, Continue.dev, Aider, ...) probe
// GET /v1/models before a key is even configured. The allowlist is the single
// source of truth for what any client may call, so the gate can answer this
// itself - no OWUI round-trip, no session required.
const MODELS_LIST_RE = /^\/(?:v1|api\/v1|ollama\/api)\/models$/;
function modelsListBody() {
  return JSON.stringify({ object: "list", data: POLICY.models.map((m) => ({ id: m, object: "model", owned_by: "korvarix" })) });
}
function isModelsListPath(p) {
  return MODELS_LIST_RE.test(p);
}

// ---- parameter clamps --------------------------------------------------------
// NEVER trust client-supplied sampling parameters on a public endpoint: every
// numeric knob is clamped to the policy upper bound (rewritten down, never up)
function clampParams(body) {
  const L = POLICY.limits;
  const out = { ...body };
  if (out.max_tokens != null) out.max_tokens = Math.max(1, Math.min(Math.floor(Number(out.max_tokens) || L.max_output_tokens), L.max_output_tokens));
  else out.max_tokens = L.max_output_tokens;
  if (out.max_completion_tokens !== undefined) out.max_completion_tokens = out.max_tokens;
  if (out.temperature !== undefined && out.temperature !== null) out.temperature = Math.min(Number(out.temperature) || 0, L.temperature_max);
  if (out.top_p !== undefined && out.top_p !== null) out.top_p = Math.min(Number(out.top_p) || 1, L.top_p_max);
  if (typeof out.prompt === "string") out.prompt = out.prompt.slice(0, L.max_prompt_chars);
  if (Array.isArray(out.messages)) {
    // system prompt lock: drop client-supplied system messages when enabled
    if (POLICY.features.system_prompt_locked) out.messages = out.messages.filter((m) => m?.role !== "system");
    let budget = L.max_prompt_chars;
    out.messages = out.messages.map((m) => {
      if (typeof m?.content !== "string") return m;
      const cut = m.content.slice(0, Math.max(0, budget));
      budget -= m.content.length;
      return { ...m, content: cut };
    });
  }
  // web lookup: strip web-search tool wiring unless the policy enables it
  if (!POLICY.features.web_lookup) {
    delete out.tools;
    delete out.tool_choice;
    delete out.functions;
    delete out.web_search;
    delete out.web_search_options;
    delete out.enable_web_search;
  }
  // n (choices) hard-capped at 1 for capacity safety
  if (out.n !== undefined) out.n = 1;
  // usage accounting: streamed responses only carry a final usage chunk when
  // the request asks for it. Inject include_usage so the gate's tee always
  // sees token counts (OWUI + ollama/OpenAI upstreams honor it; harmless
  // overhead otherwise). Non-streaming bodies carry usage natively.
  if (out.stream === true) {
    out.stream_options = { ...(out.stream_options ?? {}), include_usage: true };
  }
  return out;
}

// ---- plan state (v5 plan split) ----------------------------------------------
// entitlementOk() now returns {ok, plan, commercialRemaining, autoBuy}:
//   residential: unlimited tokens, max 5 distinct client IPs / rolling 30 days
//   commercial:  1B-token pack balance (metered locally, synced each refresh),
//                no IP limit, priority lane (higher in-flight), API-first
// Backward compatible: an old base site returns no plan fields => residential.
const RESIDENTIAL_IP_LIMIT = 5;
const IP_WINDOW_MS = 30 * 86400 * 1000;
// distinct-IP rolling window per account: email -> {ips: Map(ip -> firstSeen),
// snapshot: array for restart survival via the usage log}
const ipWindows = new Map();
const IP_WINDOW_SNAPSHOT_MS = 5 * 60 * 1000;
let lastIpSnapshot = 0;
function ipWindowSnapshotPath() {
  return (USAGE_LOG_PATH.replace(/[^/]*$/, "") || "/var/log/korvarix/") + "ip-windows.json";
}
function ipWindowRecord(email) {
  let rec = ipWindows.get(email);
  if (!rec) {
    rec = { ips: new Map() };
    ipWindows.set(email, rec);
    // restore the 30-day window from the last snapshot (gate restart survival)
    try {
      const raw = readFileSync(ipWindowSnapshotPath(), "utf8");
      const all = JSON.parse(raw);
      const mine = all[email];
      if (mine && Array.isArray(mine)) {
        for (const [ip, ts] of mine) if (Date.now() - ts < IP_WINDOW_MS_30) rec.ips.set(ip, ts);
      }
    } catch {}
  }
  return rec;
}
const IP_WINDOW_MS_30 = IP_WINDOW_MS;
// returns {allowed, count} - true when recording ip stays within the limit
function ipWindowTouch(email, ip) {
  const rec = ipWindowRecord(email);
  const now = Date.now();
  for (const [ip, ts] of rec.ips) if (now - ts >= IP_WINDOW_MS_30) rec.ips.delete(ip);
  if (!rec.ips.has(ip)) {
    if (rec.ips.size >= RESIDENTIAL_IP_LIMIT) {
      persistIpWindows();
      return { allowed: false, count: rec.ips.size };
    }
    rec.ips.set(ip, now);
  }
  if (now - lastIpSnapshot > IP_WINDOW_SNAPSHOT_MS) persistIpWindows();
  return { allowed: true, count: rec.ips.size };
}
function persistIpWindows() {
  lastIpSnapshot = Date.now();
  try {
    mkdirSync(dirname(ipWindowSnapshotPath()), { recursive: true });
    const out = [];
    for (const [email, rec] of ipWindows) {
      out.push([email, [...rec.ips.entries()].filter(([, ts]) => Date.now() - ts < IP_WINDOW_MS_30)]);
    }
    writeFileSync(ipWindowSnapshotPath(), JSON.stringify(out));
  } catch {}
}
setInterval(persistIpWindows, 60 * 1000).unref();

async function entitlementOk(session) {
  const now = Date.now();
  const cached = entitlementCache.get(session.email);
  if (cached && cached.checkAt + entCacheMs > now) return cached.data;
  let data = { ok: false, plan: "residential", commercialRemaining: null, autoBuy: null };
  try {
    // server-to-server probe: POST /api/sso/llm/entitlement with the shared
    // gate key in the BODY (NOT /api/auth/llm-entitlement - that endpoint
    // requires a user JWT; calling it here 401'd on EVERY request, which
    // redirected every user to korvarix.com in a loop = "request canceled")
    const probe = await fetch(`${SITE_URL}/api/sso/llm/entitlement`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ key: GATE_KEY, email: session.email }),
      signal: AbortSignal.timeout(6000),
    });
    if (probe.ok) {
      const payload = await probe.json().catch(() => ({}));
      const p = payload?.data ?? payload ?? {};
      data = {
        ok: true,
        // dedicated stacks: truly unlimited tokens, commercial lane privileges
        plan: p.plan === "dedicated" ? "dedicated" : p.plan === "commercial" ? "commercial" : "residential",
        commercialRemaining: Number.isFinite(Number(p.commercialRemaining)) ? Number(p.commercialRemaining) : null,
        autoBuy: p.autoBuy ?? null,
        dedicated: p.dedicated ?? null,
      };
    }
  } catch (err) {
    // unreachable base site: fail OPEN for grace so an outage doesn't lock out
    // paying users, but cache briefly so a dead base doesn't get hammered
    log(`entitlement probe failed (fail-open grace): ${err?.message ?? err}`);
    data = {
      ok: true,
      plan: cached?.data?.plan ?? "residential",
      commercialRemaining: cached?.data?.commercialRemaining ?? null,
      autoBuy: cached?.data?.autoBuy ?? null,
      dedicated: cached?.data?.dedicated ?? null,
      stale: true,
    };
  }
  entitlementCache.set(session.email, { data, checkAt: now });
  if (entitlementCache.size > 5000) entitlementCache.clear();
  return data;
}
// Open WebUI trusted-header names - MUST match the .env the container runs with
const H_EMAIL = envString("WEBUI_AUTH_TRUSTED_EMAIL_HEADER", "X-Korvarix-Email");
const H_NAME = envString("WEBUI_AUTH_TRUSTED_NAME_HEADER", "X-Korvarix-Name");

if (!GATE_KEY) {
  console.error("[gate] LLM_SSO_KEY is required (shared with korvarix-base) - refusing to start");
  process.exit(1);
}
if (!SESSION_SECRET) {
  console.error("[gate] WEBUI_SECRET_KEY is required (same value Open WebUI runs with) - refusing to start");
  process.exit(1);
}
if (!envString("OPEN_WEBUI_API_KEY", "").trim()) {
  console.error("[gate] OPEN_WEBUI_API_KEY is not set - avatar sync is disabled (create an API key in OWUI: Settings -> Account -> API Keys)");
}

// GATE_TRACE=1: log every proxied request (default: only non-2xx + repairs)
const GATE_TRACE = envString("GATE_TRACE", "") === "1";

// ---- signed session cookie (HMAC, same scheme as the base site tokens) ------
function sign(payload) {
  const body = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const mac = createHmac("sha256", SESSION_SECRET).update(body).digest("base64url");
  return `${body}.${mac}`;
}

function verify(token) {
  if (typeof token !== "string" || !token.includes(".")) return null;
  const [body, mac] = token.split(".");
  const expected = createHmac("sha256", SESSION_SECRET).update(body).digest("base64url");
  const a = Buffer.from(mac ?? "");
  const b = Buffer.from(expected);
  if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    if (typeof payload.exp !== "number" || payload.exp * 1000 < Date.now()) return null;
    return payload;
  } catch {
    return null;
  }
}

function readCookie(req, name) {
  const raw = req.headers.cookie ?? "";
  for (const part of raw.split(";")) {
    const [k, ...v] = part.trim().split("=");
    if (k === name) return decodeURIComponent(v.join("="));
  }
  return null;
}

// ---- korvarix base-site calls ------------------------------------------------
async function redeemCode(code) {
  const res = await fetch(`${SITE_URL}/api/sso/llm/redeem`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ key: GATE_KEY, code }),
    signal: AbortSignal.timeout(10000),
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || data.ok === false) throw new Error(data.error ?? `redeem failed (${res.status})`);
  return data;
}

/** Push the korvarix avatar into the Open WebUI user's profile so the UI shows
 *  OUR avatar (CDN-backed) instead of gravatar. Two mechanisms:
 *  - profile_image_url = the korvarix avatar URL (Open WebUI 302-forwards it
 *    when ENABLE_PROFILE_IMAGE_URL_FORWARDING is on - default), or
 *  - if forwarding is disabled, fetch the bytes here and store a data: URI
 *    (Open WebUI accepts data:image/{png,jpeg,gif,webp};base64 profiles).
 *  Best-effort: failures never block sign-in. */
const AVATAR_PROVISION_RETRIES = 6;
const AVATAR_PROVISION_DELAY_MS = 1500;

// The OWUI account is provisioned BY the trusted-header signin that follows
// this call - so on first sign-in the user row does not exist yet and a single
// lookup always lost the race (avatars silently never set). Poll briefly.
async function findOwuiUser(apiKey, email) {
  for (let attempt = 1; attempt <= AVATAR_PROVISION_RETRIES; attempt++) {
    const users = await fetch(`${OWUI_BASE}/api/v1/users/?page=1`, {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(10000),
    }).then((r) => {
      if (!r.ok) throw new Error(`users list failed (${r.status})`);
      return r.json();
    });
    const target = (users?.users ?? []).find((u) => u.email?.toLowerCase() === email.toLowerCase());
    if (target) return target;
    if (attempt < AVATAR_PROVISION_RETRIES) {
      log(`avatar sync: user not provisioned yet (attempt ${attempt}/${AVATAR_PROVISION_RETRIES}) - retrying`);
      await new Promise((resolve) => setTimeout(resolve, AVATAR_PROVISION_DELAY_MS));
    }
  }
  throw new Error(`provisioned user not found after ${AVATAR_PROVISION_RETRIES} tries (trusted-header signup never completed?)`);
}

// CDN fallback: when the base site's SSO response carries no avatarUrl but the
// account HAS an avatar, the gate constructs the CDN path itself from
// CDN_BASE_URL + userId (same shape the base site emits: /f/avatars/<id>).
// Optional - unused when the base site already embeds the full URL.
const CDN_BASE = envString("CDN_BASE_URL", "").trim().replace(/\/$/, "");

function resolveAvatarUrl(identity) {
  if (identity.avatarUrl) return identity.avatarUrl;
  if (CDN_BASE && (identity.userId ?? identity.id)) {
    return `${CDN_BASE}/f/avatars/${identity.userId ?? identity.id}`;
  }
  return null;
}

async function syncAvatar(identity) {
  try {
    const avatarUrl = resolveAvatarUrl(identity);
    if (!avatarUrl) return; // no avatar anywhere -> OWUI shows initials, fine
    // OWUI **API key** (never the admin password): minted by an admin user in
    // Open WebUI under Settings -> Account -> API Keys (sk-... token)
    const apiKey = envString("OPEN_WEBUI_API_KEY", "").trim();
    if (!apiKey) {
      log("avatar sync skipped: OPEN_WEBUI_API_KEY not set (OWUI admin: Settings -> Account -> API Keys)");
      return;
    }
    const target = await findOwuiUser(apiKey, identity.email);
    const forward = envString("ENABLE_PROFILE_IMAGE_URL_FORWARDING", "true").toLowerCase() === "true";
    const imageUrl = forward
      ? avatarUrl
      : `data:image/png;base64,${Buffer.from(await (await fetch(avatarUrl, { signal: AbortSignal.timeout(10000) })).arrayBuffer()).toString("base64")}`;
    const upd = await fetch(`${OWUI_BASE}/api/v1/users/${target.id}/update`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ profile_image_url: imageUrl }),
      signal: AbortSignal.timeout(10000),
    });
    if (!upd.ok) throw new Error(`profile update failed (${upd.status})`);
    log(`avatar synced for ${identity.email} (${forward ? "url-forward" : "data-uri"})`);
  } catch (err) {
    log(`avatar sync failed for ${identity.email}:`, err?.message ?? err);
  }
}

// ---- proxy helpers ------------------------------------------------------------
// extension -> MIME fallback. Browsers hard-fail module scripts on an empty
// MIME; when an upstream response arrives without a content-type we derive
// one from the path so the SPA always loads (and log the fallback so the
// upstream behavior stays visible in `docker logs korvarix-llm-gate`).
const MIME_BY_EXT = {
  js: "text/javascript",
  mjs: "text/javascript",
  css: "text/css",
  wasm: "application/wasm",
  json: "application/json",
  webmanifest: "application/manifest+json",
  map: "application/json",
  svg: "image/svg+xml",
  png: "image/png",
  jpg: "image/jpeg",
  jpeg: "image/jpeg",
  gif: "image/gif",
  webp: "image/webp",
  avif: "image/avif",
  ico: "image/x-icon",
  html: "text/html; charset=utf-8",
  woff: "font/woff",
  woff2: "font/woff2",
  ttf: "font/ttf",
  otf: "font/otf",
  txt: "text/plain",
  xml: "application/xml",
  pdf: "application/pdf",
  md: "text/markdown",
};

function proxyHeaders(session, extra = {}) {
  return {
    // strip inbound copies of the trusted headers - clients must never set them
    ...Object.fromEntries(Object.entries(extra).filter(([k]) => !k.startsWith("x-korvarix-"))),
    [H_EMAIL]: session.email,
    [H_NAME]: encodeURIComponent(session.name ?? session.email),
    "X-Forwarded-For": "",
  };
}

// ---- API key -> owner email (for external-client passthrough) --------------
// OWUI stores API keys hashed (sha256) per user. The admin API key can list
// users but not reverse a hash, so validation is done BY OWUI itself: probe
// with the key against an authenticated endpoint (/api/v1/auths/ returns the
// caller's own record). Result cached - the probe must never add latency to
// every chat request beyond the cache window.
const apiKeyCache = new Map(); // key -> { email, checkAt }
const API_KEY_CACHE_S = 300;

async function apiKeyOwner(key) {
  if (!key) return null;
  const now = Date.now();
  const cached = apiKeyCache.get(key);
  if (cached && now - cached.checkAt < API_KEY_CACHE_S * 1000) return cached.email;
  let email = null;
  try {
    const probe = await fetch(`${OWUI_BASE}/api/v1/auths/`, {
      headers: { Authorization: `Bearer ${key}` },
      signal: AbortSignal.timeout(8000),
    });
    if (probe.ok) {
      const data = await probe.json().catch(() => ({}));
      email = String(data?.email ?? "") || null;
    }
  } catch (err) {
    log(`api-key probe failed (fail-open): ${err?.message ?? err}`);
    email = cached?.email ?? null; // OWUI unreachable: keep last known owner
  }
  apiKeyCache.set(key, { email, checkAt: now });
  if (apiKeyCache.size > 2000) apiKeyCache.clear();
  return email;
}

// ---- auto-signin: exchange the gate session for an OWUI session cookie -----
// Open WebUI's trusted-header mode signs users in on POST /api/v1/auths/signin
// (the header email overrides whatever credentials the form posts). Without
// this dance the SPA renders its OWN login form after the SSO redirect - so
// on the first document load we perform the signin server-side and relay
// OWUI's token cookie to the browser. From then on the SPA talks to OWUI
// with its own cookie; the gate's trusted headers stay consistent with it.
// NOTE: no accept-encoding is sent here either - undici transparently
// decompresses what it negotiates (gzip/deflate only), so the buffer we
// relay is always plain bytes.
async function owuiAutoSignin(session) {
  const si = await fetch(`${OWUI_BASE}/api/v1/auths/signin`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      [H_EMAIL]: session.email,
      [H_NAME]: encodeURIComponent(session.name ?? session.email),
    },
    body: JSON.stringify({ email: session.email, password: "korvarix-sso" }),
    signal: AbortSignal.timeout(15000),
  });
  if (!si.ok) throw new Error(`signin failed (${si.status})`);
  return (si.headers.getSetCookie?.() ?? []).filter((c) => c.startsWith("token="));
}

// is this request a page load (vs an API call / asset fetch)?
function wantsDocument(req, url) {
  const accept = String(req.headers.accept ?? "");
  return req.method === "GET" && accept.includes("text/html") && !url.pathname.startsWith("/api/");
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", `http://127.0.0.1:${PORT}`);

  // ---- login completion: /sso/complete?code=... ----------------------------
  if (url.pathname === "/sso/complete" && req.method === "GET") {
    const code = (url.searchParams.get("code") ?? "").trim();
    if (!code) {
      res.writeHead(400, { "Content-Type": "text/html" });
      return res.end("<h1>Missing code</h1><p>Launch the panel from korvarix.com - Account menu.</p>");
    }
    try {
      const identity = await redeemCode(code);
      // best-effort avatar sync (before first paint so the UI never shows gravatar)
      await syncAvatar(identity);
      const token = sign({ email: identity.email, name: identity.displayName || identity.email, id: identity.userId, exp: Math.floor(Date.now() / 1000) + SESSION_TTL_S });
      // auto-signin RIGHT HERE: exchange the fresh gate session for the OWUI
      // session cookie now, so the 302 to / carries BOTH cookies. The relay
      // used to happen on the follow-up document load (and still does there
      // as a fallback), but doing it here removes a hop - and makes single
      // request flows (curl -L, some in-app browsers) land fully signed in.
      let signinCookies = [];
      const session = { email: identity.email, name: identity.displayName || identity.email };
      try {
        signinCookies = await owuiAutoSignin(session);
      } catch (err) {
        log(`auto-signin on /sso/complete failed for ${identity.email}:`, err?.message ?? err);
      }
      const cookies = [
        `korvarix_llm=${encodeURIComponent(token)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${SESSION_TTL_S}${PUBLIC_URL.startsWith("https") ? "; Secure" : ""}`,
        ...signinCookies,
      ];
      res.writeHead(302, { "Set-Cookie": cookies, Location: "/" });
      return res.end();
    } catch (err) {
      res.writeHead(403, { "Content-Type": "text/html" });
      return res.end(`<h1>Sign-in failed</h1><p>${String(err?.message ?? err).replace(/[<>&]/g, "")}</p><p><a href="${SITE_URL}">Back to korvarix.com</a></p>`);
    }
  }

  // ---- signout: drop the gate cookie too ------------------------------------
  // (handled in the proxy branch below by clearing the cookie on the response)

  // ---- static assets: proxy WITHOUT a session requirement -------------------
  // /_app/*, /static/*, fonts, favicon, manifest carry no user data and Open
  // WebUI serves them without auth (StaticFiles). Requiring the gate session
  // for them caused the module-script race: requests fired before/without the
  // cookie bounced 302 -> the browser followed into HTML -> "MIME type \"\""
  // failures. Exempting them makes page loads robust; the SPA itself still
  // only becomes functional for signed-in users (its API calls stay gated).
  const ASSET_PREFIXES = ["/_app/", "/static/", "/assets/", "/manifest.json", "/favicon", "/robots.txt"];
  const isStaticAsset = ASSET_PREFIXES.some((p) => url.pathname.startsWith(p));
  const session = verify(readCookie(req, "korvarix_llm") ?? "");

  // ---- /v1/* alias + API-key detection: BEFORE the session wall -------------
  // /v1/*: OpenAI-native tools hardcode the /v1 base path. It has no
  // OWUI-side meaning, so it maps 1:1 onto /api/v1/* before any auth logic.
  if (url.pathname.startsWith("/v1/")) {
    url.pathname = `/api${url.pathname}`;
  } else if (url.pathname === "/v1") {
    url.pathname = "/api/v1";
  }
  const authHeader = String(req.headers.authorization ?? "");
  const isApiKey = authHeader.startsWith("Bearer sk-");
  // guard BOTH API surfaces: OWUI's OpenAI-compatible /api/* AND its native
  // /ollama/api/* proxy (otherwise /ollama/api/generate bypasses the
  // allowlist/rate-limits via a raw Ollama client)
  const isChatApi = url.pathname.startsWith("/api/") || url.pathname.startsWith("/ollama/");
  // models auto-discovery (public): served straight from the policy
  // allowlist, before the session wall. This is what makes unauthenticated
  // client probes return JSON instead of the korvarix.com redirect HTML.
  if (req.method === "GET" && isModelsListPath(url.pathname)) {
    res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
    return res.end(modelsListBody());
  }
  // sessionless asset proxy: no trusted headers can be injected (no identity),
  // forward client cookies as-is (minus the gate cookie) so OWUI sees a
  // signed-in browser's own token cookie when present
  if (!session && isStaticAsset) {
    const chunks0 = [];
    for await (const chunk of req) chunks0.push(chunk);
    const body0 = Buffer.concat(chunks0);
    const h0 = {};
    const bc0 = String(req.headers.cookie ?? "")
      .split(";")
      .map((c) => c.trim())
      .filter((c) => c && !c.startsWith("korvarix_llm="));
    if (bc0.length) h0["cookie"] = bc0.join("; ");
    for (const [k, v] of Object.entries(req.headers)) {
      if (["host", "connection", "content-length", "cookie", "upgrade", "accept-encoding", "x-korvarix-email", "x-korvarix-name"].includes(k)) continue;
      h0[k] = v;
    }
    if (body0.length) h0["content-length"] = String(body0.length);
    try {
      log(`asset (sessionless) ${req.method} ${url.pathname}`);
      const upstream = await fetch(`http://${WEBUI_HOST}:${WEBUI_INTERNAL_PORT}${url.pathname}${url.search}`, {
        method: req.method,
        headers: h0,
        body: ["GET", "HEAD"].includes(req.method) ? undefined : body0,
        signal: AbortSignal.timeout(60000),
        redirect: "manual",
      });
      const rh = {};
      upstream.headers.forEach((v, k) => {
        if (["content-length", "transfer-encoding", "content-encoding", "connection", "content-type"].includes(k)) return;
        rh[k] = v;
      });
      // MIME: FORCED from the file extension for every known type - the gate
      // never trusts the upstream's content-type. This guarantees a correct
      // MIME for all file types regardless of upstream behavior (the "MIME
      // type \"\"" class of failures can no longer occur for static files).
      const ext0 = url.pathname.split(".").pop()?.toLowerCase() ?? "";
      const forcedMime = MIME_BY_EXT[ext0];
      if (forcedMime) {
        rh["content-type"] = forcedMime;
      } else {
        const ct0 = upstream.headers.get("content-type");
        if (ct0) rh["content-type"] = ct0;
      }
      res.writeHead(upstream.status, rh);
      // backpressure-safe copy: res.write() without flow control buffers
      // forever against a slow/dead client (the version.json poll wedge -
      // requests logged but never completing, one wedged every 60s).
      // NOTE: stream/promises.pipeline takes (src, dest[, options]) - NO
      // callback form (that's the callback API in node:stream). The earlier
      // 3-arg call crashed the process on every sessionless asset request.
      if (upstream.body) {
        try {
          await pipeline(upstream.body, res);
        } catch (err) {
          // premature close = client navigated away mid-transfer: normal
          if (err?.code !== "ERR_STREAM_PREMATURE_CLOSE") {
            log(`asset stream error (${upstream.status}): ${err?.code ?? err?.message ?? err}`);
          }
          if (!res.writableEnded) res.end();
        }
      } else if (!res.writableEnded) {
        res.end();
      }
      return;
    } catch (err) {
      log(`asset proxy failed ${url.pathname}: ${err?.message ?? err}`);
      // headers may already be out (mid-stream failure) - never double-write
      if (!res.headersSent) {
        res.writeHead(502, { "Content-Type": "text/plain" });
      }
      if (!res.writableEnded) res.end("asset temporarily unavailable - reload");
      return;
    }
  }

  // ---- API-key passthrough (sessionless external clients: VS Code, curl,
  // python, opencode...) - BEFORE the session wall. OpenAI-compatible clients
  // authenticate with `Authorization: Bearer sk-...` and hold NO gate cookie;
  // previously this branch sat AFTER the session wall, so every sessionless
  // Bearer request was bounced first and the entire passthrough (entitlement,
  // allowlist, metering) was unreachable dead code. API keys minted inside
  // OWUI carry the owner's rights, so we validate the OWNER's entitlement
  // (subscription still active) and then forward byte-for-byte - OWUI
  // enforces the key itself.
  if (isApiKey && isChatApi) {
    // models listing short-circuit: reply from the allowlist without touching
    // OWUI - discovery works even while the panel is warming up, and the list
    // always matches exactly what this gate will let the client call.
    if (isModelsListPath(url.pathname)) {
      res.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      return res.end(modelsListBody());
    }
    const ownerEmail = await apiKeyOwner(authHeader.slice(7).trim());
    if (!ownerEmail) {
      log(`api-key rejected (invalid/expired key) ${req.method} ${url.pathname}`);
      res.writeHead(401, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: { message: "Invalid API key", type: "invalid_request_error", code: "invalid_api_key" } }));
    }
    // subscription gate for API traffic too (cached, same as browser flow).
    // v5: returns {ok, plan, commercialRemaining, autoBuy} for plan-aware checks.
    const ent = await entitlementOk({ email: ownerEmail });
    if (!ent.ok) {
      log(`api-key entitlement refused for ${ownerEmail} ${req.method} ${url.pathname}`);
      res.writeHead(403, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: { message: "Your LLM plan is not active - renew at korvarix.com/store/korvarix-llm-unlimited", type: "subscription_error", code: "plan_inactive" } }));
    }
    const isCommercial = ent.plan === "commercial";
    // dedicated stacks share the commercial lane (priority, no IP window) but
    // skip the token meter entirely - truly unlimited, never capped
    const hasLane = isCommercial || ent.plan === "dedicated";

    // ---- commercial token meter ---------------------------------------------
    // Local counter seeded from the entitlement's commercialRemaining, spent by
    // each completion's measured usage, re-synced at every cache refresh
    // (5 min). 0 = blocked until the balance is restored (auto-buy / new pack).
    const tokenMeter = new Map(); // email -> { remaining, at }
    function tokenBalance(email) {
      const now = Date.now();
      let t = tokenMeter.get(email);
      if (!t || now - t.at > entCacheMs) {
        // fresh refresh cycle: trust the authoritative number when present
        const seeded = ent.commercialRemaining ?? t?.remaining ?? null;
        if (seeded != null) t = { remaining: seeded, at: now };
        tokenMeter.set(email, t ?? { remaining: Number.MAX_SAFE_INTEGER, at: now });
      }
      return tokenMeter.get(email);
    }
    function tokenSpend(email, n) {
      const t = tokenBalance(email);
      if (t.remaining !== Number.MAX_SAFE_INTEGER) t.remaining = Math.max(0, t.remaining - n);
    }
    if (isCommercial) {
      if (ent.commercialRemaining != null && ent.commercialRemaining <= 0) {
        const autoPending = ent.autoBuy?.enabled && ent.commercialRemaining <= (ent.autoBuy?.threshold ?? 0);
        log(`commercial balance empty for ${ownerEmail} (auto-buy ${autoPending ? "pending" : "off"})`);
        res.writeHead(403, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({
          error: {
            message: autoPending
              ? "Token balance exhausted - auto-buy is processing your next 1B pack. Retry in a few minutes."
              : "Token balance exhausted - buy a pack at korvarix.com/store/korvarix-llm-commercial or enable auto-buy in Account.",
            type: "subscription_error",
            code: "token_exhausted",
          },
        }));
      }
      const bal = tokenBalance(ownerEmail);
      if (Number.isFinite(bal.remaining) && bal.remaining <= 0) {
        log(`commercial token meter empty for ${ownerEmail}`);
        res.writeHead(403, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: { message: "Token balance exhausted - your next pack is on its way (auto-buy) or buy one at korvarix.com/store/korvarix-llm-commercial", type: "subscription_error", code: "token_exhausted" } }));
      }
    }

    // ---- policy guardrails (public-endpoint legal posture) -------------------
    // Plan-aware: commercial = priority lane (high in-flight, no IP window);
    // residential = standard caps + the 5-IP/30-day window.
    const L = POLICY.limits;
    const F = POLICY.features;
    const ip = String(req.headers["x-forwarded-for"] ?? "").split(",")[0].trim() || req.socket?.remoteAddress || "unknown";
    const inflightCap = hasLane ? Math.max(8, L.max_in_flight_per_ip) : L.max_in_flight_per_ip;
    const completionCall = /\/(chat\/completions|completions|generate|api\/generate|ollama\/api\/generate)$/.test(url.pathname) || url.pathname.endsWith("/completions");

    // residential IP window: max 5 distinct client IPs per rolling 30 days.
    // Commercial + dedicated accounts skip this entirely (no IP limit).
    if (!hasLane) {
      const win = ipWindowTouch(ownerEmail, ip);
      if (!win.allowed) {
        usageLog({ kind: "refused", subject: ownerEmail, via: "key", model: "", status: 403, reason: "ip_limit" });
        log(`residential ip-limit hit for ${ownerEmail} (${win.count} IPs in the 30-day window)`);
        res.writeHead(403, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: { message: `Your Residential plan allows ${RESIDENTIAL_IP_LIMIT} different IPs per 30 days - this is number ${win.count + 1}. It resets 30 days after each IP's first use. Upgrade to Commercial for unlimited IPs.`, type: "subscription_error", code: "ip_limit" } }));
      }
    }

    // 1. rate limits: per-IP + per-key (sliding 60s windows) - commercial and
    // dedicated get a relaxed per-key RPM (priority lane) with a DoS ceiling
    const rpmKeyLimit = hasLane ? Math.max(600, L.requests_per_min_per_key) : L.requests_per_min_per_key;
    if (!rateLimitHit(`ip:${ip}`, L.requests_per_min_per_ip)) {
      log(`rate-limited (ip) ${ip} ${url.pathname}`);
      res.writeHead(429, { "Content-Type": "application/json", "Retry-After": "30" });
      return res.end(JSON.stringify({ error: { message: "Rate limit exceeded (per IP) - slow down", type: "rate_limit_error", code: "rate_limit_ip" } }));
    }
    if (!rateLimitHit(`key:${authHeader.slice(7, 40)}`, rpmKeyLimit)) {
      log(`rate-limited (key) ${ownerEmail} ${url.pathname}`);
      res.writeHead(429, { "Content-Type": "application/json", "Retry-After": "30" });
      return res.end(JSON.stringify({ error: { message: "Rate limit exceeded (per key) - slow down", type: "rate_limit_error", code: "rate_limit_key" } }));
    }
    // 2. in-flight cap per IP (long streams can't be stacked into a DoS);
    // commercial gets the priority-lane ceiling
    if (completionCall && !inflightBegin(ip, inflightCap)) {
      log(`in-flight cap hit ${ip} (${url.pathname})`);
      res.writeHead(429, { "Content-Type": "application/json", "Retry-After": "20" });
      return res.end(JSON.stringify({ error: { message: "Too many concurrent requests - finish or cancel one first", type: "rate_limit_error", code: "concurrency_limit" } }));
    }

    try {
      // read the body ONCE for policy checks (chat APIs only; others pass raw)
      const apiChunks = [];
      for await (const c of req) apiChunks.push(c);
      let apiBody = Buffer.concat(apiChunks);

      let upstreamBody = apiBody;
      let policyHandled = false;
      let reqModel = "";
      if (completionCall && apiBody.length) {
        let parsed = null;
        try { parsed = JSON.parse(apiBody.toString("utf8")); } catch { parsed = null; }
        if (parsed && typeof parsed === "object") {
          policyHandled = true;
          reqModel = String(parsed.model ?? "");

          // 3. model allowlist: clients may call ONLY listed models
          const wanted = String(parsed.model ?? "");
          if (POLICY.models.length > 0 && !POLICY.models.includes(wanted)) {
            inflightEnd(ip);
            usageLog({ kind: "refused", subject: ownerEmail, via: "key", model: wanted, status: 403, reason: "model_not_allowed" });
            log(`model refused: "${wanted}" not on allowlist (${ownerEmail})`);
            res.writeHead(403, { "Content-Type": "application/json" });
            return res.end(JSON.stringify({ error: { message: `Model "${wanted}" is not available. Allowed: ${POLICY.models.join(", ")}`, type: "invalid_request_error", code: "model_not_allowed" } }));
          }

          // 4. safety filter: refuse before any model sees the request
          if (safetyBlocked(messagesText(parsed)) || safetyBlocked(typeof parsed.prompt === "string" ? parsed.prompt : "")) {
            inflightEnd(ip);
            usageLog({ kind: "refused", subject: ownerEmail, via: "key", model: wanted, status: 400, reason: "content_policy_violation" });
            log(`safety filter refused request (${ownerEmail}, model ${wanted})`);
            res.writeHead(400, { "Content-Type": "application/json" });
            return res.end(JSON.stringify({ error: { message: "This request was refused by the content policy. Korvarix AI is a public service; certain requests are not permitted.", type: "invalid_request_error", code: "content_policy_violation" } }));
          }

          // 5. parameter clamps + web-lookup toggle (rewrite, never trust)
          parsed = clampParams(parsed);
          upstreamBody = Buffer.from(JSON.stringify(parsed), "utf8");
        }
      }

      // forward: never inject trusted headers (API-key requests are NOT the
      // browser session flow) - OWUI's own auth handles the key
      const apiHeaders = {};
      for (const [k, v] of Object.entries(req.headers)) {
        if (["host", "connection", "content-length", "accept-encoding", "upgrade"].includes(k)) continue;
        apiHeaders[k] = v;
      }
      if (upstreamBody.length) apiHeaders["content-length"] = String(upstreamBody.length);
      const upstream = await fetch(`${OWUI_BASE}${url.pathname}${url.search}`, {
        method: req.method,
        headers: apiHeaders,
        body: ["GET", "HEAD"].includes(req.method) ? undefined : upstreamBody,
        signal: AbortSignal.timeout(600000),
        redirect: "manual",
      });
      const rh = {};
      upstream.headers.forEach((v, k) => {
        if (["content-length", "transfer-encoding", "content-encoding", "connection"].includes(k)) return;
        rh[k] = v;
      });
      res.writeHead(upstream.status, rh);
      // usage tap: tee completion responses while relaying, extract the
      // token-usage object (non-stream: top-level "usage"; stream: last
      // data: chunk carrying usage) and append one JSONL line per call.
      // Commercial: the measured tokens also spend the local token meter.
      let usageCaptured = false;
      const captureUsage = (buf) => {
        if (usageCaptured || !isCompletionPath(url.pathname)) return;
        try {
          const text = buf.toString("utf8");
          const matches = [...text.matchAll(/"usage"\s*:\s*\{[^{}]*\}/g)];
          let last = null;
          for (const m of matches) {
            try { last = JSON.parse(`{${m[0]}}`).usage; } catch {}
          }
          if (last && (last.prompt_tokens != null || last.completion_tokens != null)) {
            usageCaptured = true;
            const pt = Number(last.prompt_tokens) || 0;
            const ct = Number(last.completion_tokens) || 0;
            if (isCommercial) tokenSpend(ownerEmail, pt + ct); // dedicated never meters
            usageLog({
              kind: "completion",
              subject: ownerEmail,
              via: "key",
              model: reqModel || "unknown",
              pt,
              ct,
              status: upstream.status,
            });
          }
        } catch {}
      };
      if (upstream.body) {
        const ctype = String(upstream.headers.get("content-type") ?? "");
        if (ctype.includes("event-stream") || ctype.includes("json")) {
          const { Transform } = await import("node:stream");
          const tee = new Transform({
            transform(chunk, _enc, cb) {
              captureUsage(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
              cb(null, chunk);
            },
          });
          try {
            await pipeline(upstream.body, tee, res);
          } catch (err) {
            if (err?.code !== "ERR_STREAM_PREMATURE_CLOSE") {
              log(`api stream error (${upstream.status}): ${err?.code ?? err?.message ?? err}`);
            }
            if (!res.writableEnded) res.end();
          }
        } else {
          try {
            await pipeline(upstream.body, res);
          } catch (err) {
            if (err?.code !== "ERR_STREAM_PREMATURE_CLOSE") {
              log(`api stream error (${upstream.status}): ${err?.code ?? err?.message ?? err}`);
            }
            if (!res.writableEnded) res.end();
          }
        }
      } else if (!res.writableEnded) {
        res.end();
      }
      if (!usageCaptured && isCompletionPath(url.pathname) && upstream.status < 400) {
        // no usage in the response (stream without include_usage etc.): still
        // record the call so request counts stay accurate in the report
        usageLog({ kind: "completion", subject: ownerEmail, via: "key", model: reqModel || "unknown", pt: null, ct: null, status: upstream.status });
      }
      if (GATE_TRACE || upstream.status >= 400) {
        log(`api-key ${req.method} ${url.pathname} -> ${upstream.status} (${ownerEmail})`);
      }
    } catch (err) {
      log(`api-key proxy failed ${url.pathname}: ${err?.message ?? err}`);
      if (!res.headersSent) res.writeHead(502, { "Content-Type": "application/json" });
      if (!res.writableEnded) res.end(JSON.stringify({ error: { message: "Panel temporarily unavailable", type: "api_error" } }));
    } finally {
      if (completionCall) inflightEnd(ip);
    }
    return;
  }

  // ---- session wall: AFTER the API-key passthrough ---------------------------
  // Everything reaching this point is browser/panel traffic. API surfaces must
  // NEVER get the browser redirect: non-browser clients follow 3xx blindly and
  // end up parsing korvarix.com HTML as an API response (the auto-discover
  // bug). They get a parseable OpenAI-style JSON error instead; browsers keep
  // the SSO flow. A 401 here means a malformed/non-sk Bearer token or no auth.
  if (!session && !isStaticAsset) {
    if (url.pathname.startsWith("/api/") || url.pathname.startsWith("/ollama/")) {
      res.writeHead(401, { "Content-Type": "application/json" });
      return res.end(JSON.stringify({ error: { message: "Authentication required", type: "invalid_request_error", code: "invalid_api_key" } }));
    }
    // not signed in. Redirecting to korvarix.com/login?next=<panel> would
    // LOOP: after sign-in the SPA router cannot navigate cross-origin, and
    // even if it could, the gate would bounce again (the SSO mint never ran).
    // Send the visitor to the AUTO-LAUNCH route: if that browser holds a
    // korvarix session it mints the SSO code immediately and hands off; if
    // not, it flows through login and continues the launch automatically.
    res.writeHead(302, { Location: `${SITE_URL}/account/llm-launch?gate=${encodeURIComponent(PUBLIC_URL)}` });
    return res.end();
  }

  // read the full request body (POST/PUT) and forward it
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);

  // ---- panel-branch policy: the browser session gets the SAME guardrails ----
  // (rate limits, allowlist, clamps, safety) so OWUI chat traffic cannot be
  // used to sidestep the API-key branch's policy.
  // v5: panel chats of a COMMERCIAL account also spend the token meter
  // (the panel exists for key minting/balance, but chats draw the same balance).
  const panelIp2 = String(req.headers["x-forwarded-for"] ?? "").split(",")[0].trim() || req.socket?.remoteAddress || "unknown";
  const panelSubject = session?.email ?? panelIp2;
  const panelEnt = session?.email ? await entitlementOk(session) : { ok: false, plan: "residential" };
  const panelIsCommercial = panelEnt.ok && panelEnt.plan === "commercial";
  // dedicated panel sessions: lane RPM, no meter (chats don't draw a balance)
  const panelHasLane = panelIsCommercial || (panelEnt.ok && panelEnt.plan === "dedicated");
  const panelCompletion = isCompletionPath(url.pathname);
  let panelUpstreamBody = body;
  let panelModel = "";
  if (panelCompletion && body.length) {
    const L = POLICY.limits;
    const rpmPanel = panelHasLane ? Math.max(600, L.requests_per_min_per_key) : L.requests_per_min_per_key;
    if (!rateLimitHit(`ip:${panelIp2}`, L.requests_per_min_per_ip)) {
      usageLog({ kind: "refused", subject: panelSubject, via: "panel", model: "", status: 429, reason: "rate_limit_ip" });
      res.writeHead(429, { "Content-Type": "application/json", "Retry-After": "30" });
      return res.end(JSON.stringify({ error: { message: "Rate limit exceeded - slow down", type: "rate_limit_error", code: "rate_limit_ip" } }));
    }
    if (!rateLimitHit(`panel:${panelSubject}`, rpmPanel)) {
      usageLog({ kind: "refused", subject: panelSubject, via: "panel", model: "", status: 429, reason: "rate_limit_user" });
      res.writeHead(429, { "Content-Type": "application/json", "Retry-After": "30" });
      return res.end(JSON.stringify({ error: { message: "Rate limit exceeded - slow down", type: "rate_limit_error", code: "rate_limit_user" } }));
    }
    // commercial: panel chats draw the token balance too
    if (panelIsCommercial && panelEnt.commercialRemaining != null) {
      const bal = tokenBalance(panelSubject);
      if (Number.isFinite(bal.remaining) && bal.remaining <= 0) {
        usageLog({ kind: "refused", subject: panelSubject, via: "panel", model: "", status: 403, reason: "token_exhausted" });
        res.writeHead(403, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: { message: "Token balance exhausted - buy a pack at korvarix.com/store/korvarix-llm-commercial", type: "subscription_error", code: "token_exhausted" } }));
      }
    }
    let parsed = null;
    try { parsed = JSON.parse(body.toString("utf8")); } catch { parsed = null; }
    if (parsed && typeof parsed === "object") {
      panelModel = String(parsed.model ?? "");
      if (POLICY.models.length > 0 && panelModel && !POLICY.models.includes(panelModel)) {
        usageLog({ kind: "refused", subject: session?.email ?? panelIp2, via: "panel", model: panelModel, status: 403, reason: "model_not_allowed" });
        log(`panel model refused: "${panelModel}" (${session?.email ?? panelIp2})`);
        res.writeHead(403, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: { message: `Model "${panelModel}" is not available. Allowed: ${POLICY.models.join(", ")}`, type: "invalid_request_error", code: "model_not_allowed" } }));
      }
      if (safetyBlocked(messagesText(parsed)) || safetyBlocked(typeof parsed.prompt === "string" ? parsed.prompt : "")) {
        usageLog({ kind: "refused", subject: session?.email ?? panelIp2, via: "panel", model: panelModel, status: 400, reason: "content_policy_violation" });
        log(`panel safety filter refused (${session?.email ?? panelIp2}, model ${panelModel})`);
        res.writeHead(400, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ error: { message: "This request was refused by the content policy.", type: "invalid_request_error", code: "content_policy_violation" } }));
      }
      panelUpstreamBody = Buffer.from(JSON.stringify(clampParams(parsed)), "utf8");
    }
  }

  const headers = { ...proxyHeaders(session) };
  // browser cookies ARE forwarded (minus the gate's own) - the SPA needs its
  // OWUI `token` cookie on every request for signed-in state; the trusted
  // headers only cover the signin endpoint, not asset/API auth
  const browserCookies = String(req.headers.cookie ?? "")
    .split(";")
    .map((c) => c.trim())
    .filter((c) => c && !c.startsWith("korvarix_llm="));
  if (browserCookies.length) headers["cookie"] = browserCookies.join("; ");
  for (const [k, v] of Object.entries(req.headers)) {
    // accept-encoding: DO NOT forward the browser's list. The gate fetches with
    // undici, which auto-decompresses what IT negotiates; forwarding the
    // browser's list (zstd/br) can make OWUI answer with an encoding the
    // runtime can't decompress -> raw compressed bytes relayed with the
    // content-encoding header stripped = browser downloads garbage.
    // host/connection/cookie/upgrade are also re-set by the gate itself.
    if (["host", "connection", "content-length", "cookie", "upgrade", "accept-encoding", "x-korvarix-email", "x-korvarix-name"].includes(k)) continue;
    headers[k] = v;
  }
  if (body.length) headers["content-length"] = String(body.length);

  // first document load: make sure the browser's OWUI session is ACTUALLY
  // valid before proxying. A stale token= cookie (issued before a container
  // recreate / secret rotation) makes OWUI render its login page while the
  // gate happily forwards it - so when a token cookie is present we probe
  // /api/v1/auths/ with it and re-sign-in (trusted headers) if it's dead.
  let cookieOverride = null;
  const hasTokenCookie = browserCookies.some((c) => c.startsWith("token="));
  if (wantsDocument(req, url)) {
    // subscription re-check on document loads (auto-approve model): access
    // lives exactly as long as the subscription does - active plan never
    // hits a wall; a missed renewal locks out at the next page load without
    // any admin action. GATE_ENTITLEMENT_CHECK_S caches the answer (5 min).
    // v5: panel IP counts toward the residential 30-day IP window (commercial
    // users keep panel access for key minting + balance - no window applies).
    const panelIp = String(req.headers["x-forwarded-for"] ?? "").split(",")[0].trim() || req.socket?.remoteAddress || "unknown";
    const docEnt = await entitlementOk(session);
    if (!docEnt.ok) {
      log(`entitlement refused for ${session.email} - redirecting to korvarix.com`);
      res.writeHead(302, { Location: `${SITE_URL}/account/llm-launch?gate=${encodeURIComponent(PUBLIC_URL)}&renew=1` });
      return res.end();
    }
    if (docEnt.plan !== "commercial") {
      const win = ipWindowTouch(session.email, panelIp);
      if (!win.allowed) {
        log(`residential ip-limit hit on panel load for ${session.email}`);
        res.writeHead(403, { "Content-Type": "text/html; charset=utf-8" });
        return res.end(
          `<h1>Device limit reached</h1><p>Your Residential plan allows ${RESIDENTIAL_IP_LIMIT} different IPs per 30 days. This network would be number ${win.count + 1}.` +
          ` It resets 30 days after each IP's first use - or <a href="${SITE_URL}/store/korvarix-llm-commercial">upgrade to Commercial</a> for unlimited IPs.</p>`
        );
      }
    }
    // probe with a short budget - it must never hold a page load hostage
    let sessionLive = false;
    if (hasTokenCookie) {
      try {
        const probe = await fetch(`${OWUI_BASE}/api/v1/auths/`, {
          headers: {
            cookie: browserCookies.join("; "),
            [H_EMAIL]: session.email,
            [H_NAME]: encodeURIComponent(session.name ?? session.email),
          },
          signal: AbortSignal.timeout(4000),
        });
        sessionLive = probe.ok;
      } catch {
        sessionLive = false; // probe failed -> assume dead, re-sign-in below
      }
    }
    if (!sessionLive) {
      try {
        const cookies = await owuiAutoSignin(session);
        if (cookies.length) {
          cookieOverride = cookies;
          headers["cookie"] = cookies.map((c) => c.split(";")[0]).join("; ");
        }
      } catch (err) {
        log(`auto-signin failed for ${session.email}:`, err?.message ?? err);
      }
    }
  }

  try {
    // First-byte deadline: document loads (GET with accept: text/html) get a
    // bounded wait so an OWUI hang can never freeze the page silently - the
    // user gets a clean retry page instead of a spinner forever. Assets and
    // API calls keep the long budget (LLM streams run for many minutes).
    const isDoc = wantsDocument(req, url);
    const firstByteS = isDoc ? 30 : 600;
    if (panelUpstreamBody.length) headers["content-length"] = String(panelUpstreamBody.length);
    log(`in-flight ${req.method} ${url.pathname} (first-byte budget ${firstByteS}s)`);
    const upstream = await fetch(`http://${WEBUI_HOST}:${WEBUI_INTERNAL_PORT}${url.pathname}${url.search}`, {
      method: req.method,
      headers,
      body: ["GET", "HEAD"].includes(req.method) ? undefined : panelUpstreamBody,
      signal: AbortSignal.timeout(firstByteS * 1000),
      // DO NOT follow upstream redirects: a followed redirect would swap the
      // asset response for the SPA HTML (wrong content-type / auth bounce).
      // The gate relays 3xx + Location verbatim so the browser handles them.
      redirect: "manual",
    });
    const resHeaders = {};
    upstream.headers.forEach((v, k) => {
      if (["content-length", "transfer-encoding", "content-encoding", "connection", "content-type"].includes(k)) return;
      // relay upstream cookies EXCEPT when we have fresh signin cookies to set
      if (k === "set-cookie" && !cookieOverride) resHeaders[k] = v;
    });
    if (cookieOverride) resHeaders["set-cookie"] = cookieOverride;
    // on signout, clear the gate session too
    if (url.pathname === "/api/v1/auths/signout") {
      resHeaders["set-cookie"] = [
        ...(Array.isArray(resHeaders["set-cookie"]) ? resHeaders["set-cookie"] : resHeaders["set-cookie"] ? [resHeaders["set-cookie"]] : []),
        "korvarix_llm=; Path=/; HttpOnly; Max-Age=0",
      ];
    }
    // MIME: FORCED from the file extension for every known type - the gate
    // never trusts the upstream's content-type for static files. Unknown
    // extensions keep the upstream value when present. (API responses like
    // /api/* JSON have no file extension and take the upstream value.)
    const upstreamCt = upstream.headers.get("content-type");
    const ext = url.pathname.split(".").pop()?.toLowerCase() ?? "";
    const forcedMime = MIME_BY_EXT[ext];
    if (forcedMime) {
      resHeaders["content-type"] = forcedMime;
    } else if (upstreamCt) {
      resHeaders["content-type"] = upstreamCt;
    }
    // 304 POISON BREAK: strip conditional request headers for /_app/ assets so
    // OWUI must return a complete 200 (with our forced MIME) instead of a
    // bodyless 304 the browser would answer from its cache.
    if (url.pathname.startsWith("/_app/")) {
      delete headers["if-none-match"];
      delete headers["if-modified-since"];
      // never let a stale poisoned cache entry survive: assets are re-fetched
      // in full and stamped no-store so old broken copies are replaced
      resHeaders["cache-control"] = "no-store";
    }
    // diagnostics: log upstream status for non-2xx or odd content-types on assets
    if (upstream.status >= 400 || (url.pathname.startsWith("/_app/") && upstreamCt === null)) {
      log(`upstream ${req.method} ${url.pathname} -> ${upstream.status} ct=${JSON.stringify(upstreamCt)}`);
    }
    res.writeHead(upstream.status, resHeaders);

    // STREAM the body with real backpressure (pipeline honors it; a manual
    // res.write loop buffers unboundedly against a slow/dead client).
    // Panel completion calls tee the response for the usage log (same as the
    // API-key branch) so panel chats count in the nightly report.
    let panelUsageCaptured = false;
    const capturePanelUsage = (buf) => {
      if (panelUsageCaptured || !isCompletionPath(url.pathname)) return;
      try {
        const matches = [...buf.toString("utf8").matchAll(/"usage"\s*:\s*\{[^{}]*\}/g)];
        let last = null;
        for (const m of matches) {
          try { last = JSON.parse(`{${m[0]}}`).usage; } catch {}
        }
        if (last && (last.prompt_tokens != null || last.completion_tokens != null)) {
          panelUsageCaptured = true;
          usageLog({
            kind: "completion",
            subject: session?.email ?? panelIp2,
            via: "panel",
            model: panelModel || "unknown",
            pt: Number(last.prompt_tokens) || 0,
            ct: Number(last.completion_tokens) || 0,
            status: upstream.status,
          });
        }
      } catch {}
    };
    if (upstream.body) {
      const pCtype = String(upstreamCt ?? "");
      try {
        if (panelCompletion && (pCtype.includes("event-stream") || pCtype.includes("json"))) {
          const { Transform } = await import("node:stream");
          const tee = new Transform({
            transform(chunk, _enc, cb) {
              capturePanelUsage(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
              cb(null, chunk);
            },
          });
          await pipeline(upstream.body, tee, res);
        } else {
          await pipeline(upstream.body, res);
        }
      } catch (err) {
        // premature close = client navigated away mid-transfer: normal
        if (err?.code !== "ERR_STREAM_PREMATURE_CLOSE") {
          log(`stream ${req.method} ${url.pathname} error: ${err?.code ?? err?.message ?? err}`);
        }
        if (!res.writableEnded) res.end();
      }
    } else {
      res.end();
    }
    if (panelCompletion && upstream.status < 400 && !panelUsageCaptured) {
      usageLog({ kind: "completion", subject: session?.email ?? panelIp2, via: "panel", model: panelModel || "unknown", pt: null, ct: null, status: upstream.status });
    }
    // request trace: every request when GATE_TRACE=1, otherwise only non-2xx
    if (GATE_TRACE || upstream.status >= 400) {
      log(`proxy ${req.method} ${url.pathname} -> ${upstream.status} ct=${JSON.stringify(upstreamCt ?? resHeaders["content-type"] ?? null)}`);
    }
  } catch (err) {
    const timedOut = String(err?.name ?? "") === "TimeoutError" || String(err?.message ?? "").includes("timeout");
    log(`FAILED ${req.method} ${url.pathname}: ${err?.name ?? "Error"} ${err?.message ?? err}`);
    if (res.headersSent) {
      // headers already went out (mid-stream failure): just close the socket
      if (!res.writableEnded) res.end();
      return;
    }
    res.writeHead(timedOut ? 504 : 502, { "Content-Type": "text/html; charset=utf-8" });
    res.end(
      timedOut
        ? "<h1>Panel took too long to start responding</h1><p>Open WebUI may be warming up - <a href=\"/\">reload</a> in a few seconds.</p>"
        : `<h1>Panel error</h1><p>${String(err?.message ?? err).replace(/[<>&]/g, "").slice(0, 200)}</p><p><a href="/">reload</a></p>`
    );
  }
});

// bind host: 127.0.0.1 when run on the host (loopback only), 0.0.0.0 inside
// docker (the gateway/proxy reaches it over the bridge network; the port is
// only published to 127.0.0.1 on the host side)
const BIND_HOST = envString("GATE_BIND", "127.0.0.1");
server.listen(PORT, BIND_HOST, () => log(`korvarix-llm gate on ${BIND_HOST}:${PORT} -> open-webui ${WEBUI_HOST}:${WEBUI_INTERNAL_PORT}`));