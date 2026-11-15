import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { env, runInDurableObject } from "cloudflare:test";
import worker, { verifyAny } from "../src/index.js";
import { fingerprint, parseAdminKeys, cleanLogin, cleanBotLogin, cleanPubkey, ipBucket } from "../src/members.js";
import ADMIN from "./fixtures/org/admin.pub?raw";
import ADMIN2 from "./fixtures/org/admin2.pub?raw";
import ALICE from "./fixtures/org/alice.pub?raw";
import ALICE_FP from "./fixtures/org/alice.fp?raw";
import ALICE2_FP from "./fixtures/org/alice2.fp?raw";
import BOB from "./fixtures/org/bob.pub?raw";
import BOB_FP from "./fixtures/org/bob.fp?raw";
import ADMIN_FP from "./fixtures/org/admin.fp?raw";
import ADMIN2_FP from "./fixtures/org/admin2.fp?raw";
import QUEUE_ADMIN from "./fixtures/org/queue-auth-admin.txt?raw";
import QUEUE_NOTE from "./fixtures/queue-auth-ok.txt?raw";
import ALERT_ADMIN from "./fixtures/org/alert-test-admin.json";
import ALERT_NOTE from "./fixtures/alert-test.json";
import REPORT_ADMIN from "./fixtures/org/report-admin.json";
import REPORT_NOTE from "./fixtures/report-ok.json";
import E_ALICE from "./fixtures/org/enroll-alice.json";
import E_ALICE_AGAIN from "./fixtures/org/enroll-alice-again.json";
import E_ALICE2 from "./fixtures/org/enroll-alice2.json";
import E_BOB from "./fixtures/org/enroll-bob.json";
import E_UPPER from "./fixtures/org/enroll-upper.json";
import E_WRONGNS from "./fixtures/org/enroll-wrongns.json";
import E_BADSIG from "./fixtures/org/enroll-badsig.json";
import E_TAMPERED from "./fixtures/org/enroll-tampered.json";
import E_BADLOGIN from "./fixtures/org/enroll-badlogin.json";
import E_DASHLOGIN from "./fixtures/org/enroll-dashlogin.json";
import E_EXTRA from "./fixtures/org/enroll-extra.json";
import E_LATER from "./fixtures/org/enroll-later.json";
import A_APPROVE_ALICE from "./fixtures/org/admin-approve-alice.json";
import A_APPROVE_ALICE2 from "./fixtures/org/admin-approve-alice2.json";
import A_APPROVE_BOB from "./fixtures/org/admin-approve-bob.json";
import A_APPROVE_BOB_ADMIN2 from "./fixtures/org/admin-approve-bob-by-admin2.json";
import A_REVOKE_ALICE from "./fixtures/org/admin-revoke-alice.json";
import A_REVOKE_ALICE_FP from "./fixtures/org/admin-revoke-alice-fp.json";
import A_REVOKE_BOB from "./fixtures/org/admin-revoke-bob.json";
import A_LIST0 from "./fixtures/org/admin-list-0.json";
import A_LIST1 from "./fixtures/org/admin-list-1.json";
import A_LIST2 from "./fixtures/org/admin-list-2.json";
import A_LIST3 from "./fixtures/org/admin-list-3.json";
import A_LIST_ADMIN2 from "./fixtures/org/admin-list-admin2.json";
import A_ALLOW_BOT from "./fixtures/org/admin-allow-bot.json";
import A_DISALLOW_BOT from "./fixtures/org/admin-disallow-bot.json";
import A_UNKNOWN from "./fixtures/org/admin-unknown.json";
import A_BADARGS from "./fixtures/org/admin-badargs.json";
import A_EXTRAARGS from "./fixtures/org/admin-extraargs.json";
import A_BADFP from "./fixtures/org/admin-badfp.json";
import A_BY_MEMBER from "./fixtures/org/admin-by-member.json";
import A_APPROVE_BY_MEMBER from "./fixtures/org/admin-approve-by-member.json";
import A_WRONGNS from "./fixtures/org/admin-wrongns.json";
import A_LATE from "./fixtures/org/admin-late.json";

