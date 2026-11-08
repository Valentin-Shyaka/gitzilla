import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { env, runInDurableObject } from "cloudflare:test";
import worker from "../src/index.js";
import { formatReport } from "../src/notify.js";
import OK from "./fixtures/report-ok.json";
import TAMPERED from "./fixtures/report-tampered.json";
import WRONGNS from "./fixtures/report-wrongns.json";
import BADREASON from "./fixtures/report-badreason.json";
import TOOMANY from "./fixtures/report-toomany.json";
import ESCAPE from "./fixtures/report-escape.json";
import PARTIAL from "./fixtures/report-partial.json";
import LOWTOTAL from "./fixtures/report-lowtotal.json";
import NOTOTALS from "./fixtures/report-nototals.json";
import BIG from "./fixtures/report-big.json";
import NL from "./fixtures/report-nl.json";
import URL_ from "./fixtures/report-url.json";
import STAR from "./fixtures/report-star.json";
import JUNK from "./fixtures/report-junk.json";
import TRAIL from "./fixtures/report-trail.json";
import LONGDETAIL from "./fixtures/report-longdetail.json";
import UNVERIFIED from "./fixtures/report-unverified.json";
import QUEUE_OK from "./fixtures/queue-auth-ok.txt?raw";

const REVOKE = "If this wasn't you: revoke tokens at https://github.com/settings/applications";
const TS = JSON.parse(atob(OK.payload)).ts;
const NTFY = "https://ntfy.sh", SLACK = "https://hooks.slack.test/x";
const wenv = { ...env, NTFY_TOPIC: "t0pic", SLACK_WEBHOOK_URL: SLACK };

const post = (body, e = wenv) =>
  worker.fetch(new Request("https://w.test/report", {
    method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
  }), e);
const hub = () => env.HUB.get(env.HUB.idFromName("main"));
const setClock = (offsetSeconds) => vi.setSystemTime((TS - offsetSeconds) * 1000);
let f;

