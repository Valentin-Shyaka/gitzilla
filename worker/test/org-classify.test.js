import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { env, runInDurableObject } from "cloudflare:test";
import worker from "../src/index.js";
import { classifyOrg, BURST_WINDOW_S } from "../src/classify.js";
import { formatAlert } from "../src/notify.js";
import { sigPublicKey } from "../src/sshsig.js";
import ADMIN from "./fixtures/org/admin.pub?raw";
import ADMIN2 from "./fixtures/org/admin2.pub?raw";
import ALICE from "./fixtures/org/alice.pub?raw";
import NOTE_PERSONAL from "./fixtures/note-ok.json";
import E_ALICE from "./fixtures/org/enroll-alice.json";
import E_ALICE2 from "./fixtures/org/enroll-alice2.json";
import E_BOB from "./fixtures/org/enroll-bob.json";
import E_CAROL from "./fixtures/org/enroll-carol.json";
import A_APPROVE_ALICE from "./fixtures/org/admin-approve-alice.json";
import A_APPROVE_ALICE2 from "./fixtures/org/admin-approve-alice2.json";
import A_APPROVE_BOB from "./fixtures/org/admin-approve-bob.json";
import A_REVOKE_ALICE from "./fixtures/org/admin-revoke-alice.json";
import A_ALLOW_BOT from "./fixtures/org/admin-allow-bot.json";
import N_ALICE from "./fixtures/org/note-alice.json";
import N_ALICE_AGAIN from "./fixtures/org/note-alice-again.json";
import N_ALICE2 from "./fixtures/org/note-alice2.json";
import N_BOB from "./fixtures/org/note-bob.json";
import N_CAROL from "./fixtures/org/note-carol.json";
import N_ADMIN from "./fixtures/org/note-admin.json";
import N_WRONGNS from "./fixtures/org/note-alice-wrongns.json";
import N_CLAIMS_BOB from "./fixtures/org/note-alice-claims-bob.json";

const REVOKE = "If this wasn't you: revoke tokens at https://github.com/settings/applications";
const TS = 4102444800;
const Z = "0".repeat(40), OLD = "1".repeat(40), NEW = "4".repeat(40);
const NTFY = "https://ntfy.sh", SLACK = "https://hooks.slack.test/x";
const CALL_TOKEN = "tk_" + "a".repeat(29);
const notifyEnv = { NTFY_TOPIC: "t0pic", SLACK_WEBHOOK_URL: SLACK, NTFY_CALL_TOKEN: CALL_TOKEN, NTFY_CALL_NUMBERS: "+250788000001" };
const org = { ...env, ...notifyEnv, MODE: "org", ADMIN_PUBKEYS: `${ADMIN.trim()}\n${ADMIN2.trim()}` };
const personal = { ...env, ...notifyEnv, MODE: "personal" };

const hub = () => env.HUB.get(env.HUB.idFromName("main"));
const storage = (fn) => runInDurableObject(hub(), (_h, state) => fn(state.storage));
let ipn = 0;
const post = (path, body, e = org, headers = {}) =>
  worker.fetch(new Request(`https://w.test${path}`, {
    method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
    headers: { "CF-Connecting-IP": `198.51.100.${++ipn % 250}`, ...headers },
  }), e);
const note = (body, e = org) => post("/note", body, e);
async function member(enrollBody, approveBody) {
  expect((await post("/enroll", enrollBody)).status).toBe(202);
  expect((await post("/admin", approveBody)).status).toBe(200);
}
const alice = () => member(E_ALICE, A_APPROVE_ALICE);
const bob = () => member(E_BOB, A_APPROVE_BOB);

