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
const SESSION_TTL_S = envNumber("GATE_SESSION_TTL_S", 7 * 86400);
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

const log = (...a) => console.log(new Date().toISOString(), "[gate]", ...a);
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
async function syncAvatar(identity) {
  try {
    if (!identity.avatarUrl) return; // korvarix account has no avatar -> OWUI shows initials, fine
    // OWUI **API key** (never the admin password): minted by an admin user in
    // Open WebUI under Settings -> Account -> API Keys (sk-... token)
    const apiKey = envString("OPEN_WEBUI_API_KEY", "").trim();
    if (!apiKey) {
      log("avatar sync skipped: OPEN_WEBUI_API_KEY not set (OWUI admin: Settings -> Account -> API Keys)");
      return;
    }
    // find the user by email (admin user listing; api keys carry admin rights
    // when minted by an admin account)
    const users = await fetch(`${OWUI_BASE}/api/v1/users/?page=1`, {
      headers: { Authorization: `Bearer ${apiKey}` },
      signal: AbortSignal.timeout(10000),
    }).then((r) => {
      if (!r.ok) throw new Error(`users list failed (${r.status})`);
      return r.json();
    });
    const target = (users?.users ?? []).find((u) => u.email?.toLowerCase() === identity.email.toLowerCase());
    if (!target) throw new Error("provisioned user not found yet (trusted-header sign-in runs first)");
    const forward = envString("ENABLE_PROFILE_IMAGE_URL_FORWARDING", "true").toLowerCase() === "true";
    const imageUrl = forward
      ? identity.avatarUrl
      : `data:image/png;base64,${Buffer.from(await (await fetch(identity.avatarUrl, { signal: AbortSignal.timeout(10000) })).arrayBuffer()).toString("base64")}`;
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
  if (!session && !isStaticAsset) {
    // not signed in. Redirecting to korvarix.com/login?next=<panel> would
    // LOOP: after sign-in the SPA router cannot navigate cross-origin, and
    // even if it could, the gate would bounce again (the SSO mint never ran).
    // Send the visitor to the AUTO-LAUNCH route: if that browser holds a
    // korvarix session it mints the SSO code immediately and hands off; if
    // not, it flows through login and continues the launch automatically.
    res.writeHead(302, { Location: `${SITE_URL}/account/llm-launch?gate=${encodeURIComponent(PUBLIC_URL)}` });
    return res.end();
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

  // ---- everything else: require a gate session, proxy with trusted headers --

  // read the full request body (POST/PUT) and forward it
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const body = Buffer.concat(chunks);

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
    log(`in-flight ${req.method} ${url.pathname} (first-byte budget ${firstByteS}s)`);
    const upstream = await fetch(`http://${WEBUI_HOST}:${WEBUI_INTERNAL_PORT}${url.pathname}${url.search}`, {
      method: req.method,
      headers,
      body: ["GET", "HEAD"].includes(req.method) ? undefined : body,
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
    if (upstream.body) {
      try {
        await pipeline(upstream.body, res);
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