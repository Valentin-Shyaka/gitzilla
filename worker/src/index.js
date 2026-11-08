import { verifySshSig } from "./sshsig.js";
import { verifyGithubSignature } from "./hmac.js";
import { notifyReport, notifyAccountAlert } from "./notify.js";

export { Hub } from "./hub.js";

const SKEW_MS = 600_000;
const MAX_BODY = 8192;
const QUEUE_SKEW_MS = 300_000;
const HEX40 = /^[0-9a-f]{40}$/;

function b64decode(s) {
  try {
    const bin = atob(s);
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return null;
  }
}

function validNote(n) {
  return (
    n && typeof n === "object" &&
    typeof n.repo === "string" && /^[a-z0-9._-]+\/[a-z0-9._-]+$/.test(n.repo) &&
    typeof n.ref === "string" && n.ref.startsWith("refs/") &&
    HEX40.test(n.old_sha) && HEX40.test(n.new_sha) &&
    Number.isInteger(n.ts) &&
    typeof n.nonce === "string" && /^[0-9a-f]{32}$/.test(n.nonce)
  );
}

async function handleNote(request, env) {
  const text = await request.text();
  if (text.length > MAX_BODY) return new Response("too large", { status: 400 });
  let body;
  try { body = JSON.parse(text); } catch { return new Response("bad json", { status: 400 }); }
  if (!body || typeof body.payload !== "string" || typeof body.sig !== "string") {
    return new Response("bad body", { status: 400 });
  }
  const raw = b64decode(body.payload);
  if (!raw) return new Response("bad base64", { status: 400 });

  if (!(await verifySshSig(body.sig, raw, "gitzilla-note", env.NOTE_PUBKEY || ""))) {
    return new Response("bad signature", { status: 401 });
  }
  let note;
  try { note = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); } catch { return new Response("bad payload", { status: 400 }); }
  if (!validNote(note)) return new Response("bad payload", { status: 400 });

  const now = Date.now();
  if (Math.abs(note.ts * 1000 - now) > SKEW_MS) return new Response("ts out of range", { status: 422 });

  const hub = env.HUB.get(env.HUB.idFromName("main"));
  if (!(await hub.addNote(note.repo, note.ref, note.new_sha, note.nonce, note.ts, now))) {
    return new Response("replayed", { status: 409 });
  }
  return new Response(null, { status: 204 });
}

const REPO_RE = /^[a-z0-9._-]+\/[a-z0-9._-]+$/;
const REPORT_MAX = 50;
const REPORT_REASONS = [
  "ref moved since the incident", "old commit not available locally", "could not send note",
  "not flagged critical — review manually", "interleaved with your own pushes", "invalid event",
  "no change", "push failed", "restore target not verified — review manually",
];

const REASON_DETAIL = /^[A-Za-z0-9 ._:/-]{0,100}$/;
const REPORT_TOTAL_MAX = 100_000;
// Exact fixed reason, or fixed reason + " (" + detail + ")" with a restricted detail charset.
function validReason(r) {
  if (typeof r !== "string") return false;
  return REPORT_REASONS.some((p) =>
    r === p || (r.startsWith(p + " (") && r.endsWith(")") && REASON_DETAIL.test(r.slice(p.length + 2, -1))));
}

// Returns a clean report, or null if anything is off.
function cleanReport(r) {
  if (!r || typeof r !== "object" || !Number.isInteger(r.ts)) return null;
  if (typeof r.nonce !== "string" || !/^[0-9a-f]{32}$/.test(r.nonce)) return null;
  if (!Array.isArray(r.restored) || !Array.isArray(r.skipped)) return null;
  const okTotal = (t, n) => Number.isInteger(t) && t >= n && t <= REPORT_TOTAL_MAX;
  if (!okTotal(r.restored_total, r.restored.length) || !okTotal(r.skipped_total, r.skipped.length)) return null;
  if (r.restored.length > REPORT_MAX || r.skipped.length > REPORT_MAX) return null;
  const base = (e) => e && typeof e === "object" && typeof e.repo === "string" && REPO_RE.test(e.repo) &&
    typeof e.ref === "string" && e.ref.startsWith("refs/");
  const restored = [], skipped = [];
  for (const e of r.restored) {
    if (!base(e)) return null;
    restored.push({ repo: e.repo, ref: e.ref });
  }
  for (const e of r.skipped) {
    if (!base(e) || !validReason(e.reason)) return null;
    skipped.push({ repo: e.repo, ref: e.ref, reason: e.reason.slice(0, 120) });
  }
  return { ts: r.ts, nonce: r.nonce, restored, skipped, restored_total: r.restored_total, skipped_total: r.skipped_total };
}

