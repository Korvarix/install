// korvarix logo rasterizer - generates the PNG/ICO set Open WebUI serves from
// /static/* from the korvarix vector logo (public/assets/img/logo.svg), zero
// npm deps (pure-JS PNG encoder; ICO wraps the PNGs).
//
//   node scripts/make-branding.mjs <logo.svg> <out-dir>
//
// Output: logo.png (500x500), splash.png (960x540 dark bg), splash-dark.png,
// favicon.png (96x96), favicon-96x96.png, apple-touch-icon.png (180x180),
// web-app-manifest-192x192.png, web-app-manifest-512x512.png, favicon.ico.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { deflateSync } from "node:zlib";

const [, , svgPath, outDir] = process.argv;
if (!svgPath || !outDir) {
  console.error("usage: node make-branding.mjs <logo.svg> <out-dir>");
  process.exit(1);
}
const svg = readFileSync(svgPath, "utf8");

// ---- rasterize SVG via the browser-less path: parse the two simple paths and
// scanline-fill them ourselves (the korvarix logo is two hexagon-ish paths with
// a linear gradient - exact geometry, no external renderer needed).

// extract path d= attributes and the gradient stops from the SVG
const pathDs = [...svg.matchAll(/<path[^>]*\bd="([^"]+)"/g)].map((m) => m[1]);
const stops = [...svg.matchAll(/<stop[^>]*offset="([^"]+)"[^>]*stop-color="([^"]+)"/g)]
  .map((m) => ({ offset: parseFloat(m[1]), color: hexToRgb(m[2]) }))
  .sort((a, b) => a.offset - b.offset);
const strokeWidth = Number(/stroke-width="([\d.]+)"/.exec(svg)?.[1] ?? 5);
if (pathDs.length < 2 || stops.length < 2) {
  console.error("make-branding: could not parse logo.svg (expected 2 paths + gradient)");
  process.exit(1);
}

// INNER-SHAPE GRADIENT (brightness fix): the inner hexagon uses the raw
// brand gradient whose violet end (#8b5cf6) goes dim on the dark background -
// "the darker characters in the middle are hard to see". The fill gets a
// dedicated brighter ramp (cyan-300 -> violet-400) while the outer stroke
// keeps the exact brand gradient.
const FILL_STOPS = [
  { offset: 0, color: hexToRgb("#67e8f9") }, // cyan-300
  { offset: 1, color: hexToRgb("#a78bfa") }, // violet-400
];

function hexToRgb(hex) {
  const h = hex.replace("#", "");
  return [
    parseInt(h.slice(0, 2), 16),
    parseInt(h.slice(2, 4), 16),
    parseInt(h.slice(4, 6), 16),
  ];
}

// gradient direction from the SVG: x1 0 -> x2 1, y1 0 -> y2 1 (diagonal TL->BR)
function gradientColor(t, ramp = stops) {
  const t2 = Math.min(1, Math.max(0, t));
  const a = ramp[0].color;
  const b = ramp[ramp.length - 1].color;
  return [0, 1, 2].map((i) => Math.round(a[i] + (b[i] - a[i]) * t2));
}
// fill ramp for the inner shape (brighter), stroke keeps the brand gradient
function fillColor(t) {
  return gradientColor(t, FILL_STOPS);
}

// ---- tiny path evaluator: supports M/L/Z + implicit lines (the logo only uses
// these). Returns polygon point lists in a 64x64 viewBox coordinate space.
function parsePath(d) {
  const tokens = d.match(/[MLZz]|-?\d*\.?\d+/g) ?? [];
  const polys = [];
  let cur = [];
  let i = 0;
  let cmd = "M";
  let x = 0;
  let y = 0;
  while (i < tokens.length) {
    const t = tokens[i];
    if (t === "M") { cmd = "M"; i++; continue; }
    if (t === "L") { cmd = "L"; i++; continue; }
    if (t === "Z" || t === "z") {
      if (cur.length) polys.push(cur);
      cur = [];
      i++;
      continue;
    }
    const px = parseFloat(t);
    const py = parseFloat(tokens[i + 1]);
    if (!Number.isFinite(px) || !Number.isFinite(py)) { i++; continue; }
    if (cmd === "M" && cur.length === 0) { x = px; y = py; cur = [x, y]; }
    else { x = px; y = py; cur.push(x, y); }
    i += 2;
  }
  if (cur.length) polys.push(cur);
  return polys;
}