beforeEach(async () => {
  await runInDurableObject(hub(), (_h, state) => state.storage.deleteAll());
  f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

const sent = (url) => f.mock.calls.filter((c) => c[0] === url).map((c) => JSON.parse(c[1].body));

describe("POST /report", () => {
  it("accepts a signed report and notifies ntfy and Slack", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(OK)).status).toBe(204);
    const [n] = sent(NTFY), [s] = sent(SLACK);
    expect(n.title).toBe("Account watchdog: restore report");
    expect(n.topic).toBe("t0pic");
    expect(n.message).toBe([
      "Restored 1, skipped 2",
      "",
      "Restored:",
      "owner/name refs/heads/main",
      "",
      "Skipped:",
      "owner/name refs/heads/dev: ref moved since the incident",
      "owner/name refs/heads/x: could not send note (worker returned 500)",
      "",
      REVOKE,
    ].join("\n"));
    expect(s.text).toBe(`${n.title}\n${n.message}`);
  });
  it("rejects a bad signature with 401 and sends nothing", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(TAMPERED)).status).toBe(401);
    expect(f).not.toHaveBeenCalled();
  });
  it("rejects a signature made in the note namespace with 401", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(WRONGNS)).status).toBe(401);
  });
  it("rejects a replayed nonce with 409 and notifies once", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(OK)).status).toBe(204);
    expect((await post(OK)).status).toBe(409);
    expect(sent(NTFY).length).toBe(1);
  });
  it.each([[240, 204], [660, 422], [-660, 422]])("ts skew %i s -> %i", async (skew, status) => {
    vi.useFakeTimers(); setClock(skew);
    expect((await post(OK)).status).toBe(status);
  });
  it("accepts the restore-target-not-verified reason", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(UNVERIFIED)).status).toBe(204);
    expect(sent(NTFY)[0].message).toContain("owner/name refs/heads/main: restore target not verified — review manually");
  });
  it("rejects an unknown reason with 400", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(BADREASON)).status).toBe(400);
  });
  it("rejects more than 50 entries with 400", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(TOOMANY)).status).toBe(400);
  });
  it.each([
    ["newline in detail", NL], ["URL in detail", URL_], ["* in detail", STAR],
    ["trailing junk after a fixed reason", JUNK], ["text after the detail", TRAIL], ["detail over 100 chars", LONGDETAIL],
  ])("rejects a malformed reason: %s", async (_n, fx) => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(fx)).status).toBe(400);
    expect(f).not.toHaveBeenCalled();
  });
  it("rejects a payload without totals, or with a total below the listed count", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(NOTOTALS)).status).toBe(400);
    expect((await post(LOWTOTAL)).status).toBe(400);
  });
  it("renders totals larger than the listed count", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(PARTIAL)).status).toBe(204);
    expect(sent(NTFY)[0].message.startsWith("Restored 80 (50 listed), skipped 1\n")).toBe(true);
  });
  it("accepts a body at the byte budget (7600)", async () => {
    vi.useFakeTimers(); setClock(0);
    expect(JSON.stringify(BIG).length).toBeLessThanOrEqual(7600);
    expect((await post(BIG)).status).toBe(204);
  });
  it("a valid report signature is not accepted on /note", async () => {
    vi.useFakeTimers(); setClock(0);
    const r = await worker.fetch(new Request("https://w.test/note", { method: "POST", body: JSON.stringify(OK) }), wenv);
    expect(r.status).toBe(401);
  });
  it("a queue-auth signature is not accepted as a report signature", async () => {
    vi.useFakeTimers(); setClock(0);
    const [p, sg] = QUEUE_OK.trim().split(".");
    expect((await post({ payload: p, sig: atob(sg) })).status).toBe(401);
  });
  it("rejects non-JSON and missing fields with 400", async () => {
    expect((await post("nope")).status).toBe(400);
    expect((await post({ payload: OK.payload })).status).toBe(400);
  });
  it("escapes Slack text, keeps ntfy plain", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(ESCAPE)).status).toBe(204);
    expect(sent(SLACK)[0].text).toContain("refs/heads/&lt;!channel&gt;&amp;x");
    expect(sent(SLACK)[0].text).not.toMatch(/[<>]/);
    expect(sent(NTFY)[0].message).toContain("refs/heads/<!channel>&x");
  });
  it("is fail-open: delivery errors still give 204", async () => {
    vi.useFakeTimers(); setClock(0);
    vi.spyOn(console, "error").mockImplementation(() => {});
    f.mockRejectedValue(new Error("boom"));
    expect((await post(OK)).status).toBe(204);
  });
  it("404 for GET", async () => {
    expect((await worker.fetch(new Request("https://w.test/report"), wenv)).status).toBe(404);
  });
});

describe("Hub.useNonce", () => {
  it("is single-use until max(now,ts)+600 s", async () => {
    const t0 = TS * 1000;
    await runInDurableObject(hub(), async (h) => {
      expect(await h.useNonce("a".repeat(32), TS, t0)).toBe(true);
      expect(await h.useNonce("a".repeat(32), TS, t0 + 599_000)).toBe(false);
      expect(await h.useNonce("a".repeat(32), TS, t0 + 601_000)).toBe(true);
    });
  });
});

describe("formatReport", () => {
  const mk = (n, extra = {}) => Array.from({ length: n }, (_, i) => ({ repo: "o/r", ref: "refs/heads/b" + i, ...extra }));
  it("lists at most 10 per section and says how many more", () => {
    const { body } = formatReport({ restored: mk(12), skipped: mk(11, { reason: "push failed" }), restored_total: 12, skipped_total: 20 });
    expect(body.startsWith("Restored 12, skipped 20 (11 listed)\n")).toBe(true);
    expect(body).toContain("refs/heads/b9");
    expect(body).not.toContain("refs/heads/b10");
    expect(body).toContain("…and 2 more");
    expect(body).toContain("…and 1 more");
    expect(body.endsWith(REVOKE)).toBe(true);
  });
  it("caps repo/ref at 200 and reason at 120", () => {
    const { body } = formatReport({
      restored: [{ repo: "p".repeat(300), ref: "r".repeat(300) }],
      skipped: [{ repo: "o/r", ref: "refs/heads/x", reason: "push failed" + "z".repeat(200) }],
    });
    expect(body).toContain("p".repeat(200) + "…");
    expect(body).not.toContain("p".repeat(201));
    expect(body).not.toContain("z".repeat(120));
  });
});
