// Org mode: pure helpers for member enrollment and admin commands (no storage, no network).

export const KEY_TYPE = "ecdsa-sha2-nistp256";
export const MAX_ADMIN_KEYS = 3;
export const MAX_MEMBERS = 2000;
export const MAX_KEYS_PER_MEMBER = 8;
export const MAX_PENDING = 200;
export const MAX_BOTS = 200;
export const PENDING_TTL_MS = 7 * 86_400_000;
export const ENROLL_PER_HOUR = 10;
export const ENROLL_GLOBAL_PER_HOUR = 100;

// "_" appears in Enterprise Managed Users' logins (<user>_<shortcode>)
const LOGIN_RE = /^[a-z0-9](?:[a-z0-9_-]{0,38})$/;
// GitHub App bots push as "<name>[bot]"
const BOT_RE = /^[a-z0-9](?:[a-z0-9_-]{0,38})(?:\[bot\])?$/;
const FP_RE = /^SHA256:[A-Za-z0-9+/]{43}$/;
const NONCE_RE = /^[0-9a-f]{32}$/;

// Lowercased login if valid, else null.
export function cleanLogin(v) {
  if (typeof v !== "string") return null;
  const l = v.toLowerCase();
  return LOGIN_RE.test(l) ? l : null;
}

export function cleanBotLogin(v) {
  if (typeof v !== "string") return null;
  const l = v.toLowerCase();
  return BOT_RE.test(l) ? l : null;
}

export const validFingerprint = (v) => typeof v === "string" && FP_RE.test(v);
export const validNonce = (v) => typeof v === "string" && NONCE_RE.test(v);