// scale polygons from the 64-unit viewBox to a size x size canvas, centered,
// with padding
function scalePolys(polys, size, pad) {
  const s = (size - pad * 2) / 64;
  return polys.map((p) =>
    p.map((v, idx) => (idx % 2 === 0 ? pad + v * s : pad + v * s))
  );
}

// ---- scanline polygon fill with a diagonal gradient shader -----------------
function render(size, { pad = 0, stroke = true, bg = null, glow = 0 } = {}) {
  const w = bg && bg[2] ? size : size; // square canvas for logos/icons
  const h = size;
  const buf = Buffer.alloc(w * h * 4);
  const putPx = (x, y, rgba) => {
    if (x < 0 || y < 0 || x >= w || y >= h) return;
    const o = (y * w + x) * 4;
    const a = rgba[3] ?? 255;
    // source-over blend
    const sa = a / 255;
    buf[o] = Math.round(buf[o] * (1 - sa) + rgba[0] * sa);
    buf[o + 1] = Math.round(buf[o + 1] * (1 - sa) + rgba[1] * sa);
    buf[o + 2] = Math.round(buf[o + 2] * (1 - sa) + rgba[2] * sa);
    buf[o + 3] = Math.min(255, Math.round(buf[o + 3] + a * (1 - buf[o + 3] / 255)));
  };

  // background
  if (bg) {
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const o = (y * w + x) * 4;
        buf[o] = bg[0]; buf[o + 1] = bg[1]; buf[o + 2] = bg[2]; buf[o + 3] = 255;
      }
    }
  }

  const polys = scalePolys(pathDs.map(parsePath), size, pad);

  // point-in-polygon (even-odd) for the fill shapes; outline handled by
  // distance-to-edge approximation below
  const inPoly = (polysList, px, py) => {
    let inside = false;
    for (const poly of polysList) {
      const pts = [];
      for (let j = 0; j < poly.length; j += 2) pts.push([poly[j], poly[j + 1]]);
      for (let a = 0, b = pts.length - 1; a < pts.length; b = a++) {
        const [xa, ya] = pts[a];
        const [xb, yb] = pts[b];
        if (ya > py !== yb > py && px < ((xb - xa) * (py - ya)) / (yb - ya) + xa) {
          inside = !inside;
        }
      }
    }
    return inside;
  };

  const distToEdges = (poly, px, py) => {
    let best = Infinity;
    for (let j = 0; j < poly.length; j += 2) {
      const x1 = poly[j];
      const y1 = poly[j + 1];
      const x2 = poly[(j + 2) % poly.length];
      const y2 = poly[(j + 3) % poly.length];
      const dx = x2 - x1;
      const dy = y2 - y1;
      const len2 = dx * dx + dy * dy || 1;
      const t = Math.min(1, Math.max(0, ((px - x1) * dx + (py - y1) * dy) / len2));
      const cx = x1 + t * dx;
      const cy = y1 + t * dy;
      best = Math.min(best, Math.hypot(px - cx, py - cy));
    }
    return best;
  };

  const allPolys = polys;
  const fillPolys = polys.slice(1); // path 1 = the filled inner hex
  const outlinePoly = polys[0];

  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const t = (x / w + y / h) / 2; // diagonal gradient like the SVG
      let painted = false;

      // outer shape: stroke only (like the SVG)
      if (stroke && outlinePoly) {
        const d = distToEdges(outlinePoly, x + 0.5, y + 0.5);
        const half = (strokeWidth * (size - pad * 2)) / 64 / 2;
        if (Math.abs(d - 0) <= half) {
          putPx(x, y, [...gradientColor(t), 255]);
          painted = true;
        }
        // soft glow bleed on splashes
        if (glow > 0 && !painted && d > half && d < half + glow) {
          const a = Math.round(70 * (1 - (d - half) / glow));
          if (a > 0) putPx(x, y, [...gradientColor(t), a]);
        }
      }

      // inner shape: filled with the BRIGHTER ramp so it reads on dark bg
      if (!painted && inPoly(fillPolys, x + 0.5, y + 0.5)) {
        putPx(x, y, [...fillColor(t), 255]);
      }
    }
  }
  return { buf, w, h };
}

