import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { SELF, env, runInDurableObject, runDurableObjectAlarm } from "cloudflare:test";
import NOTE from "./fixtures/note-ok.json";
import QUEUE_OK from "./fixtures/queue-auth-ok.txt?raw";
import QUEUE_TAMPERED from "./fixtures/queue-auth-tampered.txt?raw";
import QUEUE_WRONGNS from "./fixtures/queue-auth-wrongns.txt?raw";

const note = JSON.parse(atob(NOTE.payload));
const T0 = note.ts * 1000;
const hub = () => env.HUB.get(env.HUB.idFromName("main"));
const enc = new TextEncoder();

async function hmac(body) {
  const key = await crypto.subtle.importKey("raw", enc.encode(env.WEBHOOK_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(body)));
  return "sha256=" + [...sig].map((b) => b.toString(16).padStart(2, "0")).join("");
}
let n = 0;
async function hook(event, payload, { sig, delivery } = {}) {
  const body = JSON.stringify(payload);
  return SELF.fetch("https://w.test/webhook", {
    method: "POST",
    body,
    headers: {
      "X-GitHub-Event": event,
      "X-GitHub-Delivery": delivery ?? `d-${++n}`,
      "X-Hub-Signature-256": sig ?? (await hmac(body)),
    },
  });
}
const pushPayload = (o = {}) => ({
  ref: note.ref, before: note.old_sha, after: note.new_sha, forced: false,
  repository: { full_name: "Owner/Name" }, ...o,
});
const postNote = () => SELF.fetch("https://w.test/note", { method: "POST", body: JSON.stringify(NOTE) });
const queue = (after = 0, auth = QUEUE_OK.trim()) =>
  SELF.fetch(`https://w.test/queue?after=${after}`, { headers: auth === null ? {} : { "X-Watchdog-Auth": auth } });
const events = async (after = 0) => (await (await queue(after)).json());
const at = (secFromT0) => vi.setSystemTime(T0 + secFromT0 * 1000);
const alarm = () => runDurableObjectAlarm(hub());

beforeEach(async () => {
  await runInDurableObject(hub(), (_h, state) => state.storage.deleteAll());
  vi.useFakeTimers();
  at(0);
});
afterEach(() => vi.useRealTimers());