const enc = new TextEncoder();
async function hmac(body) {
  const key = await crypto.subtle.importKey("raw", enc.encode(env.WEBHOOK_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
  return "sha256=" + [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
}
let dn = 0;
async function push(o = {}, e = org) {
  const body = JSON.stringify({
    ref: "refs/heads/main", before: OLD, after: NEW, forced: false, repository: { full_name: "Acme/App" },
    sender: { login: "bob", type: "User" }, commits: [{ committer: { username: "bob" } }], ...o,
  });
  const r = await worker.fetch(new Request("https://w.test/webhook", {
    method: "POST", body,
    headers: { "X-GitHub-Event": "push", "X-GitHub-Delivery": `od-${++dn}`, "X-Hub-Signature-256": await hmac(body) },
  }), e);
  expect(r.status).toBe(202);
}
// Runs the Hub alarm 20 s later with notify settings in the Hub's own env (as deployed), then returns all events.
async function classifyNow(sec = 20) {
  vi.setSystemTime((TS + sec) * 1000);
  await runInDurableObject(hub(), async (h) => {
    Object.assign(h.env, notifyEnv);
    try { await h.alarm(); } finally { for (const k of Object.keys(notifyEnv)) delete h.env[k]; }
  });
  return storage(async (s) => [...(await s.list({ prefix: "ev:" })).values()]);
}
const lastEvent = async (sec) => (await classifyNow(sec)).at(-1);
let f;
const sent = (url) => f.mock.calls.filter((c) => c[0] === url).map((c) => JSON.parse(c[1].body));
const calls = () => sent(NTFY).filter((b) => b.call);
// push alerts only (enrollment alerts from the member setup are not counted)
const slack = () => sent(SLACK).filter((b) => !b.text.includes("enrollment request"));
const pushNtfy = () => sent(NTFY).filter((b) => !b.call && b.title !== "🟠 gitzilla: enrollment request");

beforeEach(async () => {
  await storage((s) => s.deleteAll());
  f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
  vi.spyOn(console, "error").mockImplementation(() => {});
  vi.useFakeTimers();
  vi.setSystemTime(TS * 1000);
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

// ---- pure classification: the spec table, in order
const NOW = 1_790_812_800;
const P = (o = {}) => ({
  repo: "o/r", ref: "refs/heads/main", before: OLD, after: NEW, forced: false, ts: NOW,
  sender: { login: "bob", type: "User" }, webflow: false, ...o,
});
const C = (o = {}) => ({ logins: [], enrolled: true, allowlisted: false, webFlow: "orange", ...o });
const un = (repo, ref, age = 60) => ({ repo, ref, ts: NOW - age });

describe("classifyOrg", () => {
  it("noted by the sender's own login -> silent", () => {
    expect(classifyOrg(P(), C({ logins: ["bob"] }), [])).toEqual({ level: "silent", flags: [] });
    expect(classifyOrg(P(), C({ logins: ["alice", "bob"] }), [])).toEqual({ level: "silent", flags: [] });
    expect(classifyOrg(P({ forced: true }), C({ logins: ["bob"] }), [])).toEqual({ level: "silent", flags: [] });
    expect(classifyOrg(P({ before: Z }), C({ logins: ["bob"] }), [])).toEqual({ level: "silent", flags: ["created"] });
  });
  it("a note by member A never silences member B's push", () => {
    expect(classifyOrg(P(), C({ logins: ["alice"] }), [])).toEqual({ level: "warning", flags: ["no-note"] });
    expect(classifyOrg(P({ forced: true }), C({ logins: ["alice"] }), [])).toEqual({ level: "critical", flags: ["no-note", "forced"] });
    expect(classifyOrg(P(), C({ logins: ["alice"], enrolled: false }), [])).toEqual({ level: "warning", flags: ["unenrolled"] });
  });
  it("Bot sender type or allowlisted login -> silent bot", () => {
    const bot = { login: "renovate[bot]", type: "Bot" };
    expect(classifyOrg(P({ sender: bot }), C({ enrolled: false }), [])).toEqual({ level: "silent", flags: ["bot"] });
    expect(classifyOrg(P({ sender: { login: "ci-user", type: "User" } }), C({ enrolled: false, allowlisted: true }), []))
      .toEqual({ level: "silent", flags: ["bot"] });
    expect(classifyOrg(P({ sender: bot, after: Z }), C(), [])).toEqual({ level: "silent", flags: ["bot", "deleted"] });
  });
  it("web-flow: orange by default, silent with WEB_FLOW=silent", () => {
    expect(classifyOrg(P({ webflow: true }), C(), [])).toEqual({ level: "warning", flags: ["web-flow"] });
    expect(classifyOrg(P({ webflow: true }), C({ webFlow: undefined }), [])).toEqual({ level: "warning", flags: ["web-flow"] });
    expect(classifyOrg(P({ webflow: true }), C({ webFlow: "silent" }), [])).toEqual({ level: "silent", flags: ["web-flow"] });
    expect(classifyOrg(P({ webflow: true, forced: true }), C(), [])).toEqual({ level: "critical", flags: ["web-flow", "forced"] });
  });
  it("a forced push is never silenced by the bot or web-flow rules", () => {
    const bot = { login: "renovate[bot]", type: "Bot" };
    expect(classifyOrg(P({ sender: bot, forced: true }), C({ enrolled: false }), [])).toEqual({ level: "critical", flags: ["bot", "forced"] });
    expect(classifyOrg(P({ sender: { login: "ci-user", type: "User" }, forced: true }), C({ allowlisted: true }), []))
      .toEqual({ level: "critical", flags: ["bot", "forced"] });
    expect(classifyOrg(P({ webflow: true, forced: true }), C({ webFlow: "silent" }), []))
      .toEqual({ level: "critical", flags: ["web-flow", "forced"] });
    expect(classifyOrg(P({ sender: bot, webflow: true, forced: true, after: Z }), C({ webFlow: "silent" }), []))
      .toEqual({ level: "critical", flags: ["bot", "forced", "deleted"] });
    // the sender's own note still silences (unchanged)
    expect(classifyOrg(P({ webflow: true, forced: true }), C({ logins: ["bob"], webFlow: "silent" }), []))
      .toEqual({ level: "silent", flags: [] });
  });
  it("forced bot pushes count towards a burst; non-forced bot and web-flow pushes are silent", () => {
    const bot = { login: "x[bot]", type: "Bot" };
    const r = classifyOrg(P({ sender: bot, forced: true }), C(), [un("o/x", "refs/heads/a"), un("o/y", "refs/heads/a")]);
    expect(r).toEqual({ level: "critical", flags: ["bot", "forced", "burst"] });
    expect(classifyOrg(P({ sender: bot }), C(), [un("o/x", "refs/heads/a"), un("o/y", "refs/heads/a")]).level).toBe("silent");
    expect(classifyOrg(P({ webflow: true }), C({ webFlow: "silent" }), [un("o/x", "refs/heads/a"), un("o/y", "refs/heads/a")]).level)
      .toBe("silent");
  });
  it("table order: own note beats bot, bot beats web-flow", () => {
    expect(classifyOrg(P({ sender: { login: "x[bot]", type: "Bot" }, webflow: true }), C(), []).flags).toEqual(["bot"]);
    expect(classifyOrg(P({ webflow: true }), C({ logins: ["bob"] }), [])).toEqual({ level: "silent", flags: [] });
  });
  it("enrolled without a note -> no-note; not enrolled -> unenrolled", () => {
    expect(classifyOrg(P(), C(), [])).toEqual({ level: "warning", flags: ["no-note"] });
    expect(classifyOrg(P(), C({ enrolled: false }), [])).toEqual({ level: "warning", flags: ["unenrolled"] });
  });
  it("missing sender -> unenrolled, never silent", () => {
    expect(classifyOrg(P({ sender: null }), C({ enrolled: true, logins: ["bob"], allowlisted: true }), []))
      .toEqual({ level: "warning", flags: ["unenrolled"] });
    expect(classifyOrg(P({ sender: undefined, forced: true }), C(), [])).toEqual({ level: "critical", flags: ["unenrolled", "forced"] });
  });
  it("forced unenrolled -> critical; created/deleted flags as in classify", () => {
    expect(classifyOrg(P({ forced: true }), C({ enrolled: false }), [])).toEqual({ level: "critical", flags: ["unenrolled", "forced"] });
    expect(classifyOrg(P({ before: Z }), C(), [])).toEqual({ level: "warning", flags: ["no-note", "created"] });
    expect(classifyOrg(P({ after: Z }), C({ enrolled: false }), [])).toEqual({ level: "warning", flags: ["unenrolled", "deleted"] });
  });
  it("burst: 3 repos or 5 refs in the window across all pushers -> critical", () => {
    const r = classifyOrg(P(), C(), [un("o/x", "refs/heads/a"), un("o/y", "refs/heads/a")]);
    expect(r).toEqual({ level: "critical", flags: ["no-note", "burst"] });
    const refs = [1, 2, 3, 4].map((i) => un("o/r", `refs/heads/b${i}`));
    expect(classifyOrg(P(), C({ enrolled: false }), refs)).toEqual({ level: "critical", flags: ["unenrolled", "burst"] });
    // outside the window or in the future: not counted
    const old = [un("o/x", "refs/heads/a", BURST_WINDOW_S + 1), un("o/y", "refs/heads/a", -5)];
    expect(classifyOrg(P(), C(), old).level).toBe("warning");
  });
});

describe("formatAlert Pusher line", () => {
  const ev = (o = {}) => ({ seq: 1, ts: NOW, kind: "push", repo: "o/r", ref: "refs/heads/main", before: OLD, after: NEW,
    forced: false, level: "warning", flags: ["no-note"], ...o });
  it("comes right after Ref when set, and the body still ends with the revoke line", () => {
    const { body } = formatAlert([ev({ pusher: "mallory" })]);
    const lines = body.split("\n");
    expect(lines[lines.indexOf("Ref: refs/heads/main") + 1]).toBe("Pusher: mallory");
    expect(body.endsWith("\n\n" + REVOKE)).toBe(true);
  });
  it("is absent when the event has no pusher field (personal mode)", () => {
    expect(formatAlert([ev()]).body).not.toContain("Pusher:");
  });
  it("says unknown for an org push without a usable sender (pusher null)", () => {
    const { body } = formatAlert([ev({ pusher: null })]);
    expect(body).toContain("Ref: refs/heads/main\nPusher: unknown\nCommits:");
    expect(body.endsWith("\n\n" + REVOKE)).toBe(true);
  });
});

describe("sigPublicKey", () => {
  it("returns the signer's key line from an SSHSIG, null for junk", () => {
    expect(sigPublicKey(N_ALICE.sig)).toBe(ALICE.trim().split(" ").slice(0, 2).join(" "));
    expect(sigPublicKey("nope")).toBeNull();
    expect(sigPublicKey("-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----")).toBeNull();
  });
});

// ---- org-mode POST /note: bound to the member that owns the signing key
describe("org /note", () => {
  const row = () => storage((s) => s.get(`note:acme/app|refs/heads/main|${NEW}`));
  it("a member's note is stored with the signer's login", async () => {
    await alice();
    expect((await note(N_ALICE)).status).toBe(204);
    const v = await row();
    expect(v).toEqual({ exp: TS * 1000 + 600_000, logins: ["alice"] });
  });
  it("unknown, admin-only, wrong-namespace and personal-key signatures are 401", async () => {
    await alice();
    expect((await note(N_ADMIN)).status).toBe(401);
    expect((await note(N_WRONGNS)).status).toBe(401);
    expect((await note(NOTE_PERSONAL)).status).toBe(401);
    expect((await note(N_BOB)).status).toBe(401); // bob never enrolled
    expect((await note({ payload: N_ALICE.payload, sig: "junk" })).status).toBe(401);
    expect(await row()).toBeUndefined();
  });
  it("a pending (unapproved) key never verifies", async () => {
    expect((await post("/enroll", E_CAROL)).status).toBe(202);
    expect((await post("/enroll", E_BOB)).status).toBe(202);
    expect((await note(N_CAROL)).status).toBe(401);
    expect((await note(N_BOB)).status).toBe(401);
    expect(await row()).toBeUndefined();
  });
  it("a revoked key fails immediately", async () => {
    await alice();
    expect((await note(N_ALICE)).status).toBe(204);
    expect((await post("/admin", A_REVOKE_ALICE)).status).toBe(200);
    expect((await note(N_ALICE_AGAIN)).status).toBe(401);
  });
  it("a login claimed in the payload is ignored: the key owner is the signer", async () => {
    await alice();
    await bob();
    expect((await note(N_CLAIMS_BOB)).status).toBe(204);
    expect((await row()).logins).toEqual(["alice"]);
  });
  it("a note already signed by 8 members refuses a 9th login with 409 and records nothing", async () => {
    await alice();
    const eight = ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8"];
    const full = { exp: TS * 1000 + 600_000, logins: eight };
    await storage((s) => s.put(`note:acme/app|refs/heads/main|${NEW}`, full));
    const r = await note(N_ALICE);
    expect(r.status).toBe(409);
    expect(await row()).toEqual(full);
    const nonce = JSON.parse(atob(N_ALICE.payload)).nonce;
    expect(await storage((s) => s.get(`nonce:${nonce}`))).toBeUndefined();
    // a login already on the full note may still refresh it
    await storage((s) => s.put(`note:acme/app|refs/heads/main|${NEW}`, { ...full, logins: [...eight.slice(1), "alice"] }));
    vi.setSystemTime((TS + 30) * 1000);
    expect((await note(N_ALICE)).status).toBe(204);
    expect((await row()).exp).toBe((TS + 30) * 1000 + 600_000);
  });
  it("two members noting the same push: both logins, deduped across a member's keys; replay is 409", async () => {
    await alice();
    await member(E_ALICE2, A_APPROVE_ALICE2);
    await bob();
    expect((await note(N_ALICE)).status).toBe(204);
    vi.setSystemTime((TS + 30) * 1000);
    expect((await note(N_BOB)).status).toBe(204);
    expect((await note(N_ALICE2)).status).toBe(204);
    expect((await note(N_BOB)).status).toBe(409);
    expect(await row()).toEqual({ exp: (TS + 30) * 1000 + 600_000, logins: ["alice", "bob"] });
  });
  it("a revoke between key lookup and storing refuses the note", async () => {
    await alice();
    const fp = (await storage((s) => s.list({ prefix: "fp:" }))).keys().next().value.slice(3);
    const r = await runInDurableObject(hub(), (h) =>
      h.addNote("acme/app", "refs/heads/main", NEW, "f".repeat(32), TS, TS * 1000, { login: "bob", fp }));
    expect(r).toBeNull();
    expect(await row()).toBeUndefined();
  });
  it("personal mode keeps the plain expiry value", async () => {
    vi.setSystemTime(JSON.parse(atob(NOTE_PERSONAL.payload)).ts * 1000);
    expect((await note(NOTE_PERSONAL, personal)).status).toBe(204);
    const rows = await storage((s) => s.list({ prefix: "note:" }));
    expect([...rows.values()]).toEqual([TS * 1000 + 600_000]);
  });
});

// ---- org-mode pushes, end to end through the webhook and the Hub alarm
describe("org push classification", () => {
  it("note by member A, push by member B -> not silent", async () => {
    await alice();
    await bob();
    expect((await note(N_ALICE)).status).toBe(204);
    await push({ sender: { login: "bob", type: "User" } });
    const e = await lastEvent();
    expect(e).toMatchObject({ kind: "push", repo: "acme/app", pusher: "bob", level: "warning", flags: ["no-note"] });
  });
  it("note by member A, forced push by unenrolled mallory -> critical", async () => {
    await alice();
    expect((await note(N_ALICE)).status).toBe(204);
    await push({ sender: { login: "mallory", type: "User" }, forced: true });
    expect(await lastEvent()).toMatchObject({ pusher: "mallory", level: "critical", flags: ["unenrolled", "forced"] });
  });
  it("note by enrolled B for B's own push -> silent (login matched case-insensitively)", async () => {
    await bob();
    expect((await note(N_BOB)).status).toBe(204);
    await push({ sender: { login: "Bob", type: "User" } });
    const e = await lastEvent();
    expect(e).toMatchObject({ pusher: "bob", level: "silent", flags: [] });
    expect(slack()).toHaveLength(0);
  });
  it("enrolled member without a note -> orange with the Pusher line", async () => {
    await bob();
    await push();
    expect(await lastEvent()).toMatchObject({ pusher: "bob", level: "warning", flags: ["no-note"] });
    const [sl] = slack();
    expect(sl.text).toContain("Ref: refs/heads/main\nPusher: bob\nCommits:");
    expect(sl.text.endsWith(REVOKE)).toBe(true);
    expect(calls()).toHaveLength(0);
  });
  it("an EMU login with _ (<user>_<shortcode>) is the pusher, not unknown", async () => {
    await push({ sender: { login: "Mallory_Acme", type: "User" }, forced: true });
    expect(await lastEvent()).toMatchObject({ pusher: "mallory_acme", level: "critical", flags: ["unenrolled", "forced"] });
    const [sl] = slack();
    expect(sl.text).toContain("Pusher: mallory_acme");
  });
  it("Bot sender type -> silent bot", async () => {
    await push({ sender: { login: "renovate[bot]", type: "Bot" } });
    expect(await lastEvent()).toMatchObject({ pusher: "renovate[bot]", level: "silent", flags: ["bot"] });
    expect(slack()).toHaveLength(0);
  });
  it("forced push by a Bot sender -> critical alert and a phone call", async () => {
    await push({ sender: { login: "renovate[bot]", type: "Bot" }, forced: true });
    expect(await lastEvent()).toMatchObject({ pusher: "renovate[bot]", level: "critical", flags: ["bot", "forced"] });
    const red = pushNtfy();
    expect(red).toHaveLength(1);
    expect(red[0].priority).toBe(5);
    expect(red[0].message).toContain("Pusher: renovate[bot]");
    expect(red[0].message.endsWith(REVOKE)).toBe(true);
    expect(calls()).toHaveLength(1);
  });
  it("forced web-flow push with WEB_FLOW=silent -> critical", async () => {
    const wf = { commits: [{ committer: { username: "web-flow" } }], forced: true };
    await push(wf, { ...org, WEB_FLOW: "silent" });
    expect(await lastEvent()).toMatchObject({ level: "critical", flags: ["web-flow", "forced"] });
    expect(calls()).toHaveLength(1);
  });
  it("allowlisted bot login -> silent bot; not allowlisted -> unenrolled", async () => {
    await push({ sender: { login: "dependabot[bot]", type: "User" } });
    expect(await lastEvent()).toMatchObject({ level: "warning", flags: ["unenrolled"] });
    expect((await post("/admin", A_ALLOW_BOT)).status).toBe(200);
    vi.setSystemTime((TS + 30) * 1000);
    await push({ sender: { login: "Dependabot[bot]", type: "User" } });
    expect(await lastEvent(60)).toMatchObject({ pusher: "dependabot[bot]", level: "silent", flags: ["bot"] });
  });
  it("web-flow commits: orange by default, silent with WEB_FLOW=silent", async () => {
    const wf = { commits: [{ committer: { username: "web-flow" } }, { committer: { username: "web-flow" } }] };
    await push(wf);
    expect(await lastEvent()).toMatchObject({ level: "warning", flags: ["web-flow"] });
    vi.setSystemTime((TS + 30) * 1000);
    await push(wf, { ...org, WEB_FLOW: "silent" });
    expect(await lastEvent(60)).toMatchObject({ level: "silent", flags: ["web-flow"] });
    // one commit not by web-flow, or no commits at all: not web-flow
    vi.setSystemTime((TS + 70) * 1000);
    await push({ commits: [{ committer: { username: "web-flow" } }, { committer: { username: "bob" } }] }, { ...org, WEB_FLOW: "silent" });
    expect(await lastEvent(100)).toMatchObject({ flags: ["unenrolled"] });
    vi.setSystemTime((TS + 110) * 1000);
    await push({ commits: [] }, { ...org, WEB_FLOW: "silent" });
    expect(await lastEvent(140)).toMatchObject({ flags: ["unenrolled"] });
  });
  it("forced push by an unenrolled sender -> critical alert and a phone call", async () => {
    await push({ sender: { login: "mallory", type: "User" }, forced: true });
    expect(await lastEvent()).toMatchObject({ pusher: "mallory", level: "critical", flags: ["unenrolled", "forced"] });
    const red = pushNtfy();
    expect(red).toHaveLength(1);
    expect(red[0].priority).toBe(5);
    expect(red[0].message).toContain("Pusher: mallory");
    expect(red[0].message.endsWith(REVOKE)).toBe(true);
    expect(calls()).toHaveLength(1);
    expect(calls()[0].call).toBe("+250788000001");
  });
  it("missing or malformed sender -> unenrolled, Pusher: unknown", async () => {
    await push({ sender: undefined });
    expect(await lastEvent()).toMatchObject({ pusher: null, level: "warning", flags: ["unenrolled"] });
    expect(slack()[0].text).toContain("Ref: refs/heads/main\nPusher: unknown\nCommits:");
    vi.setSystemTime((TS + 30) * 1000);
    await push({ sender: { login: "<b>evil</b>", type: "Bot" } });
    expect(await lastEvent(60)).toMatchObject({ pusher: null, level: "warning", flags: ["unenrolled"] });
  });
  it("burst across members: three repos by three different pushers -> critical", async () => {
    await alice();
    await bob();
    await push({ sender: { login: "alice", type: "User" }, repository: { full_name: "acme/one" } });
    vi.setSystemTime((TS + 5) * 1000);
    await push({ sender: { login: "bob", type: "User" }, repository: { full_name: "acme/two" } });
    vi.setSystemTime((TS + 10) * 1000);
    await push({ sender: { login: "mallory", type: "User" }, repository: { full_name: "acme/three" } });
    const ev = await classifyNow(40);
    expect(ev.map((e) => [e.pusher, e.level, e.flags])).toEqual([
      ["alice", "warning", ["no-note"]],
      ["bob", "warning", ["no-note"]],
      ["mallory", "critical", ["unenrolled", "burst"]],
    ]);
  });
  it("silent pushes do not count towards a burst", async () => {
    await bob();
    expect((await note(N_BOB)).status).toBe(204);
    await push({ sender: { login: "x[bot]", type: "Bot" }, repository: { full_name: "acme/one" } });
    await push({ sender: { login: "x[bot]", type: "Bot" }, repository: { full_name: "acme/two" } });
    await push({ sender: { login: "bob", type: "User" } }); // noted -> silent
    vi.setSystemTime((TS + 5) * 1000);
    await push({ sender: { login: "mallory", type: "User" }, repository: { full_name: "acme/three" } });
    const ev = await classifyNow(40);
    expect(ev.map((e) => e.level)).toEqual(["silent", "silent", "silent", "warning"]);
  });
  it("disarmed stays critical in org mode", async () => {
    const body = JSON.stringify({ action: "deleted", installation: { account: { login: "Acme" } } });
    const r = await worker.fetch(new Request("https://w.test/webhook", {
      method: "POST", body,
      headers: { "X-GitHub-Event": "installation", "X-GitHub-Delivery": "dis-1", "X-Hub-Signature-256": await hmac(body) },
    }), org);
    expect(r.status).toBe(202);
    const ev = await storage(async (s) => [...(await s.list({ prefix: "ev:" })).values()]);
    expect(ev).toHaveLength(1);
    expect(ev[0]).toMatchObject({ kind: "disarmed", repo: "acme", level: "critical" });
  });
});

describe("personal mode is unchanged", () => {
  it("a push with sender and web-flow commits classifies as before, without a pusher field", async () => {
    await push({ sender: { login: "bob", type: "Bot" }, commits: [{ committer: { username: "web-flow" } }] }, personal);
    const [e] = await classifyNow();
    expect(e).toEqual({
      seq: 1, delivery: `od-${dn}`, ts: TS, kind: "push", repo: "acme/app", ref: "refs/heads/main",
      before: OLD, after: NEW, forced: false, level: "warning", flags: ["no-note"],
    });
    expect(slack()[0].text).not.toContain("Pusher:");
  });
  it("the default env (MODE from wrangler.toml) is personal too", async () => {
    await push({ sender: { login: "bob", type: "Bot" } }, { ...env });
    const [e] = await classifyNow();
    expect(e.pusher).toBeUndefined();
    expect(e.level).toBe("warning");
  });
});