// ---- minimal PNG encoder (RGBA, no filter) --------------------------------
function crc32(buf) {
  let c;
  const table = [];
  for (let n = 0; n < 256; n++) {
    c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    table[n] = c >>> 0;
  }
  let crc = 0xffffffff;
  for (const b of buf) crc = table[(crc ^ b) & 0xff] ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}
function encodePng({ buf, w, h }) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // RGBA
  // per-row filter 0 prefix
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 4 + 1)] = 0;
    buf.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// ---- ICO wrapper (PNG-in-ICO) ----------------------------------------------
function encodeIco(pngs) {
  const count = pngs.length;
  const header = Buffer.alloc(6);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2); // type icon
  header.writeUInt16LE(count, 4);
  const entries = [];
  let offset = 6 + count * 16;
  const datas = [];
  for (const { size, png } of pngs) {
    const e = Buffer.alloc(16);
    e[0] = size >= 256 ? 0 : size; // width
    e[1] = size >= 256 ? 0 : size; // height
    e.writeUInt16LE(1, 4); // planes
    e.writeUInt16LE(32, 6); // bpp
    e.writeUInt32LE(png.length, 8);
    e.writeUInt32LE(offset, 12);
    offset += png.length;
    entries.push(e);
    datas.push(png);
  }
  return Buffer.concat([header, ...entries, ...datas]);
}

// ---- generate the full set --------------------------------------------------
mkdirSync(outDir, { recursive: true });
const write = (name, png) => {
  writeFileSync(join(outDir, name), png);
  console.log(`  ${name} (${png.length} B)`);
};

// favicon.svg: OWUI's index.html declares BOTH favicon.png and favicon.svg,
// and browsers prefer the SVG - the earlier branding round missed it, so the
// browser tab kept the stock Open WebUI icon. Write the korvarix logo as a
// real SVG (crisp at every size) with the same brighter inner fill.
const brightSvg = svg
  // inner path (2nd) gets the brighter gradient stops
  .replace(
    /(<path d="[^"]+" fill=")url\(#g\)("\s*\/>)(?!.*fill=")/s,
    '$1url(#g-bright)$2'
  )
  // inject the brighter gradient def after the original one
  .replace(
    /<\/defs>/,
    [
      '  <linearGradient id="g-bright" x1="0" y1="0" x2="1" y2="1">',
      '    <stop offset="0" stop-color="#67e8f9"/>',
      '    <stop offset="1" stop-color="#a78bfa"/>',
      '  </linearGradient>',
      '</defs>',
    ].join("\n")
  );
write("favicon.svg", Buffer.from(brightSvg, "utf8"));

const DARK_BG = [7, 10, 18]; // korvarix --bg
const logoTransparent = render(512, { pad: 24 });
const logo500 = render(500, { pad: 24 });
write("logo.png", encodePng(logo500));

const splash = render(960, { pad: 340, bg: DARK_BG, glow: 26 });
write("splash.png", encodePng(splash));
const splashDark = render(960, { pad: 340, bg: [11, 16, 29], glow: 26 });
write("splash-dark.png", encodePng(splashDark));

const fav96 = render(96, { pad: 6 });
write("favicon.png", encodePng(fav96));
write("favicon-96x96.png", encodePng(render(96, { pad: 6 })));
write("apple-touch-icon.png", encodePng(render(180, { pad: 14, bg: DARK_BG })));
write("web-app-manifest-192x192.png", encodePng(render(192, { pad: 14 })));
write("web-app-manifest-512x512.png", encodePng(logoTransparent));
write("favicon.ico", encodeIco([{ size: 32, png: encodePng(render(32, { pad: 2 })) }, { size: 48, png: encodePng(render(48, { pad: 3 })) }, { size: 96, png: encodePng(fav96) }]));

console.log(`branding set written to ${outDir}`);