describe("POST /webhook", () => {
  it("rejects a bad HMAC with 401 and queues nothing", async () => {
    expect((await hook("push", pushPayload(), { sig: "sha256=" + "0".repeat(64) })).status).toBe(401);
    expect((await hook("push", pushPayload(), { sig: "nope" })).status).toBe(401);
    expect(await alarm()).toBe(false);
  });
  it("ignores other event types with 204", async () => {
    expect((await hook("ping", { zen: "x" })).status).toBe(204);
    expect(await alarm()).toBe(false);
  });
  it("classifies a push with a matching note as silent after 20 s", async () => {
    expect((await postNote()).status).toBe(204);
    expect((await hook("push", pushPayload(), { delivery: "dlv-1" })).status).toBe(202);
    expect((await events()).events).toEqual([]);
    at(20);
    expect(await alarm()).toBe(true);
    const { events: ev, next } = await events();
    expect(ev).toHaveLength(1);
    expect(ev[0]).toEqual({
      seq: 1, delivery: "dlv-1", ts: note.ts + 0, kind: "push", repo: "owner/name", ref: note.ref,
      before: note.old_sha, after: note.new_sha, forced: false, level: "silent", flags: [],
    });
    expect(next).toBe(1);
  });
  it("a push without a note is a warning; forced is critical", async () => {
    await hook("push", pushPayload());
    await hook("push", pushPayload({ forced: true, after: "3".repeat(40) }));
    at(20);
    await alarm();
    const { events: ev } = await events();
    expect(ev.map((e) => [e.level, e.flags])).toEqual([
      ["warning", ["no-note"]],
      ["critical", ["no-note", "forced"]],
    ]);
  });
  it("a note arriving 15 s after the webhook still counts", async () => {
    await hook("push", pushPayload());
    at(15);
    expect((await postNote()).status).toBe(204);
    at(20);
    await alarm();
    expect((await events()).events[0].level).toBe("silent");
  });
  it("a note for a different sha does not match", async () => {
    await postNote();
    await hook("push", pushPayload({ after: "4".repeat(40) }));
    at(20);
    await alarm();
    expect((await events()).events[0].level).toBe("warning");
  });
  it("classifies on time even when a note with a later expiry arrives afterwards", async () => {
    await hook("push", pushPayload());
    const t = await runInDurableObject(hub(), (_h, s) => s.storage.getAlarm());
    expect(t).toBe(T0 + 20_000);
    at(5);
    await postNote(); // its note/nonce expire ~10 min out; must not push the alarm back
    expect(await runInDurableObject(hub(), (_h, s) => s.storage.getAlarm())).toBe(T0 + 20_000);
    at(20);
    await alarm();
    const { events: ev } = await events();
    expect(ev).toHaveLength(1);
    expect(ev[0].level).toBe("silent");
    // and the alarm is re-armed for the next outstanding deadline (note/nonce expiry)
    expect(await runInDurableObject(hub(), (_h, s) => s.storage.getAlarm())).toBeGreaterThan(T0 + 20_000);
  });
  it("flags a burst across repos using the stored un-noted window", async () => {
    for (const [i, repo] of ["o/a", "o/b", "o/c"].entries()) {
      at(i);
      await hook("push", pushPayload({ repository: { full_name: repo } }));
    }
    at(30);
    await alarm();
    const { events: ev } = await events();
    expect(ev.map((e) => e.level)).toEqual(["warning", "warning", "critical"]);
    expect(ev[2].flags).toContain("burst");
  });
  it("a 67-push attack sends ONE aggregated alert (1 ntfy + 1 Slack call), critical, revoke line once at the end", async () => {
    const wenv = { NTFY_TOPIC: "t0pic", SLACK_WEBHOOK_URL: "https://hooks.slack.test/x" };
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
    try {
      await runInDurableObject(hub(), async (h) => {
        h.env.NTFY_TOPIC = wenv.NTFY_TOPIC; h.env.SLACK_WEBHOOK_URL = wenv.SLACK_WEBHOOK_URL;
        for (let i = 0; i < 67; i++) {
          await h.receivePush(`d${i}`, { repo: `o/r${i % 7}`, ref: `refs/heads/b${i}`, before: "1".repeat(40), after: "2".repeat(40), forced: false }, T0);
        }
      });
      at(30);
      await alarm();
      const ntfy = f.mock.calls.filter((c) => c[0] === "https://ntfy.sh");
      const slack = f.mock.calls.filter((c) => c[0] === wenv.SLACK_WEBHOOK_URL);
      expect(ntfy).toHaveLength(1);
      expect(slack).toHaveLength(1);
      const nb = JSON.parse(ntfy[0][1].body);
      expect(nb.priority).toBe(5);
      expect(nb.title.startsWith("🔴")).toBe(true);
      expect(nb.message.endsWith("If this wasn't you: revoke tokens at https://github.com/settings/applications")).toBe(true);
      expect(nb.message.split("revoke tokens").length).toBe(2);
      expect(nb.message).toContain("67 events");
      expect(nb.message).toContain("…and 57 more event(s)");
      expect(nb.message.length).toBeLessThan(4000);
      // all 67 events are queued
      const p1 = await events(0), p2 = await events(p1.next);
      expect(p1.events.length + p2.events.length).toBe(67);
    } finally {
      await runInDurableObject(hub(), async (h) => { delete h.env.NTFY_TOPIC; delete h.env.SLACK_WEBHOOK_URL; });
      f.mockRestore();
    }
  });
  it("emits disarmed events immediately for installation removal", async () => {
    expect((await hook("installation", { action: "deleted", installation: { account: { login: "Owner" } } })).status).toBe(202);
    expect((await hook("installation_repositories", {
      action: "removed", installation: { account: { login: "Owner" } },
      repositories_removed: [{ full_name: "Owner/A" }, { full_name: "Owner/B" }],
    })).status).toBe(202);
    const { events: ev } = await events();
    expect(ev).toHaveLength(2);
    expect(ev[0]).toMatchObject({ kind: "disarmed", level: "critical", repo: "owner", ref: "", before: "", after: "", forced: false, flags: [] });
    expect(ev[1]).toMatchObject({ kind: "disarmed", level: "critical", repo: "owner/a,owner/b" });
  });
  it("treats installation suspend like deleted (disarmed)", async () => {
    expect((await hook("installation", { action: "suspend", installation: { account: { login: "Owner" } } })).status).toBe(202);
    const { events: ev } = await events();
    expect(ev).toHaveLength(1);
    expect(ev[0]).toMatchObject({ kind: "disarmed", level: "critical", repo: "owner" });
  });
  it("ignores installation actions that do not disarm", async () => {
    expect((await hook("installation", { action: "created", installation: { account: { login: "o" } } })).status).toBe(204);
    expect((await hook("installation_repositories", { action: "added", repositories_removed: [] })).status).toBe(204);
    expect((await events()).events).toEqual([]);
  });
  it("rejects a malformed push payload with 400", async () => {
    expect((await hook("push", { ref: 1 })).status).toBe(400);
  });
  it("keeps events for 7 days (a Mac offline for days still drains them), then prunes them", async () => {
    await hook("installation", { action: "deleted", installation: { account: { login: "o" } } });
    at(2 * 86_400);
    expect((await hub().events(0)).events).toHaveLength(1);
    at(7 * 86_400 - 1);
    expect((await hub().events(0)).events).toHaveLength(1);
    at(7 * 86_400 + 1);
    await alarm();
    expect((await hub().events(0)).events).toEqual([]);
  });
  it("keeps seq increasing after pruning", async () => {
    await hook("installation", { action: "deleted", installation: { account: { login: "o" } } });
    at(7 * 86_400 + 1);
    await alarm();
    await hook("installation", { action: "deleted", installation: { account: { login: "o" } } });
    expect((await hub().events(0)).events.map((e) => e.seq)).toEqual([2]);
  });
});

