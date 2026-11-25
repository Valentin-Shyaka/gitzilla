import { DurableObject } from "cloudflare:workers";
import { classify, classifyOrg, BURST_WINDOW_S } from "./classify.js";
import { notifyEvents } from "./notify.js";
import {
  MAX_MEMBERS, MAX_KEYS_PER_MEMBER, MAX_PENDING, MAX_BOTS, PENDING_TTL_MS, ENROLL_PER_HOUR, ENROLL_GLOBAL_PER_HOUR,
} from "./members.js";

export const TTL_MS = 600_000;

export const GRACE_MS = 20_000;
// 7 days: a Mac asleep or offline for days still drains its queue on wake (spec §8). Notes, nonces and
// burst windows keep their short lifetimes.
export const EVENT_TTL_MS = 7 * 86_400_000;
const PAGE = 100;

const evKey = (seq) => `ev:${String(seq).padStart(12, "0")}`;
const unKey = (ts, delivery) => `un:${String(ts).padStart(12, "0")}:${delivery}`;
const noteKey = (repo, ref, sha) => `note:${repo}|${ref}|${sha}`;
// A note row is its expiry (personal mode) or {exp, logins} (org mode: the members who signed it).
const noteExp = (v) => (typeof v === "number" ? v : v?.exp ?? 0);
export const MAX_NOTE_LOGINS = 8;
// org mode
const memberKey = (login) => `member:${login}`;
const pendingKey = (login, fp) => `pending:${login}:${fp}`;
const fpKey = (fp) => `fp:${fp}`; // fingerprint -> login of the member that owns it (one login per key)
const botKey = (login) => `bot:${login}`;
const rlKey = (ip, hour) => `rl:${ip}:${hour}`;
const RL_ALL = "all"; // global bucket: rl:all:<hour> (never a client bucket, which always holds "." or ":")
const RL_PRUNED = "rlpruned"; // hour of the last rl:/enonce: sweep (outside both prefixes)
const enonceKey = (nonce) => `enonce:${nonce}`;