const REVOKE = "If this wasn't you: revoke tokens at https://github.com/settings/applications";
const TS = 4102444800;
const fpA = ALICE_FP.trim(), fpA2 = ALICE2_FP.trim(), fpB = BOB_FP.trim();
const NTFY = "https://ntfy.sh", SLACK = "https://hooks.slack.test/x";
const CALL_TOKEN = "tk_" + "a".repeat(29);
const base = { ...env, NTFY_TOPIC: "t0pic", SLACK_WEBHOOK_URL: SLACK, NTFY_CALL_TOKEN: CALL_TOKEN, NTFY_CALL_NUMBERS: "+250788000001" };
const org = { ...base, MODE: "org", ADMIN_PUBKEYS: `${ADMIN.trim()}\n${ADMIN2.trim()}` };
const personal = { ...base, MODE: "personal" };

let ipn = 0;
const post = (path, body, e = org, ip, headers = {}) =>
  worker.fetch(new Request(`https://w.test${path}`, {
    method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
    headers: { "CF-Connecting-IP": ip ?? `203.0.113.${++ipn % 250}`, ...headers },
  }), e);
const enroll = (body, e, ip) => post("/enroll", body, e, ip);
const admin = (body, e) => post("/admin", body, e);
const list = async (body = A_LIST0) => {
  const r = await admin(body);
  expect(r.status).toBe(200);
  return r.json();
};
const queue = (auth, e) =>
  worker.fetch(new Request("https://w.test/queue?after=0", { headers: { "X-Gitzilla-Auth": auth.trim() } }), e);
const hub = () => env.HUB.get(env.HUB.idFromName("main"));
const storage = (fn) => runInDurableObject(hub(), (_h, state) => fn(state.storage));
let f;
const sent = (url) => f.mock.calls.filter((c) => c[0] === url).map((c) => JSON.parse(c[1].body));