describe("GET /queue", () => {
  it("pages 100 at a time and reports next", async () => {
    for (let i = 0; i < 150; i++) await hook("installation", { action: "deleted", installation: { account: { login: "o" } } });
    const p1 = await events(0);
    expect(p1.events).toHaveLength(100);
    expect(p1.events[0].seq).toBe(1);
    expect(p1.next).toBe(100);
    const p2 = await events(p1.next);
    expect(p2.events).toHaveLength(50);
    expect(p2.events[49].seq).toBe(150);
    expect(p2.next).toBe(150);
    const p3 = await events(150);
    expect(p3).toEqual({ events: [], next: 150, oldest: 1 });
  });
  it("reports the oldest retained seq, so a Mac can tell that events were pruned before it read them", async () => {
    expect((await events(0)).oldest).toBe(1);   // empty, nothing ever stored
    await hook("installation", { action: "deleted", installation: { account: { login: "o" } } });
    expect((await events(0)).oldest).toBe(1);
    at(7 * 86_400 + 1);
    await alarm();
    await hook("installation", { action: "deleted", installation: { account: { login: "o" } } });
    // (the signed /queue auth is pinned to T0, so read the Hub directly after the clock jump)
    const r = await hub().events(0);
    expect(r.events.map((e) => e.seq)).toEqual([2]);
    expect(r.oldest).toBe(2);
    at(14 * 86_400 + 2);
    expect(await hub().events(2)).toEqual({ events: [], next: 2, oldest: 3 });
  });
  it("rejects missing, tampered and wrong-namespace auth with 401", async () => {
    expect((await queue(0, null)).status).toBe(401);
    expect((await queue(0, "garbage")).status).toBe(401);
    expect((await queue(0, QUEUE_TAMPERED.trim())).status).toBe(401);
    expect((await queue(0, QUEUE_WRONGNS.trim())).status).toBe(401);
  });
  it("rejects a bad after parameter with 400", async () => {
    expect((await queue("x")).status).toBe(400);
  });
  // skew = auth ts minus Worker time (positive: Mac clock ahead)
  it.each([[240, 200], [360, 401], [-240, 200], [-360, 401]])("auth ts minus Worker time = %i s -> %i", async (skew, status) => {
    vi.setSystemTime(T0 - skew * 1000);
    expect((await queue()).status).toBe(status);
  });
});

describe("GET /health", () => {
  it("returns ok", async () => {
    const r = await SELF.fetch("https://w.test/health");
    expect(r.status).toBe(200);
    expect(await r.json()).toEqual({ ok: true });
  });
});