async function handleReport(request, env) {
  const text = await request.text();
  if (text.length > MAX_BODY) return new Response("too large", { status: 400 });
  let body;
  try { body = JSON.parse(text); } catch { return new Response("bad json", { status: 400 }); }
  if (!body || typeof body.payload !== "string" || typeof body.sig !== "string") {
    return new Response("bad body", { status: 400 });
  }
  const raw = b64decode(body.payload);
  if (!raw) return new Response("bad base64", { status: 400 });
  if (!(await verifySshSig(body.sig, raw, "gitzilla-report", env.NOTE_PUBKEY || ""))) {
    return new Response("bad signature", { status: 401 });
  }
  let parsed;
  try { parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); } catch { return new Response("bad payload", { status: 400 }); }
  const report = cleanReport(parsed);
  if (!report) return new Response("bad payload", { status: 400 });

  const now = Date.now();
  if (Math.abs(report.ts * 1000 - now) > SKEW_MS) return new Response("ts out of range", { status: 422 });
  if (!(await getHub(env).useNonce(report.nonce, report.ts, now))) return new Response("replayed", { status: 409 });

  try { await notifyReport(report, env); } catch (e) { console.error("report notify failed", e); }
  return new Response(null, { status: 204 });
}

// POST /alert: account alerts from the Mac's reconcile, signed in their own namespace. Strict shape: exactly
// these keys, fixed values; the Worker writes the message text itself (no free text from the Mac).
const ALERT_SKEW_MS = 300_000;
const ALERT_FIELDS = {
  "new-key": {
    key_type: (v) => typeof v === "string" && /^(ssh-|ecdsa-|sk-)[A-Za-z0-9@.-]{1,60}$/.test(v),
    fingerprint: (v) => typeof v === "string" && /^SHA256:[A-Za-z0-9+/]{43}$/.test(v),
    source: (v) => v === "auth" || v === "signing",
  },
  "missed-webhook": {
    refs: (v) => Number.isInteger(v) && v >= 1 && v <= 100_000,
    repos: (v) => Number.isInteger(v) && v >= 1 && v <= 100_000,
  },
};

function cleanAlert(a) {
  if (!a || typeof a !== "object" || Array.isArray(a)) return null;
  const spec = Object.hasOwn(ALERT_FIELDS, a.kind) ? ALERT_FIELDS[a.kind] : null;
  if (!spec || !Number.isInteger(a.ts)) return null;
  if (typeof a.nonce !== "string" || !/^[0-9a-f]{32}$/.test(a.nonce)) return null;
  const want = ["kind", "ts", "nonce", ...Object.keys(spec)];
  const keys = Object.keys(a);
  if (keys.length !== want.length || !keys.every((k) => want.includes(k))) return null;
  const out = { kind: a.kind, ts: a.ts, nonce: a.nonce };
  for (const [k, ok] of Object.entries(spec)) {
    if (!ok(a[k])) return null;
    out[k] = a[k];
  }
  return out;
}

async function handleAlert(request, env) {
  const text = await request.text();
  if (text.length > MAX_BODY) return new Response("too large", { status: 400 });
  let body;
  try { body = JSON.parse(text); } catch { return new Response("bad json", { status: 400 }); }
  if (!body || typeof body.payload !== "string" || typeof body.sig !== "string") {
    return new Response("bad body", { status: 400 });
  }
  const raw = b64decode(body.payload);
  if (!raw) return new Response("bad base64", { status: 400 });
  if (!(await verifySshSig(body.sig, raw, "gitzilla-alert", env.NOTE_PUBKEY || ""))) {
    return new Response("bad signature", { status: 401 });
  }
  let parsed;
  try { parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)); } catch { return new Response("bad payload", { status: 400 }); }
  const a = cleanAlert(parsed);
  if (!a) return new Response("bad payload", { status: 400 });
  const now = Date.now();
  if (Math.abs(a.ts * 1000 - now) > ALERT_SKEW_MS) return new Response("ts out of range", { status: 422 });
  if (!(await getHub(env).useNonce(a.nonce, a.ts, now))) return new Response("replayed", { status: 409 });
  try { await notifyAccountAlert(a, env); } catch (e) { console.error("alert notify failed", e); }
  return new Response(null, { status: 204 });
}

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });
const getHub = (env) => env.HUB.get(env.HUB.idFromName("main"));