beforeEach(async () => {
  await storage((s) => s.deleteAll());
  f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
  vi.useFakeTimers();
  vi.setSystemTime(TS * 1000);
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe("members.js", () => {
  it("fingerprint matches ssh-keygen -lf for fixture keys", async () => {
    expect(await fingerprint(ALICE)).toBe(fpA);
    expect(await fingerprint(BOB.trim())).toBe(fpB);
    expect(await fingerprint(ADMIN)).toBe(ADMIN_FP.trim());
    expect(fpA).toMatch(/^SHA256:[A-Za-z0-9+/]{43}$/);
  });
  it("fingerprint and cleanPubkey reject non-nistp256 or malformed keys", async () => {
    expect(await fingerprint("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")).toBeNull();
    expect(await fingerprint("ecdsa-sha2-nistp256 AAAA")).toBeNull();
    expect(cleanPubkey("ecdsa-sha2-nistp256 !!!")).toBeNull();
    expect(cleanPubkey(ALICE)).toBe(ALICE.trim().split(" ").slice(0, 2).join(" "));
  });
  it("validates logins", () => {
    expect(cleanLogin("Alice")).toBe("alice");
    expect(cleanLogin("a-b-1")).toBe("a-b-1");
    expect(cleanLogin("-a")).toBeNull();
    expect(cleanLogin("a".repeat(40))).toBeNull();
    expect(cleanLogin("a".repeat(39))).toBe("a".repeat(39));
    expect(cleanLogin("a_b")).toBeNull();
    expect(cleanLogin("dependabot[bot]")).toBeNull();
    expect(cleanBotLogin("Dependabot[bot]")).toBe("dependabot[bot]");
  });
  it("parses ADMIN_PUBKEYS separated by newlines or commas, max 3, failing closed", () => {
    const a = ADMIN.trim(), b = ADMIN2.trim(), c = BOB.trim(), d = ALICE.trim();
    expect(parseAdminKeys(`${a}\n${b}`)).toHaveLength(2);
    expect(parseAdminKeys(`${a}, ${b},${c}`)).toHaveLength(3);
    expect(parseAdminKeys("")).toEqual([]);
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(parseAdminKeys(`${a}\n${b}\n${c}\n${d}`)).toEqual([]);
    expect(parseAdminKeys(`${a}\nssh-rsa AAAA`)).toEqual([]);
  });
  it("parseAdminKeys is memoized per value: a bad value logs once", () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const bad = `${ADMIN.trim()}\nssh-rsa AAAA # memo-test`;
    for (let i = 0; i < 5; i++) expect(parseAdminKeys(bad)).toEqual([]);
    expect(err).toHaveBeenCalledTimes(1);
    expect(parseAdminKeys(ADMIN)).toEqual([cleanPubkey(ADMIN)]);
    expect(err).toHaveBeenCalledTimes(1);
  });
  it("verifyAny returns the key that verified, or null", async () => {
    const r = JSON.parse(atob(A_LIST_ADMIN2.payload));
    const raw = Uint8Array.from(atob(A_LIST_ADMIN2.payload), (c) => c.charCodeAt(0));
    expect(r.cmd).toBe("list");
    expect(await verifyAny(A_LIST_ADMIN2.sig, raw, "gitzilla-admin", [ADMIN.trim(), ADMIN2.trim()])).toBe(ADMIN2.trim());
    expect(await verifyAny(A_LIST_ADMIN2.sig, raw, "gitzilla-admin", [ADMIN.trim()])).toBeNull();
    expect(await verifyAny(A_LIST_ADMIN2.sig, raw, "gitzilla-enroll", [ADMIN2.trim()])).toBeNull();
    expect(await verifyAny(A_LIST_ADMIN2.sig, raw, "gitzilla-admin", [])).toBeNull();
  });
});

describe("POST /enroll", () => {
  it("happy path: 202, pending entry, one orange alert to ntfy and Slack, no call", async () => {
    const r = await enroll(E_ALICE);
    expect(r.status).toBe(202);
    expect(await r.json()).toEqual({ ok: true, fingerprint: fpA });
    const p = await storage((s) => s.get(`pending:alice:${fpA}`));
    expect(p).toEqual({ pubkey: cleanPubkey(ALICE), ts: TS });
    const [n] = sent(NTFY), [s] = sent(SLACK);
    expect(n.topic).toBe("t0pic");
    expect(n.priority).toBe(3);
    expect(n.title).toBe("🟠 gitzilla: enrollment request");
    expect(n.message).toBe(`Login: alice\nKey: ${fpA}\n\n${REVOKE}`);
    expect(s.text).toBe(`${n.title}\n${n.message}`);
    // exactly two posts: ntfy + Slack, never the call topic
    expect(f).toHaveBeenCalledTimes(2);
    expect(f.mock.calls.some((c) => String(c[1]?.body).includes("-call"))).toBe(false);
  });
  it("lowercases the login", async () => {
    expect((await enroll(E_UPPER)).status).toBe(202);
    expect(await storage((s) => s.get(`pending:bob:${fpB}`))).toBeDefined();
  });
  it("a pending enrollment is not a member", async () => {
    expect((await enroll(E_ALICE)).status).toBe(202);
    expect(await hub().isMemberKey("alice", fpA)).toBe(false);
    expect((await list()).members).toEqual([]);
  });
  it.each([
    ["signature by a different key than the payload's pubkey", E_BADSIG, 401],
    ["payload tampered after signing", E_TAMPERED, 401],
    ["signature in the admin namespace", E_WRONGNS, 401],
    ["login with bad characters", E_BADLOGIN, 400],
    ["login starting with a dash", E_DASHLOGIN, 400],
    ["extra payload field", E_EXTRA, 400],
  ])("rejects %s (%i) with no pending entry and no alert", async (_n, body, status) => {
    expect((await enroll(body)).status).toBe(status);
    expect((await storage((s) => s.list({ prefix: "pending:" }))).size).toBe(0);
    expect(f).not.toHaveBeenCalled();
  });
  it("rejects ts more than 5 minutes off with 401", async () => {
    vi.setSystemTime((TS + 301) * 1000); // 301 s after E_ALICE, 299 s before E_LATER
    expect((await enroll(E_ALICE)).status).toBe(401);
    expect((await enroll(E_LATER)).status).toBe(202);
  });
  it("rejects a replayed nonce with 401 and alerts once", async () => {
    expect((await enroll(E_ALICE)).status).toBe(202);
    expect((await enroll(E_ALICE)).status).toBe(401);
    expect(sent(NTFY)).toHaveLength(1);
  });
  it("re-enrolling the same login+key while pending refreshes ts, one entry, no second alert", async () => {
    expect((await enroll(E_ALICE)).status).toBe(202);
    vi.setSystemTime((TS + 120) * 1000);
    expect((await enroll(E_ALICE_AGAIN)).status).toBe(202);
    const rows = await storage((s) => s.list({ prefix: "pending:" }));
    expect([...rows.values()]).toEqual([{ pubkey: cleanPubkey(ALICE), ts: TS + 120 }]);
    expect(sent(NTFY)).toHaveLength(1);
  });
  it("rate limits to 10 per hour per IP (bad requests count), others unaffected; no alert when limited", async () => {
    const ip = "198.51.100.7";
    for (let i = 0; i < 10; i++) expect((await enroll(E_BADSIG, org, ip)).status).toBe(401);
    expect((await enroll(E_ALICE, org, ip)).status).toBe(429);
    expect(f).not.toHaveBeenCalled();
    expect((await enroll(E_ALICE, org, "198.51.100.8")).status).toBe(202);
    // next clock hour: the counter resets and the first request sweeps past-hour counters
    vi.setSystemTime(Math.ceil((TS * 1000 + 1) / 3_600_000) * 3_600_000 + 1000);
    const hourNow = Math.floor(Date.now() / 3_600_000);
    expect(await hub().enrollRateOk(ip, Date.now())).toBe(true);
    const keys = [...(await storage((s) => s.list({ prefix: "rl:" }))).keys()];
    expect(keys.sort()).toEqual([`rl:${ip}:${hourNow}`, `rl:all:${hourNow}`]);
  });
  it("a global cap of 100 attempts per hour across all IPs comes first: 429, no alert, no row", async () => {
    for (let i = 0; i < 100; i++) expect((await enroll(E_BADSIG, org, `192.0.2.${i}`)).status).toBe(401);
    expect((await enroll(E_ALICE, org, "198.51.100.200")).status).toBe(429);
    expect(f).not.toHaveBeenCalled();
    const rl = await storage((s) => s.list({ prefix: "rl:" }));
    expect(rl.size).toBe(101); // 100 client buckets + the global one; the refused client got no row
    expect(rl.has("rl:198.51.100.200:" + Math.floor(Date.now() / 3_600_000))).toBe(false);
    expect((await storage((s) => s.list({ prefix: "pending:" }))).size).toBe(0);
  }, 20_000);
  it("IPv6 addresses in one /64 share a bucket; another /64 does not", async () => {
    for (let i = 0; i < 10; i++) {
      expect((await enroll(E_BADSIG, org, `2001:db8:1:2::${(i + 1).toString(16)}`)).status).toBe(401);
    }
    expect((await enroll(E_ALICE, org, "2001:db8:1:2:ffff:ffff:ffff:ffff")).status).toBe(429);
    expect((await enroll(E_ALICE, org, "2001:db8:1:3::1")).status).toBe(202);
  });
  it("ipBucket: IPv4 as is, IPv6 by /64, mapped IPv4 as IPv4, junk in one bucket", () => {
    expect(ipBucket("198.51.100.7")).toBe("198.51.100.7");
    expect(ipBucket("2001:DB8:0001:0002:aaaa::1")).toBe("2001:db8:1:2::/64");
    expect(ipBucket("2001:db8:1:2:3:4:5:6")).toBe("2001:db8:1:2::/64");
    expect(ipBucket("2001:db8::")).toBe("2001:db8:0:0::/64");
    expect(ipBucket("::1")).toBe("0:0:0:0::/64");
    expect(ipBucket("::ffff:198.51.100.7")).toBe("198.51.100.7");
    for (const junk of [null, "", "unknown", "1::2::3", "1:2:3:4:5:6:7:8:9", "12345::", "a:b", "x".repeat(60)]) {
      expect(ipBucket(junk)).toBe("?");
    }
  });
  it("past-hour rl: rows and expired enonce: rows are swept once per hour, not on every request", async () => {
    const hour = Math.floor(Date.now() / 3_600_000);
    expect((await enroll(E_BADSIG)).status).toBe(401); // first request this hour: sweep runs, marker set
    // stale rows planted after this hour's sweep survive further requests in the same hour
    await storage((s) => s.put({ [`rl:192.0.2.9:${hour - 1}`]: 3, "enonce:stale": Date.now() - 1 }));
    for (let i = 0; i < 3; i++) expect((await enroll(E_BADSIG)).status).toBe(401);
    expect(await storage((s) => s.get(`rl:192.0.2.9:${hour - 1}`))).toBe(3);
    expect(await storage((s) => s.get("enonce:stale"))).toBeDefined();
    // first request of the next hour sweeps them
    vi.setSystemTime((hour + 1) * 3_600_000 + 1000);
    expect((await enroll(E_BADSIG)).status).toBe(401);
    expect(await storage((s) => s.get(`rl:192.0.2.9:${hour - 1}`))).toBeUndefined();
    expect(await storage((s) => s.get("enonce:stale"))).toBeUndefined();
  });
  it("enrollment nonces live under enonce:, never the shared nonce: store", async () => {
    expect((await enroll(E_ALICE)).status).toBe(202);
    const n = JSON.parse(atob(E_ALICE.payload)).nonce;
    expect(await storage((s) => s.get(`enonce:${n}`))).toBeGreaterThan(Date.now());
    expect((await storage((s) => s.list({ prefix: "nonce:" }))).size).toBe(0);
  });
  it("rejects bodies over 8192 bytes: by Content-Length before reading, and by bytes read", async () => {
    // declared too large: refused before the rate limiter or the body is touched
    const r1 = await post("/enroll", E_ALICE, org, "198.51.100.50", { "Content-Length": "9000" });
    expect(r1.status).toBe(400);
    expect((await storage((s) => s.list({ prefix: "rl:" }))).size).toBe(0);
    expect((await post("/admin", A_LIST0, org, undefined, { "Content-Length": "9000" })).status).toBe(400);
    // 3000 three-byte characters: 3000 UTF-16 units but 9000 bytes
    const multibyte = JSON.stringify({ payload: "€".repeat(3000), sig: "x" });
    const stream = () => new ReadableStream({
      start(c) { c.enqueue(new TextEncoder().encode(multibyte)); c.close(); },
    });
    for (const path of ["/enroll", "/admin"]) {
      const req = new Request(`https://w.test${path}`, {
        method: "POST", body: stream(), duplex: "half", headers: { "CF-Connecting-IP": "198.51.100.51" },
      });
      const r = await worker.fetch(req, org);
      expect(r.status).toBe(400);
      expect((await r.json()).error).toBe("too large");
    }
  });
  it("refuses a new pending entry beyond 200 with 429 and keeps the existing ones", async () => {
    await storage(async (s) => {
      for (let i = 0; i < 200; i += 100) {
        const batch = {};
        for (let j = i; j < i + 100; j++) batch[`pending:u${j}:SHA256:x${j}`] = { pubkey: "k", ts: TS };
        await s.put(batch);
      }
    });
    expect((await enroll(E_ALICE)).status).toBe(429);
    expect((await storage((s) => s.list({ prefix: "pending:" }))).size).toBe(200);
    expect(f).not.toHaveBeenCalled();
  });
  it("expired pending entries (7 days) do not count against the cap and are removed", async () => {
    await storage(async (s) => {
      const batch = {};
      for (let j = 0; j < 100; j++) batch[`pending:u${j}:SHA256:x${j}`] = { pubkey: "k", ts: TS - 8 * 86_400 };
      await s.put(batch);
      const b2 = {};
      for (let j = 100; j < 200; j++) b2[`pending:u${j}:SHA256:x${j}`] = { pubkey: "k", ts: TS - 8 * 86_400 };
      await s.put(b2);
    });
    expect((await enroll(E_ALICE)).status).toBe(202);
    expect((await storage((s) => s.list({ prefix: "pending:" }))).size).toBe(1);
  });
  it("enrolling a key that is already a member returns 409 with no alert", async () => {
    expect((await enroll(E_ALICE)).status).toBe(202);
    expect((await admin(A_APPROVE_ALICE)).status).toBe(200);
    f.mockClear();
    expect((await enroll(E_ALICE_AGAIN)).status).toBe(409);
    expect(f).not.toHaveBeenCalled();
    expect((await list()).pending).toEqual([]);
  });
  it("is 404 in personal mode and with MODE unset", async () => {
    expect((await enroll(E_ALICE, personal)).status).toBe(404);
    expect((await enroll(E_ALICE, { ...base, MODE: undefined })).status).toBe(404);
    expect((await enroll(E_ALICE, env)).status).toBe(404); // wrangler.toml default: MODE = "personal"
    expect((await admin(A_LIST0, personal)).status).toBe(404);
    expect((await storage((s) => s.list({ prefix: "pending:" }))).size).toBe(0);
    expect(f).not.toHaveBeenCalled();
  });
});

describe("POST /admin", () => {
  it("approve moves pending to member with added_by = admin fingerprint", async () => {
    await enroll(E_ALICE);
    const r = await admin(A_APPROVE_ALICE);
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true });
    const m = await storage((s) => s.get("member:alice"));
    expect(m).toEqual([{ pubkey: cleanPubkey(ALICE), fp: fpA, added_ts: TS, added_by: ADMIN_FP.trim() }]);
    expect(await hub().isMemberKey("alice", fpA)).toBe(true);
    expect(await hub().isMemberKey("bob", fpA)).toBe(false);
    expect(await storage((s) => s.get(`pending:alice:${fpA}`))).toBeUndefined();
  });
  it("a second admin key works and is recorded as added_by", async () => {
    await enroll(E_BOB);
    expect((await admin(A_APPROVE_BOB_ADMIN2)).status).toBe(200);
    expect((await storage((s) => s.get("member:bob")))[0].added_by).toBe(ADMIN2_FP.trim());
    expect((await admin(A_LIST_ADMIN2)).status).toBe(200);
  });
  it("list returns members, pending and bots", async () => {
    await enroll(E_ALICE);
    await enroll(E_ALICE2);
    await enroll(E_BOB);
    await admin(A_APPROVE_ALICE);
    await admin(A_APPROVE_ALICE2);
    await admin(A_ALLOW_BOT);
    expect(await list()).toEqual({
      members: [{ login: "alice", fps: [fpA, fpA2] }],
      pending: [{ login: "bob", fp: fpB, ts: TS }],
      bots: ["dependabot[bot]"],
    });
  });
  it("revoke with a fingerprint removes one key; without, the whole member", async () => {
    await enroll(E_ALICE);
    await enroll(E_ALICE2);
    await admin(A_APPROVE_ALICE);
    await admin(A_APPROVE_ALICE2);
    expect((await admin(A_REVOKE_ALICE_FP)).status).toBe(200);
    expect((await list(A_LIST0)).members).toEqual([{ login: "alice", fps: [fpA2] }]);
    expect(await hub().isMemberKey("alice", fpA)).toBe(false);
    expect((await admin(A_REVOKE_ALICE)).status).toBe(200);
    expect((await list(A_LIST1)).members).toEqual([]);
    expect(await hub().isMemberKey("alice", fpA2)).toBe(false);
    expect((await storage((s) => s.list({ prefix: "fp:" }))).size).toBe(0);
  });
  it("revoke also rejects a pending enrollment; revoke of nothing is 404", async () => {
    await enroll(E_BOB);
    expect((await admin(A_REVOKE_BOB)).status).toBe(200);
    expect((await list()).pending).toEqual([]);
    expect((await admin(A_REVOKE_ALICE)).status).toBe(404);
  });
  it("allow-bot / disallow-bot", async () => {
    expect((await admin(A_ALLOW_BOT)).status).toBe(200);
    expect(await storage((s) => s.get("bot:dependabot[bot]"))).toEqual({ added_ts: TS, added_by: ADMIN_FP.trim() });
    expect((await list(A_LIST0)).bots).toEqual(["dependabot[bot]"]);
    expect((await admin(A_DISALLOW_BOT)).status).toBe(200);
    expect((await list(A_LIST1)).bots).toEqual([]);
  });
  it("approve of a key that is not pending is 404 and adds nothing", async () => {
    const r = await admin(A_APPROVE_BOB);
    expect(r.status).toBe(404);
    expect(await r.json()).toHaveProperty("error");
    expect((await list()).members).toEqual([]);
  });
  it("approve of an expired pending enrollment is 404", async () => {
    await enroll(E_ALICE);
    vi.setSystemTime((TS + 7 * 86_400) * 1000);
    expect(await hub().admin("approve", { login: "alice", fingerprint: fpA }, "SHA256:x", Date.now()))
      .toEqual({ status: 404, body: { error: "no such pending enrollment" } });
  });
  it("a member key cannot run admin commands (401), even after approval", async () => {
    expect((await admin(A_BY_MEMBER)).status).toBe(401);
    await enroll(E_ALICE);
    await admin(A_APPROVE_ALICE);
    await storage((s) => s.delete("member:alice")); // so a successful self-approve would be visible
    await enroll(E_ALICE_AGAIN);
    expect((await admin(A_APPROVE_BY_MEMBER)).status).toBe(401);
    expect(await storage((s) => s.get("member:alice"))).toBeUndefined();
  });
  it("rejects the enroll namespace, a replayed nonce and a stale ts with 401", async () => {
    expect((await admin(A_WRONGNS)).status).toBe(401);
    expect((await admin(A_LIST0)).status).toBe(200);
    expect((await admin(A_LIST0)).status).toBe(401);
    expect((await admin(A_LATE)).status).toBe(401); // ts 6 min ahead
    vi.setSystemTime((TS + 360) * 1000);
    expect((await admin(A_LATE)).status).toBe(200);
  });
  it("unknown command and bad args are 400 JSON errors", async () => {
    for (const b of [A_UNKNOWN, A_BADARGS, A_EXTRAARGS, A_BADFP]) {
      const r = await admin(b);
      expect(r.status).toBe(400);
      expect(r.headers.get("content-type")).toBe("application/json");
      expect(typeof (await r.json()).error).toBe("string");
    }
  });
  it("no admin keys configured: everything is 401", async () => {
    expect((await admin(A_LIST0, { ...org, ADMIN_PUBKEYS: "" })).status).toBe(401);
    vi.spyOn(console, "error").mockImplementation(() => {});
    const four = [ADMIN, ADMIN2, ALICE, BOB].map((k) => k.trim()).join("\n");
    expect((await admin(A_LIST0, { ...org, ADMIN_PUBKEYS: four })).status).toBe(401);
  });
  it("refuses a 9th key for a member with 409 and keeps the pending entry", async () => {
    await enroll(E_ALICE);
    await storage((s) => s.put("member:alice",
      Array.from({ length: 8 }, (_, i) => ({ pubkey: "k", fp: `SHA256:k${i}`, added_ts: TS, added_by: "a" }))));
    expect((await admin(A_APPROVE_ALICE)).status).toBe(409);
    expect((await storage((s) => s.get("member:alice")))).toHaveLength(8);
    expect(await storage((s) => s.get(`pending:alice:${fpA}`))).toBeDefined();
  });
  it("refuses a 2001st member with 409", async () => {
    await storage(async (s) => {
      for (let i = 0; i < 2000; i += 100) {
        const b = {};
        for (let j = i; j < i + 100; j++) b[`member:m${j}`] = [{ pubkey: "k", fp: `SHA256:m${j}`, added_ts: TS, added_by: "a" }];
        await s.put(b);
      }
    });
    await enroll(E_BOB);
    expect((await admin(A_APPROVE_BOB)).status).toBe(409);
    expect(await storage((s) => s.get("member:bob"))).toBeUndefined();
  }, 20_000);
  it("a key can belong to only one login", async () => {
    await enroll(E_ALICE);
    await admin(A_APPROVE_ALICE);
    // forge a pending entry for bob with alice's key (enroll itself refuses member keys)
    await storage((s) => s.put(`pending:bob:${fpA}`, { pubkey: cleanPubkey(ALICE), ts: TS }));
    expect(await hub().admin("approve", { login: "bob", fingerprint: fpA }, "SHA256:x", Date.now()))
      .toEqual({ status: 409, body: { error: "key belongs to another member" } });
  });
});

