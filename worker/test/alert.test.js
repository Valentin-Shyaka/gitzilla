import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { env, runInDurableObject } from "cloudflare:test";
import worker from "../src/index.js";
import { formatAccountAlert } from "../src/notify.js";
import NEWKEY from "./fixtures/alert-newkey.json";
import NEWKEY_SIGNING from "./fixtures/alert-newkey-signing.json";
import MISSED from "./fixtures/alert-missed.json";
import WRONGNS from "./fixtures/alert-wrongns.json";
import TAMPERED from "./fixtures/alert-tampered.json";
import BADFP from "./fixtures/alert-badfp.json";
import MD5FP from "./fixtures/alert-md5fp.json";
import BADSOURCE from "./fixtures/alert-badsource.json";
import BADKIND from "./fixtures/alert-badkind.json";
import EXTRA from "./fixtures/alert-extra.json";
import FREETEXT from "./fixtures/alert-freetext.json";
import MISSING from "./fixtures/alert-missing.json";
import REFSSTR from "./fixtures/alert-refsstr.json";
import REFSZERO from "./fixtures/alert-refszero.json";
import REPOSFLOAT from "./fixtures/alert-reposfloat.json";
import MISSEDEXTRA from "./fixtures/alert-missedextra.json";
import MISSEDNONCE from "./fixtures/alert-missednonce.json";
import REPORT_OK from "./fixtures/report-ok.json";
import NOTE from "./fixtures/note-ok.json";

const REVOKE = "If this wasn't you: revoke tokens at https://github.com/settings/applications";
const TS = JSON.parse(atob(NEWKEY.payload)).ts;
const FP = JSON.parse(atob(NEWKEY.payload)).fingerprint;
const NTFY = "https://ntfy.sh", SLACK = "https://hooks.slack.test/x";
const wenv = { ...env, NTFY_TOPIC: "t0pic", SLACK_WEBHOOK_URL: SLACK, ALERT_TZ: "Africa/Kigali" };

const post = (path, body, e = wenv) =>
  worker.fetch(new Request(`https://w.test${path}`, {
    method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
  }), e);
const alert = (body) => post("/alert", body);
const hub = () => env.HUB.get(env.HUB.idFromName("main"));
const setClock = (offsetSeconds) => vi.setSystemTime((TS - offsetSeconds) * 1000);
let f;
const sent = (url) => f.mock.calls.filter((c) => c[0] === url).map((c) => JSON.parse(c[1].body));

beforeEach(async () => {
  await runInDurableObject(hub(), (_h, state) => state.storage.deleteAll());
  f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
});
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); });

describe("POST /alert", () => {
  it("new-key: critical (priority 5) to ntfy and Slack, fixed text, keys link, revoke line last", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(NEWKEY)).status).toBe(204);
    const [n] = sent(NTFY), [s] = sent(SLACK);
    expect(n.topic).toBe("t0pic");
    expect(n.priority).toBe(5);
    expect(n.tags).toEqual(["rotating_light"]);
    expect(n.title).toBe("🔴 gitzilla: new key on your GitHub account");
    expect(n.message).toBe([
      `New authentication key: ssh-ed25519 ${FP}`,
      "Time: 2100-01-01 00:00:00 UTC / 01/01/2100, 02:00:00 (Africa/Kigali)",
      "Review keys: https://github.com/settings/keys",
      "",
      REVOKE,
    ].join("\n"));
    expect(s.text).toBe(`${n.title}\n${n.message}`);
  });
  it("new-key from the signing-key list says so", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(NEWKEY_SIGNING)).status).toBe(204);
    expect(sent(NTFY)[0].message.startsWith(`New signing key: ssh-ed25519 ${FP}\n`)).toBe(true);
  });
  it("missed-webhook: warning (🟠, priority 3), fixed text, revoke line last", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(MISSED)).status).toBe(204);
    const [n] = sent(NTFY);
    expect(n.priority).toBe(3);
    expect(n.tags).toEqual(["warning"]);
    expect(n.title).toBe("🟠 gitzilla: possible missed webhook");
    expect(n.message).toBe([
      "3 ref(s) in 2 repo(s) differ from the known heads (possible missed webhook).",
      "Time: 2100-01-01 00:00:00 UTC / 01/01/2100, 02:00:00 (Africa/Kigali)",
      "",
      REVOKE,
    ].join("\n"));
    expect(n.message.split(REVOKE).length).toBe(2);
    expect(sent(SLACK)).toHaveLength(1);
  });
  it("rejects a tampered payload with 401 and sends nothing", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(TAMPERED)).status).toBe(401);
    expect(f).not.toHaveBeenCalled();
  });
  it("rejects a signature made in the report namespace with 401", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(WRONGNS)).status).toBe(401);
    expect(f).not.toHaveBeenCalled();
  });
  it("an alert signature is not accepted on /report or /note", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post("/report", NEWKEY)).status).toBe(401);
    expect((await post("/note", NEWKEY)).status).toBe(401);
  });
  it("report and note signatures are not accepted on /alert", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(REPORT_OK)).status).toBe(401);
    expect((await alert(NOTE)).status).toBe(401);
  });
  it("rejects a replayed nonce with 409 and notifies once", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(NEWKEY)).status).toBe(204);
    expect((await alert(NEWKEY)).status).toBe(409);
    expect(sent(NTFY)).toHaveLength(1);
  });
  it("shares the nonce store with /report", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post("/report", REPORT_OK)).status).toBe(204);
    expect((await alert(NEWKEY)).status).toBe(409); // same nonce as report-ok
  });
  it.each([[240, 204], [-240, 204], [360, 422], [-360, 422]])("ts skew %i s -> %i", async (skew, status) => {
    vi.useFakeTimers(); setClock(skew);
    expect((await alert(NEWKEY)).status).toBe(status);
  });
  it.each([
    ["short fingerprint", BADFP], ["MD5 fingerprint", MD5FP], ["unknown source", BADSOURCE], ["unknown kind", BADKIND],
    ["extra field", EXTRA], ["free text in key_type", FREETEXT], ["missing field", MISSING],
    ["refs as a string", REFSSTR], ["refs 0", REFSZERO], ["fractional repos", REPOSFLOAT],
    ["extra field (missed-webhook)", MISSEDEXTRA], ["bad nonce", MISSEDNONCE],
  ])("rejects a malformed alert: %s", async (_n, fx) => {
    vi.useFakeTimers(); setClock(0);
    expect((await alert(fx)).status).toBe(400);
    expect(f).not.toHaveBeenCalled();
  });
  it("rejects non-JSON, missing fields and oversize bodies with 400", async () => {
    expect((await alert("nope")).status).toBe(400);
    expect((await alert({ payload: NEWKEY.payload })).status).toBe(400);
    expect((await alert("x".repeat(9000))).status).toBe(400);
  });
  it("is fail-open: delivery errors still give 204", async () => {
    vi.useFakeTimers(); setClock(0);
    vi.spyOn(console, "error").mockImplementation(() => {});
    f.mockRejectedValue(new Error("boom"));
    expect((await alert(NEWKEY)).status).toBe(204);
  });
  it("404 for GET", async () => {
    expect((await worker.fetch(new Request("https://w.test/alert"), wenv)).status).toBe(404);
  });
});

describe("formatAccountAlert", () => {
  it("never renders fields other than the fixed ones", () => {
    const r = formatAccountAlert({ kind: "missed-webhook", ts: TS, refs: 1, repos: 1, text: "SECRET" });
    expect(r.body).not.toContain("SECRET");
    expect(r.body.endsWith(REVOKE)).toBe(true);
  });
});
