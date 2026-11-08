import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { SELF, env, runInDurableObject } from "cloudflare:test";
import OK from "./fixtures/note-ok.json";
import TAMPERED from "./fixtures/note-tampered.json";

const payload = JSON.parse(atob(OK.payload));
const REPO = payload.repo, REF = payload.ref, SHA = payload.new_sha;

const post = (body) =>
  SELF.fetch("https://w.test/note", {
    method: "POST",
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
const hub = () => env.HUB.get(env.HUB.idFromName("main"));
const setClock = (offsetSeconds) => vi.setSystemTime((payload.ts - offsetSeconds) * 1000);

// Durable Object storage written via SELF.fetch is not rolled back between tests.
beforeEach(() => runInDurableObject(hub(), (_h, state) => state.storage.deleteAll()));
afterEach(() => vi.useRealTimers());

describe("POST /note", () => {
  it("accepts a signed note and records it", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(OK)).status).toBe(204);
    expect(await hub().hasNote(REPO, REF, SHA)).toBe(true);
    expect(await hub().hasNote(REPO, REF, "f".repeat(40))).toBe(false);
  });
  it("rejects a replayed nonce with 409", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(OK)).status).toBe(204);
    expect((await post(OK)).status).toBe(409);
  });
  // skew = note ts minus Worker time (positive: Mac clock ahead of the Worker)
  it.each([
    [240, 204], [360, 204], [660, 422],
    [-240, 204], [-360, 204], [-660, 422],
  ])("note ts minus Worker time = %i s -> %i", async (skew, status) => {
    vi.useFakeTimers(); setClock(skew);
    expect((await post(OK)).status).toBe(status);
  });
  it("keeps the nonce until ts+600 s for a future-dated note", async () => {
    vi.useFakeTimers(); setClock(590);
    expect((await post(OK)).status).toBe(204);
    // past receipt+600 s (ts+10) but within the ts window: still a replay
    vi.setSystemTime((payload.ts + 11) * 1000);
    expect((await post(OK)).status).toBe(409);
  });
  it("rejects a tampered payload with 401", async () => {
    vi.useFakeTimers(); setClock(0);
    expect((await post(TAMPERED)).status).toBe(401);
  });
  it("rejects non-JSON with 400", async () => {
    expect((await post("not json")).status).toBe(400);
  });
  it("rejects a body missing sig/payload or with bad base64 with 400", async () => {
    expect((await post({ payload: OK.payload })).status).toBe(400);
    expect((await post({ payload: "!!!", sig: OK.sig })).status).toBe(400);
  });
});

describe("Hub expiry", () => {
  it("hasNote is false after 601 s and nonce can be reused", async () => {
    const t0 = payload.ts * 1000;
    await runInDurableObject(hub(), async (h) => {
      await h.addNote(REPO, REF, SHA, payload.nonce, payload.ts, t0);
      expect(await h.hasNote(REPO, REF, SHA, t0 + 599_000)).toBe(true);
      expect(await h.hasNote(REPO, REF, SHA, t0 + 601_000)).toBe(false);
      expect(await h.addNote(REPO, REF, SHA, payload.nonce, payload.ts, t0 + 601_000)).toBe(true);
    });
  });
  it("addNote returns false for a live nonce", async () => {
    const t0 = payload.ts * 1000;
    await runInDurableObject(hub(), async (h) => {
      expect(await h.addNote(REPO, REF, SHA, payload.nonce, payload.ts, t0)).toBe(true);
      expect(await h.addNote(REPO, REF, SHA, payload.nonce, payload.ts, t0 + 1000)).toBe(false);
    });
  });
});