describe("control-route auth by mode", () => {
  it("queue: admin keys in org mode, NOTE_PUBKEY in personal mode", async () => {
    expect((await queue(QUEUE_ADMIN, org)).status).toBe(200);
    expect((await queue(QUEUE_NOTE, org)).status).toBe(401);
    expect((await queue(QUEUE_NOTE, personal)).status).toBe(200);
    expect((await queue(QUEUE_ADMIN, personal)).status).toBe(401);
    expect((await queue(QUEUE_NOTE, env)).status).toBe(200);
  });
  it("report: admin keys in org mode, NOTE_PUBKEY in personal mode", async () => {
    expect((await post("/report", REPORT_NOTE, org)).status).toBe(401);
    expect((await post("/report", REPORT_ADMIN, personal)).status).toBe(401);
    expect((await post("/report", REPORT_ADMIN, org)).status).toBe(204);
    expect((await post("/report", REPORT_NOTE, personal)).status).toBe(204);
  });
  it("alert: admin keys in org mode, NOTE_PUBKEY in personal mode", async () => {
    expect((await post("/alert", ALERT_NOTE, org)).status).toBe(401);
    expect((await post("/alert", ALERT_ADMIN, personal)).status).toBe(401);
    expect((await post("/alert", ALERT_ADMIN, org)).status).toBe(204);
    expect((await post("/alert", ALERT_NOTE, personal)).status).toBe(204);
  });
});

describe("GET /health (org mode)", () => {
  const health = (e) => worker.fetch(new Request("https://w.test/health"), e);
  it("reports mode and lowercased org login in org mode", async () => {
    const r = await health({ ...org, ORG: "Acme-Corp" });
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true, mode: "org", org: "acme-corp" });
  });
  it("reports org null when ORG is unset or invalid", async () => {
    expect(await (await health({ ...org, ORG: "" })).json()).toEqual({ ok: true, mode: "org", org: null });
    expect(await (await health({ ...org, ORG: "-bad" })).json()).toEqual({ ok: true, mode: "org", org: null });
  });
  it("is unchanged in personal mode", async () => {
    expect(await (await health({ ...personal, ORG: "acme" })).json()).toEqual({ ok: true });
  });
});