// Single instance (idFromName("main")). Stores signed push notes and replay nonces,
// each with an expiry timestamp (ms). `now` is injectable for tests.
export class Hub extends DurableObject {
  async #prune(now) {
    for (const prefix of ["note:", "nonce:"]) {
      const rows = await this.ctx.storage.list({ prefix });
      const dead = [...rows].filter(([, v]) => noteExp(v) <= now).map(([k]) => k);
      if (dead.length) await this.ctx.storage.delete(dead);
    }
    for (const prefix of ["call:", "testcall:"]) {
      const rows = await this.ctx.storage.list({ prefix });
      const dead = [...rows].filter(([, last]) => last <= now - 3_600_000).map(([k]) => k);
      if (dead.length) await this.ctx.storage.delete(dead);
    }
  }

  // Call rate limit per number: normal calls 10 min apart, test calls 1 h apart (own key space).
  async callAllowed(number, now = Date.now(), test = false) {
    await this.#prune(now);
    const key = `${test ? "testcall" : "call"}:${number}`;
    const last = await this.ctx.storage.get(key);
    if (last !== undefined && now - last < (test ? 3_600_000 : 600_000)) return false;
    await this.ctx.storage.put(key, now);
    return true;
  }

  // Returns false if the nonce was already seen (replay), true if the note was stored.
  // The nonce is kept until ts+TTL too, so it outlives the window in which its note's ts is accepted.
  // Org mode passes signer {login, fp}: the key must still belong to that member (else null, nothing stored),
  // and the note row records the signer's login next to any other member who noted the same push. A row that
  // already holds MAX_NOTE_LOGINS other logins refuses a new one ("full", nothing stored, nonce not used).
  async addNote(repo, ref, newSha, nonce, ts, now = Date.now(), signer = null) {
    const st = this.ctx.storage;
    await this.#prune(now);
    if (signer && (await st.get(fpKey(signer.fp))) !== signer.login) return null;
    if ((await st.get(`nonce:${nonce}`)) !== undefined) return false;
    const exp = now + TTL_MS;
    const nonceExp = Math.max(exp, ts * 1000 + TTL_MS);
    const key = noteKey(repo, ref, newSha);
    let value = exp;
    if (signer) {
      const old = await st.get(key);
      const logins = Array.isArray(old?.logins) ? [...old.logins] : [];
      if (!logins.includes(signer.login)) {
        if (logins.length >= MAX_NOTE_LOGINS) return "full";
        logins.push(signer.login);
      }
      value = { exp: Math.max(exp, noteExp(old)), logins };
    }
    await st.put({ [`nonce:${nonce}`]: nonceExp, [key]: value });
    await this.#armAt(exp + 1000);
    return true;
  }

  // Org mode: the logins that signed a live note for this exact push ([] if none).
  async noteLogins(repo, ref, newSha, now = Date.now()) {
    await this.#prune(now);
    const v = await this.ctx.storage.get(noteKey(repo, ref, newSha));
    return Array.isArray(v?.logins) ? v.logins : [];
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

  // ---- org mode: enrollment and members. Every limit is enforced with a refusal, never by dropping data.

  async #prunePending(now) {
    const rows = await this.ctx.storage.list({ prefix: "pending:" });
    const dead = [...rows].filter(([, p]) => p.ts * 1000 + PENDING_TTL_MS <= now).map(([k]) => k);
    if (dead.length) await this.ctx.storage.delete(dead);
    return rows.size - dead.length;
  }

  // Enrollment rate limits, checked before any parsing or crypto, so junk requests use up the budget too:
  // first ENROLL_GLOBAL_PER_HOUR attempts per clock hour across all clients, then ENROLL_PER_HOUR per client
  // bucket (IPv4 address or IPv6 /64). The global cap bounds every row an unauthenticated client can create
  // (rl:, enonce:, pending:) and the enrollment alerts, however many addresses are used. Past-hour rl: rows and
  // expired enonce: rows are swept at most once per hour, never on every request.
  async enrollRateOk(bucket, now = Date.now()) {
    const hour = Math.floor(now / 3_600_000);
    const st = this.ctx.storage;
    if (((await st.get(RL_PRUNED)) ?? -1) < hour) await this.#sweepEnroll(hour, now);
    const allKey = rlKey(RL_ALL, hour);
    const all = (await st.get(allKey)) ?? 0;
    if (all >= ENROLL_GLOBAL_PER_HOUR) return false;
    await st.put(allKey, all + 1);
    const key = rlKey(bucket, hour);
    const n = (await st.get(key)) ?? 0;
    if (n >= ENROLL_PER_HOUR) return false;
    await st.put(key, n + 1);
    return true;
  }

  async #sweepEnroll(hour, now) {
    const st = this.ctx.storage;
    const dead = [...(await st.list({ prefix: "rl:" })).keys()]
      .filter((k) => Number(k.slice(k.lastIndexOf(":") + 1)) < hour);
    for (const [k, exp] of await st.list({ prefix: "enonce:" })) if (exp <= now) dead.push(k);
    for (let i = 0; i < dead.length; i += 128) await st.delete(dead.slice(i, i + 128));
    await st.put(RL_PRUNED, hour);
  }

  // A signed, verified enrollment. Returns "replay" | "member" | "full" | "new" | "refreshed".
  async enroll(login, pubkey, fp, nonce, ts, now = Date.now()) {
    const st = this.ctx.storage;
    // own nonce space: unauthenticated enrollers never write to the nonce: rows that #prune walks on every call
    if ((await st.get(enonceKey(nonce))) !== undefined) return "replay";
    await st.put(enonceKey(nonce), Math.max(now, ts * 1000) + TTL_MS);
    if ((await st.get(fpKey(fp))) !== undefined) return "member";
    const live = await this.#prunePending(now);
    const key = pendingKey(login, fp);
    const had = (await st.get(key)) !== undefined;
    if (!had && live >= MAX_PENDING) return "full";
    await st.put(key, { pubkey, ts: Math.floor(now / 1000) });
    return had ? "refreshed" : "new";
  }

  async isMemberKey(login, fp) {
    return (await this.ctx.storage.get(fpKey(fp))) === login;
  }

  // The active member key with this fingerprint: {login, pubkey}, or null (unknown, pending or revoked).
  async memberByFp(fp) {
    const st = this.ctx.storage;
    const login = await st.get(fpKey(fp));
    if (login === undefined) return null;
    const k = ((await st.get(memberKey(login))) ?? []).find((e) => e.fp === fp);
    return k ? { login, pubkey: k.pubkey } : null;
  }

  // Admin command, already authenticated and validated. Returns { status, body }.
  async admin(cmd, args, adminFp, now = Date.now()) {
    const st = this.ctx.storage;
    const ok = { status: 200, body: { ok: true } };
    const err = (status, error) => ({ status, body: { error } });
    await this.#prunePending(now);

    if (cmd === "approve") {
      const { login, fingerprint: fp } = args;
      const p = await st.get(pendingKey(login, fp));
      if (p === undefined) return err(404, "no such pending enrollment");
      const owner = await st.get(fpKey(fp));
      if (owner !== undefined && owner !== login) return err(409, "key belongs to another member");
      const keys = (await st.get(memberKey(login))) ?? [];
      if (!keys.some((k) => k.fp === fp)) {
        if (keys.length >= MAX_KEYS_PER_MEMBER) return err(409, `member has ${MAX_KEYS_PER_MEMBER} keys`);
        if (!keys.length && (await st.list({ prefix: "member:" })).size >= MAX_MEMBERS) {
          return err(409, `org has ${MAX_MEMBERS} members`);
        }
        keys.push({ pubkey: p.pubkey, fp, added_ts: Math.floor(now / 1000), added_by: adminFp });
      }
      await st.put({ [memberKey(login)]: keys, [fpKey(fp)]: login });
      await st.delete(pendingKey(login, fp));
      return ok;
    }
    if (cmd === "revoke") {
      const { login, fingerprint: fp } = args;
      const keys = (await st.get(memberKey(login))) ?? [];
      const gone = keys.filter((k) => fp === undefined || k.fp === fp);
      const pend = [...(await st.list({ prefix: `pending:${login}:` })).keys()]
        .filter((k) => fp === undefined || k === pendingKey(login, fp));
      if (!gone.length && !pend.length) return err(404, "no such member or key");
      const left = keys.filter((k) => !gone.includes(k));
      if (left.length) await st.put(memberKey(login), left);
      else await st.delete(memberKey(login));
      await st.delete([...gone.map((k) => fpKey(k.fp)), ...pend]);
      return ok;
    }
    if (cmd === "list") {
      const members = [...(await st.list({ prefix: "member:" }))]
        .map(([k, v]) => ({ login: k.slice("member:".length), fps: v.map((e) => e.fp) }));
      const pending = [...(await st.list({ prefix: "pending:" }))].map(([k, v]) => {
        const rest = k.slice("pending:".length), i = rest.indexOf(":");
        return { login: rest.slice(0, i), fp: rest.slice(i + 1), ts: v.ts };
      });
      const bots = [...(await st.list({ prefix: "bot:" })).keys()].map((k) => k.slice("bot:".length));
      return { status: 200, body: { members, pending, bots } };
    }
    if (cmd === "allow-bot") {
      if ((await st.get(botKey(args.login))) === undefined) {
        if ((await st.list({ prefix: "bot:" })).size >= MAX_BOTS) return err(409, `org has ${MAX_BOTS} bots`);
        await st.put(botKey(args.login), { added_ts: Math.floor(now / 1000), added_by: adminFp });
      }
      return ok;
    }
    if (cmd === "disallow-bot") {
      if (!(await st.delete(botKey(args.login)))) return err(404, "no such bot");
      return ok;
    }
    return err(400, "unknown command");
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
    for (const prefix of ["note:", "nonce:"]) for (const [, v] of await st.list({ prefix })) c.push(noteExp(v) + 1000);
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
    try { await notifyEvents(loud, this.env, 8000, (n) => this.callAllowed(n)); } catch (e) { console.error("notify failed", e); }
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
      const recent = [...(await st.list({ prefix: "un:" }))].map(([, u]) => u);
      let level, flags;
      if (p.org) {
        // org mode: the note must be signed by the pusher; the push record carries sender, webflow, web_flow
        const login = p.sender?.login ?? null;
        const ctx = {
          logins: await this.noteLogins(p.repo, p.ref, p.after, now),
          enrolled: login !== null && (await st.get(memberKey(login))) !== undefined,
          allowlisted: login !== null && (await st.get(botKey(login))) !== undefined,
          webFlow: p.web_flow,
        };
        ({ level, flags } = classifyOrg({ ...push, sender: p.sender ?? null, webflow: p.webflow === true }, ctx, recent));
        push.pusher = login;
      } else {
        ({ level, flags } = classify(push, await this.hasNote(p.repo, p.ref, p.after, now), recent));
      }
      // burst window: every non-silent push (personal mode: silent exactly when noted)
      if (level !== "silent") await st.put(unKey(push.ts, p.delivery), { repo: p.repo, ref: p.ref, ts: push.ts });
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
