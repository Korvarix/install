import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
export function parseEnv(text) {
    const out = {};
    for (const rawLine of text.split(/\r?\n/)) {
        const line = rawLine.trim();
        if (!line || line.startsWith("#"))
            continue;
        const eq = line.indexOf("=");
        if (eq <= 0)
            continue;
        const key = line.slice(0, eq).trim();
        let value = line.slice(eq + 1).trim();
        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'"))) {
            value = value.slice(1, -1);
        }
        if (key)
            out[key] = value;
    }
    return out;
}
/** Walks up from a module URL to the directory containing its package.json. */
export function findServiceRoot(startUrl) {
    let dir = fileURLToPath(startUrl);
    for (;;) {
        if (existsSync(resolve(dir, "package.json")))
            return dir;
        const parent = dirname(dir);
        if (parent === dir)
            return dir;
        dir = parent;
    }
}
/**
 * Loads `.env` for the calling service. Checks the current working directory
 * first, then the calling module's package root. Never overrides variables
 * already set in the environment (container/Pterodactyl env wins).
 */
export function loadEnv(startUrl) {
    const candidates = [resolve(process.cwd(), ".env"), resolve(findServiceRoot(startUrl), ".env")];
    for (const path of candidates) {
        if (!existsSync(path))
            continue;
        const parsed = parseEnv(readFileSync(path, "utf8"));
        for (const [key, value] of Object.entries(parsed)) {
            if (process.env[key] === undefined)
                process.env[key] = value;
        }
        return;
    }
}
export function envString(key, fallback) {
    return process.env[key] ?? fallback;
}
export function envNumber(key, fallback) {
    const raw = process.env[key];
    if (raw === undefined || raw === "")
        return fallback;
    const n = Number(raw);
    return Number.isFinite(n) ? n : fallback;
}
export function envBool(key, fallback) {
    const raw = process.env[key];
    if (raw === undefined)
        return fallback;
    return raw === "true" || raw === "1";
}
//# sourceMappingURL=env.js.map