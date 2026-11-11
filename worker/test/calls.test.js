import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { env, runInDurableObject } from "cloudflare:test";
import { parseCallNumbers, formatCall, formatAccountCall, notifyEvents } from "../src/notify.js";

const TOKEN = "tk_" + "a".repeat(29);
const N1 = "+250788123442", N2 = "+14155550142";
const SLACK = "https://hooks.slack.test/x";
const hub = () => env.HUB.get(env.HUB.idFromName("main"));
const ev = (o = {}) => ({
  seq: 1, ts: 1790000000, kind: "push", repo: "owner/repo", ref: "refs/heads/main",
  before: "a".repeat(40), after: "b".repeat(40), forced: true, level: "critical", flags: ["force-push"], ...o,
});
const cenv = (o = {}) => ({ NTFY_TOPIC: "t0pic", SLACK_WEBHOOK_URL: SLACK, NTFY_CALL_TOKEN: TOKEN,
  NTFY_CALL_NUMBERS: `${N1},${N2}`, ...o });
let f, err;
const calls = () => f.mock.calls.filter((c) => c[0] === "https://ntfy.sh" && JSON.parse(c[1].body).call);
beforeEach(async () => {
  await runInDurableObject(hub(), (_h, s) => s.storage.deleteAll());
  f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
  err = vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => vi.restoreAllMocks());
const allow = () => true;

describe("parseCallNumbers", () => {
  it("keeps valid, drops invalid, dedupes, caps at 5", () => {
    expect(parseCallNumbers(" +250788123442 , 0788, +14155550142,+250788123442,abc,+0123456789")).toEqual([N1, N2]);
    const six = [1, 2, 3, 4, 5, 6].map((i) => `+1415555010${i}`).join(",");
    expect(parseCallNumbers(six)).toHaveLength(5);
    expect(parseCallNumbers(undefined)).toEqual([]);
  });
});

describe("formatCall", () => {
  it("push text, 3 names max, sanitised and capped", () => {
    const evs = ["a/b", "c/d", "e/f", "g/h", "i/j"].map((repo) => ev({ repo }));
    const t = formatCall(evs);
    expect(t).toBe("gitzilla critical alert. Possible stolen GitHub credential. 5 events in a/b, c/d, e/f and 2 more. " +
      "Check Slack or the ntfy app, and revoke tokens if this was not you.");
    const odd = formatCall([ev({ repo: "Own er/Re<po>;$(x)" + "z".repeat(100) })]);
    expect(odd).toContain("1 event in ");
    const name = odd.match(/in (\S+)\./)[1];
    expect(name).toMatch(/^[a-z0-9._/-]{1,60}$/);
    expect(odd).not.toMatch(/[a-f0-9]{40}/);
  });
  it("names that all sanitise to empty say \"your repositories\"", () => {
    expect(formatCall([ev({ repo: "<>" }), ev({ repo: "!!" })])).toBe(
      "gitzilla critical alert. Possible stolen GitHub credential. 2 events in your repositories. " +
      "Check Slack or the ntfy app, and revoke tokens if this was not you.");
    expect(formatCall([ev({ kind: "disarmed", repo: "" })])).toBe(
      "gitzilla critical alert. gitzilla was disarmed for your repositories. " +
      "Check Slack or the ntfy app, and revoke tokens if this was not you.");
  });
  it("disarmed and account", () => {
    expect(formatCall([ev({ kind: "disarmed", repo: "o/r" })])).toBe(
      "gitzilla critical alert. gitzilla was disarmed for o/r. Check Slack or the ntfy app, and revoke tokens if this was not you.");
    expect(formatAccountCall({})).toBe(
      "gitzilla critical alert. A new key was added to your GitHub account. Check Slack or the ntfy app, and revoke tokens if this was not you.");
  });
});

describe("calls from notifyEvents", () => {
  it("critical run places one call per number with Bearer header and -call topic", async () => {
    await notifyEvents([ev()], cenv(), 8000, allow);
    const c = calls();
    expect(c).toHaveLength(2);
    expect(c[0][1].headers.Authorization).toBe(`Bearer ${TOKEN}`);
    const b = JSON.parse(c[0][1].body);
    expect(b).toMatchObject({ topic: "t0pic-call", priority: 5, call: N1 });
    expect(b.message).toContain("Possible stolen GitHub credential");
    expect(JSON.parse(c[1][1].body).call).toBe(N2);
    // normal push + Slack still sent
    expect(f.mock.calls.some((x) => x[0] === SLACK)).toBe(true);
    expect(f.mock.calls.some((x) => x[0] === "https://ntfy.sh" && JSON.parse(x[1].body).topic === "t0pic")).toBe(true);
  });
  it("warning places no call", async () => {
    await notifyEvents([ev({ level: "warning" })], cenv(), 8000, allow);
    expect(calls()).toHaveLength(0);
  });
  it.each([
    ["missing token", { NTFY_CALL_TOKEN: undefined }],
    ["bad token", { NTFY_CALL_TOKEN: "tk_short" }],
    ["no numbers", { NTFY_CALL_NUMBERS: "" }],
    ["only invalid numbers", { NTFY_CALL_NUMBERS: "123" }],
    ["no topic", { NTFY_TOPIC: undefined }],
  ])("%s: no call", async (_n, o) => {
    await notifyEvents([ev()], cenv(o), 8000, allow);
    expect(calls()).toHaveLength(0);
  });
  it("failing call does not block push or Slack, and logs leak nothing", async () => {
    f.mockImplementation(async (url, init) => {
      if (url === "https://ntfy.sh" && JSON.parse(init.body).call) throw new Error(`boom ${TOKEN} ${N1}`);
      return new Response("ok");
    });
    await notifyEvents([ev()], cenv(), 8000, allow);
    expect(f.mock.calls.some((x) => x[0] === SLACK)).toBe(true);
    expect(f.mock.calls.some((x) => x[0] === "https://ntfy.sh" && !JSON.parse(x[1].body).call)).toBe(true);
    expect(err).toHaveBeenCalled();
  });
  it("HTTP failure logs status and masked number only", async () => {
    f.mockImplementation(async (url, init) =>
      url === "https://ntfy.sh" && JSON.parse(init.body).call ? new Response("no", { status: 402 }) : new Response("ok"));
    await notifyEvents([ev()], cenv(), 8000, allow);
    const logs = err.mock.calls.flat().map(String).join("\n");
    expect(logs).toContain("HTTP 402");
    expect(logs).toContain("+**********42");
    expect(logs).not.toContain(TOKEN);
    expect(logs).not.toContain(N1);
    expect(logs).not.toContain(N2);
  });
});

describe("Hub.callAllowed and rate limit", () => {
  it("10 min for calls, 1 h for tests, separate keys, pruned after 1 h", async () => {
    await runInDurableObject(hub(), async (h, s) => {
      const t = 1_800_000_000_000;
      expect(await h.callAllowed(N1, t)).toBe(true);
      expect(await h.callAllowed(N1, t + 599_999)).toBe(false);
      expect(await h.callAllowed(N1, t + 600_000)).toBe(true);
      expect(await h.callAllowed(N2, t)).toBe(true);
      expect(await h.callAllowed(N1, t + 600_001, true)).toBe(true);
      expect(await h.callAllowed(N1, t + 600_002, true)).toBe(false);
      expect(await s.storage.get(`call:${N1}`)).toBe(t + 600_000);
      expect(await h.callAllowed(N1, t + 600_001 + 3_600_000, true)).toBe(true);
      await h.callAllowed("+19995550100", t + 10_000_000);
      expect(await s.storage.get(`call:${N2}`)).toBeUndefined();
      expect(await s.storage.get(`call:${N1}`)).toBeUndefined();
    });
  });
  it("a burst of 50 events through the Hub places one call per number", async () => {
    await runInDurableObject(hub(), async (h) => {
      Object.assign(h.env, cenv());
      try {
        for (let i = 0; i < 50; i++) await h.receiveDisarmed(`d${i}`, `o/r${i}`);
      } finally {
        for (const k of Object.keys(cenv())) delete h.env[k];
      }
    });
    expect(calls()).toHaveLength(2);
    expect(f.mock.calls.filter((c) => c[0] === SLACK)).toHaveLength(50);
  });
  it("second critical run within 10 min places no call; after 10 min it does", async () => {
    vi.useFakeTimers();
    try {
      vi.setSystemTime(1_800_000_000_000);
      await runInDurableObject(hub(), async (h) => {
        Object.assign(h.env, cenv());
        try {
          await h.receiveDisarmed("a", "o/r");
          expect(calls()).toHaveLength(2);
          vi.setSystemTime(1_800_000_000_000 + 599_000);
          await h.receiveDisarmed("b", "o/r");
          expect(calls()).toHaveLength(2);
          vi.setSystemTime(1_800_000_000_000 + 601_000);
          await h.receiveDisarmed("c", "o/r");
          expect(calls()).toHaveLength(4);
        } finally {
          for (const k of Object.keys(cenv())) delete h.env[k];
        }
      });
    } finally { vi.useRealTimers(); }
  });
});
