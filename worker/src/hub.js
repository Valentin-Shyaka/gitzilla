import { DurableObject } from "cloudflare:workers";
import { classify, BURST_WINDOW_S } from "./classify.js";
import { notifyEvents } from "./notify.js";

export const TTL_MS = 600_000;

export const GRACE_MS = 20_000;
// 7 days: a Mac asleep or offline for days still drains its queue on wake (spec §8). Notes, nonces and
// burst windows keep their short lifetimes.
export const EVENT_TTL_MS = 7 * 86_400_000;
const PAGE = 100;

const evKey = (seq) => `ev:${String(seq).padStart(12, "0")}`;
const unKey = (ts, delivery) => `un:${String(ts).padStart(12, "0")}:${delivery}`;
const noteKey = (repo, ref, sha) => `note:${repo}|${ref}|${sha}`;

// Single instance (idFromName("main")). Stores signed push notes and replay nonces,
// each with an expiry timestamp (ms). `now` is injectable for tests.
export class Hub extends DurableObject {
  async #prune(now) {
    for (const prefix of ["note:", "nonce:"]) {
      const rows = await this.ctx.storage.list({ prefix });
      const dead = [...rows].filter(([, exp]) => exp <= now).map(([k]) => k);
      if (dead.length) await this.ctx.storage.delete(dead);
    }
  }

  // Returns false if the nonce was already seen (replay), true if the note was stored.
  // The nonce is kept until ts+TTL too, so it outlives the window in which its note's ts is accepted.
  async addNote(repo, ref, newSha, nonce, ts, now = Date.now()) {
    await this.#prune(now);
    if ((await this.ctx.storage.get(`nonce:${nonce}`)) !== undefined) return false;
    const exp = now + TTL_MS;
    const nonceExp = Math.max(exp, ts * 1000 + TTL_MS);
    await this.ctx.storage.put({ [`nonce:${nonce}`]: nonceExp, [noteKey(repo, ref, newSha)]: exp });
    await this.#armAt(exp + 1000);
    return true;
  }

  // Single-use nonce for other signed routes; same retention as addNote. False on replay.
  async useNonce(nonce, ts, now = Date.now()) {
    await this.#prune(now);
    if ((await this.ctx.storage.get(`nonce:${nonce}`)) !== undefined) return false;
    const nonceExp = Math.max(now, ts * 1000) + TTL_MS;
    await this.ctx.storage.put(`nonce:${nonce}`, nonceExp);
    await this.#armAt(nonceExp + 1000);
    return true;
  }

  async hasNote(repo, ref, newSha, now = Date.now()) {
    await this.#prune(now);
    return (await this.ctx.storage.get(noteKey(repo, ref, newSha))) !== undefined;
  }

  // The Hub has ONE alarm: it is only ever moved earlier here, and re-armed for the
  // next outstanding deadline at the end of alarm().
  async #armAt(t) {
    const cur = await this.ctx.storage.getAlarm();
    if (cur === null || t < cur) await this.ctx.storage.setAlarm(t);
  }

  async #nextDeadline() {
    const st = this.ctx.storage;
    const c = [];
    for (const [, p] of await st.list({ prefix: "pend:" })) c.push(p.at + GRACE_MS);
    for (const prefix of ["note:", "nonce:"]) for (const [, exp] of await st.list({ prefix })) c.push(exp + 1000);
    for (const [, u] of await st.list({ prefix: "un:", limit: 1 })) c.push(u.ts * 1000 + BURST_WINDOW_S * 1000 + 1000);
    for (const [, e] of await st.list({ prefix: "ev:", limit: 1 })) c.push(e.ts * 1000 + EVENT_TTL_MS + 1000);
    return c.length ? Math.min(...c) : null;
  }

  async #append(fields, now) {
    const seq = ((await this.ctx.storage.get("seq")) ?? 0) + 1;
    const event = { seq, ts: Math.floor(now / 1000), ...fields };
    await this.ctx.storage.put({ seq, [evKey(seq)]: event });
    return event;
  }

  // One aggregated alert for every non-silent event of a run (never one post per event).
  async #notify(events) {
    const loud = events.filter((e) => e.level !== "silent");
    if (!loud.length) return;
    try { await notifyEvents(loud, this.env); } catch (e) { console.error("notify failed", e); }
  }

  // Queue a push for classification GRACE_MS from now (a note may still arrive).
  async receivePush(delivery, push, now = Date.now()) {
    const key = `pend:${delivery}`;
    if ((await this.ctx.storage.get(key)) === undefined) {
      await this.ctx.storage.put(key, { ...push, delivery, at: now });
    }
    await this.#armAt(now + GRACE_MS);
  }

  // Installation removed / repositories removed: no grace period.
  async receiveDisarmed(delivery, repo, now = Date.now()) {
    const event = await this.#append(
      { delivery, kind: "disarmed", repo, ref: "", before: "", after: "", forced: false, level: "critical", flags: [] },
      now,
    );
    await this.#armAt(now + EVENT_TTL_MS + 1000);
    await this.#notify([event]);
  }

  async events(after, now = Date.now()) {
    await this.#pruneEvents(now);
    const rows = await this.ctx.storage.list({ prefix: "ev:", start: evKey(after + 1), limit: PAGE });
    const events = [...rows.values()];
    // oldest: seq of the oldest retained event, or the next seq to be assigned when none is retained.
    // A reader whose cursor is below oldest - 1 lost events to pruning.
    let oldest = null;
    for (const [, e] of await this.ctx.storage.list({ prefix: "ev:", limit: 1 })) oldest = e.seq;
    if (oldest === null) oldest = ((await this.ctx.storage.get("seq")) ?? 0) + 1;
    return { events, next: events.length ? events[events.length - 1].seq : after, oldest };
  }

  // Events are stored in ascending seq (~ts) order, so only the oldest few can be expired.
  async #pruneEvents(now) {
    for (;;) {
      const rows = await this.ctx.storage.list({ prefix: "ev:", limit: PAGE });
      const dead = [...rows].filter(([, e]) => e.ts * 1000 + EVENT_TTL_MS <= now).map(([k]) => k);
      if (dead.length) await this.ctx.storage.delete(dead);
      if (dead.length < PAGE) return;
    }
  }

  async #classifyDue(now) {
    const st = this.ctx.storage;
    const due = [...(await st.list({ prefix: "pend:" }))].filter(([, p]) => p.at + GRACE_MS <= now)
      .sort((a, b) => a[1].at - b[1].at);
    const out = [];
    for (const [key, p] of due) {
      const push = { repo: p.repo, ref: p.ref, before: p.before, after: p.after, forced: p.forced, ts: Math.floor(p.at / 1000) };
      const noted = await this.hasNote(p.repo, p.ref, p.after, now);
      const recent = [...(await st.list({ prefix: "un:" }))].map(([, u]) => u);
      const { level, flags } = classify(push, noted, recent);
      if (!noted) await st.put(unKey(push.ts, p.delivery), { repo: p.repo, ref: p.ref, ts: push.ts });
      const event = await this.#append({ delivery: p.delivery, kind: "push", ...push, level, flags }, p.at);
      await st.delete(key);
      out.push(event);
    }
    // every event is queued first; then one alert for the whole run
    await this.#notify(out);
  }

  async alarm() {
    const now = Date.now();
    await this.#prune(now);
    await this.#classifyDue(now);
    await this.#pruneEvents(now);
    const un = await this.ctx.storage.list({ prefix: "un:" });
    const deadU = [...un].filter(([, u]) => u.ts * 1000 + BURST_WINDOW_S * 1000 <= now).map(([k]) => k);
    if (deadU.length) await this.ctx.storage.delete(deadU);
    const next = await this.#nextDeadline();
    if (next !== null) await this.ctx.storage.setAlarm(Math.max(next, now + 1));
  }
}