function b64(s) {
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function u32(buf, off) {
  return off + 4 <= buf.length ? new DataView(buf.buffer, buf.byteOffset + off, 4).getUint32(0) : -1;
}

// "ecdsa-sha2-nistp256 <base64 blob> [comment]" -> the blob bytes if the blob is a well-formed
// nistp256 public key (string type, string curve, string 65-byte uncompressed point), else null.
function keyBlob(line) {
  if (typeof line !== "string" || line.length > 512) return null;
  const parts = line.trim().split(/\s+/);
  if (parts[0] !== KEY_TYPE || !parts[1] || !/^[A-Za-z0-9+/]+={0,2}$/.test(parts[1])) return null;
  const blob = b64(parts[1]);
  if (!blob) return null;
  const td = new TextDecoder();
  let off = 0;
  const field = () => {
    const n = u32(blob, off);
    if (n < 0 || off + 4 + n > blob.length) return null;
    const f = blob.subarray(off + 4, off + 4 + n);
    off += 4 + n;
    return f;
  };
  const t = field(), c = field(), p = field();
  if (!t || !c || !p || off !== blob.length) return null;
  if (td.decode(t) !== KEY_TYPE || td.decode(c) !== "nistp256" || p.length !== 65 || p[0] !== 4) return null;
  return blob;
}

// Normalized "ecdsa-sha2-nistp256 <base64>" (comment dropped), or null.
export function cleanPubkey(line) {
  if (!keyBlob(line)) return null;
  const parts = line.trim().split(/\s+/);
  return `${parts[0]} ${parts[1]}`;
}

// "SHA256:<base64 of sha256(blob), no padding>", the same string `ssh-keygen -lf` prints. Null if not a key.
export async function fingerprint(pubkeyLine) {
  const blob = keyBlob(pubkeyLine);
  if (!blob) return null;
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", blob));
  return "SHA256:" + btoa(String.fromCharCode(...h)).replace(/=+$/, "");
}

// ADMIN_PUBKEYS: newline- or comma-separated key lines, at most MAX_ADMIN_KEYS. Anything malformed or more than
// MAX_ADMIN_KEYS keys fails closed (no admin keys at all) rather than silently trusting a subset.
// Memoized per isolate on the string value, so a bad value is parsed (and logged) once, not on every request.
let adminCache = { str: undefined, keys: [] };
export function parseAdminKeys(str) {
  str = String(str ?? "");
  if (adminCache.str === str) return adminCache.keys;
  const lines = str.split(/[\n,]/).map((l) => l.trim()).filter(Boolean);
  let keys = lines.map(cleanPubkey);
  if (lines.length > MAX_ADMIN_KEYS) {
    console.error(`ADMIN_PUBKEYS has ${lines.length} keys (max ${MAX_ADMIN_KEYS}); admin auth disabled`);
    keys = [];
  } else if (keys.some((k) => k === null)) {
    console.error("ADMIN_PUBKEYS has a malformed key; admin auth disabled");
    keys = [];
  }
  adminCache = { str, keys: Object.freeze(keys) };
  return adminCache.keys;
}

// Rate-limit bucket for a client address: IPv4 as is, IPv6 by its /64 prefix (a single host usually holds a
// whole /64, so per-address buckets would be free to rotate). IPv4-mapped IPv6 counts as the IPv4 address.
// Anything unparsable shares one "?" bucket.
export function ipBucket(ip) {
  ip = String(ip ?? "").trim().toLowerCase();
  const v4 = /^(?:::ffff:)?((?:\d{1,3}\.){3}\d{1,3})$/.exec(ip);
  if (v4) return v4[1];
  if (ip.length > 45 || !/^[0-9a-f:]+$/.test(ip) || !ip.includes(":")) return "?";
  const halves = ip.split("::");
  if (halves.length > 2) return "?";
  const head = halves[0] ? halves[0].split(":") : [];
  const tail = halves.length === 2 && halves[1] ? halves[1].split(":") : [];
  const fill = 8 - head.length - tail.length;
  if (halves.length === 2 ? fill < 1 : fill !== 0) return "?";
  const groups = [...head, ...Array(fill).fill("0"), ...tail];
  if (groups.some((g) => !/^[0-9a-f]{1,4}$/.test(g))) return "?";
  return groups.slice(0, 4).map((g) => g.replace(/^0+(?=.)/, "")).join(":") + "::/64";
}

const exactKeys = (o, want) => {
  const keys = Object.keys(o);
  return keys.length === want.length && keys.every((k) => want.includes(k));
};
const isObj = (o) => o !== null && typeof o === "object" && !Array.isArray(o);

// Enrollment payload {login, pubkey, ts, nonce} -> cleaned copy, or null.
export function cleanEnroll(p) {
  if (!isObj(p) || !exactKeys(p, ["login", "pubkey", "ts", "nonce"])) return null;
  const login = cleanLogin(p.login), pubkey = cleanPubkey(p.pubkey);
  if (!login || !pubkey || !Number.isInteger(p.ts) || !validNonce(p.nonce)) return null;
  return { login, pubkey, ts: p.ts, nonce: p.nonce };
}

// Admin command arg specs: required and optional fields with validators/cleaners.
const ADMIN_CMDS = {
  approve: { req: { login: cleanLogin, fingerprint: (v) => (validFingerprint(v) ? v : null) }, opt: {} },
  revoke: { req: { login: cleanLogin }, opt: { fingerprint: (v) => (validFingerprint(v) ? v : null) } },
  list: { req: {}, opt: {} },
  "allow-bot": { req: { login: cleanBotLogin }, opt: {} },
  "disallow-bot": { req: { login: cleanBotLogin }, opt: {} },
};

// Admin envelope {cmd, args, ts, nonce} -> { ts, nonce, cmd?, args?, error? }.
// error "payload" = envelope malformed; "cmd"/"args" = unknown command or bad arguments.
export function cleanAdmin(p) {
  if (!isObj(p) || !exactKeys(p, ["cmd", "args", "ts", "nonce"])) return { error: "bad payload" };
  if (!Number.isInteger(p.ts) || !validNonce(p.nonce)) return { error: "bad payload" };
  const base = { ts: p.ts, nonce: p.nonce };
  const spec = typeof p.cmd === "string" && Object.hasOwn(ADMIN_CMDS, p.cmd) ? ADMIN_CMDS[p.cmd] : null;
  if (!spec) return { ...base, error: "unknown command" };
  if (!isObj(p.args)) return { ...base, error: "bad args" };
  const args = {};
  for (const k of Object.keys(p.args)) {
    if (!Object.hasOwn(spec.req, k) && !Object.hasOwn(spec.opt, k)) return { ...base, error: "bad args" };
  }
  for (const [k, clean] of Object.entries(spec.req)) {
    const v = clean(p.args[k]);
    if (v === null) return { ...base, error: "bad args" };
    args[k] = v;
  }
  for (const [k, clean] of Object.entries(spec.opt)) {
    if (!Object.hasOwn(p.args, k)) continue;
    const v = clean(p.args[k]);
    if (v === null) return { ...base, error: "bad args" };
    args[k] = v;
  }
  return { ...base, cmd: p.cmd, args };
}