async function handleWebhook(request, env) {
  const body = new Uint8Array(await request.arrayBuffer());
  if (!env.WEBHOOK_SECRET ||
      !(await verifyGithubSignature(env.WEBHOOK_SECRET, body, request.headers.get("X-Hub-Signature-256")))) {
    return new Response("bad signature", { status: 401 });
  }
  const event = request.headers.get("X-GitHub-Event");
  const delivery = request.headers.get("X-GitHub-Delivery");
  if (!["push", "installation", "installation_repositories"].includes(event)) return new Response(null, { status: 204 });
  if (!delivery) return new Response("missing delivery", { status: 400 });
  let p;
  try { p = JSON.parse(new TextDecoder().decode(body)); } catch { return new Response("bad json", { status: 400 }); }
  if (!p || typeof p !== "object") return new Response("bad json", { status: 400 });
  const now = Date.now();
  const hub = getHub(env);

  if (event === "push") {
    const repo = p.repository?.full_name;
    if (typeof repo !== "string" || typeof p.ref !== "string" || !HEX40.test(p.before) || !HEX40.test(p.after)) {
      return new Response("bad payload", { status: 400 });
    }
    await hub.receivePush(delivery, {
      repo: repo.toLowerCase(), ref: p.ref, before: p.before, after: p.after, forced: p.forced === true,
    }, now);
    return new Response(null, { status: 202 });
  }
  // a suspended app stops every delivery: as bad as an uninstall
  if (event === "installation" && (p.action === "deleted" || p.action === "suspend")) {
    await hub.receiveDisarmed(delivery, String(p.installation?.account?.login ?? "").toLowerCase(), now);
    return new Response(null, { status: 202 });
  }
  if (event === "installation_repositories" && p.action === "removed") {
    const names = (p.repositories_removed ?? []).map((r) => String(r?.full_name ?? "").toLowerCase()).filter(Boolean);
    const repo = names.length ? names.join(",") : String(p.installation?.account?.login ?? "").toLowerCase();
    await hub.receiveDisarmed(delivery, repo, now);
    return new Response(null, { status: 202 });
  }
  return new Response(null, { status: 204 });
}

// X-Gitzilla-Auth: base64(JSON {"ts":<unix s>}) "." base64(armored SSHSIG over those exact JSON bytes)
async function queueAuthorized(request, env) {
  const parts = (request.headers.get("X-Gitzilla-Auth") || "").split(".");
  if (parts.length !== 2) return false;
  const raw = b64decode(parts[0]);
  const sigBytes = b64decode(parts[1]);
  if (!raw || !sigBytes) return false;
  let ts;
  try {
    ts = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw)).ts;
  } catch { return false; }
  if (!Number.isInteger(ts) || Math.abs(ts * 1000 - Date.now()) > QUEUE_SKEW_MS) return false;
  const sig = new TextDecoder().decode(sigBytes);
  return verifySshSig(sig, raw, "gitzilla-queue", env.NOTE_PUBKEY || "");
}

async function handleQueue(request, env) {
  if (!(await queueAuthorized(request, env))) return new Response("unauthorized", { status: 401 });
  const raw = new URL(request.url).searchParams.get("after") ?? "0";
  if (!/^\d{1,15}$/.test(raw)) return new Response("bad after", { status: 400 });
  return json(await getHub(env).events(Number(raw)));
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/note" && request.method === "POST") return handleNote(request, env);
    if (url.pathname === "/report" && request.method === "POST") return handleReport(request, env);
    if (url.pathname === "/alert" && request.method === "POST") return handleAlert(request, env);
    if (url.pathname === "/webhook" && request.method === "POST") return handleWebhook(request, env);
    if (url.pathname === "/queue" && request.method === "GET") return handleQueue(request, env);
    if (url.pathname === "/health" && request.method === "GET") return json({ ok: true });
    return new Response("not found", { status: 404 });
  },
};
