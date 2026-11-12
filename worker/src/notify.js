const REVOKE = "If this wasn't you: revoke tokens at https://github.com/settings/applications";

const cap = (v) => { v = String(v ?? ""); return v.length > 200 ? v.slice(0, 200) + "…" : v; };
const slackEscape = (t) => t.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const short = (sha) => (!sha || /^0+$/.test(sha) ? "(none)" : sha.slice(0, 7));
const utc = (ts) => new Date(ts * 1000).toISOString().slice(0, 19).replace("T", " ") + " UTC";
// alertTz <zone>: the IANA zone for the local time in alerts (env.ALERT_TZ, a deploy --var); "UTC" when it is missing
// or not a zone Intl knows (Intl.DateTimeFormat throws a RangeError on an invalid timeZone).
export function alertTz(tz) {
  if (typeof tz !== "string" || !tz) return "UTC";
  try {
    new Intl.DateTimeFormat("en-GB", { timeZone: tz });
    return tz;
  } catch {
    return "UTC";
  }
}
const local = (ts, tz) =>
  new Intl.DateTimeFormat("en-GB", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false,
  }).format(new Date(ts * 1000)) + ` (${tz})`;

const ALERT_LIST_MAX = 10;
const TITLE_REPOS_MAX = 5;

// Pure. Only repo/ref/short SHAs/times/flags are ever rendered; never commit content.
// Several events (one alarm run) become ONE alert: critical wins over warning, at most ALERT_LIST_MAX events
// are listed (critical first), and the revoke line ends the body exactly once.
export function formatAlert(events, tz = "UTC") {
  tz = alertTz(tz);
  const critical = events.some((e) => e.level === "critical");
  const first = events[0];
  const icon = critical ? "🔴" : "🟠";
  const allRepos = [...new Set(events.map((e) => cap(e.repo)))];
  const repos = allRepos.slice(0, TITLE_REPOS_MAX).join(", ") +
    (allRepos.length > TITLE_REPOS_MAX ? ` +${allRepos.length - TITLE_REPOS_MAX} more` : "");
  const title =
    first.kind === "disarmed" && events.length === 1
      ? `${icon} gitzilla disarmed (${repos})`
      : `${icon} gitzilla: ${repos}`;
  const ordered = events.length > ALERT_LIST_MAX
    ? [...events.filter((e) => e.level === "critical"), ...events.filter((e) => e.level !== "critical")]
    : events;
  const lines = ordered.slice(0, ALERT_LIST_MAX).map((e) => {
    const flags = (e.flags ?? []).join(", ") || "-";
    if (e.kind === "disarmed") {
      return `gitzilla disarmed: ${cap(e.repo)}\nTime: ${utc(e.ts)} / ${local(e.ts, tz)}\nFlags: ${flags}`;
    }
    return [
      `Repo: ${cap(e.repo)}`,
      `Ref: ${cap(e.ref)}${e.forced ? " (forced)" : ""}`,
      `Commits: ${short(e.before)} → ${short(e.after)}`,
      `Time: ${utc(e.ts)} / ${local(e.ts, tz)}`,
      `Flags: ${flags}`,
    ].join("\n");
  });
  if (events.length > 1) {
    const nc = events.filter((e) => e.level === "critical").length;
    lines.unshift(`${events.length} events, ${nc} critical`);
  }
  if (events.length > ALERT_LIST_MAX) lines.push(`…and ${events.length - ALERT_LIST_MAX} more event(s)`);
  return { title, body: lines.join("\n\n") + "\n\n" + REVOKE, priority: critical ? 5 : 3 };
}

// Pure. Account alerts from the Mac's reconcile (POST /alert). Only the validated fixed fields are rendered.
export function formatAccountAlert(a, tz = "UTC") {
  tz = alertTz(tz);
  const time = `Time: ${utc(a.ts)} / ${local(a.ts, tz)}`;
  if (a.kind === "test") {
    return {
      title: "🔴 gitzilla: test alert",
      body: ["This is a test of every alert channel.", time, "", REVOKE].join("\n"),
      priority: 5,
    };
  }
  if (a.kind === "new-key") {
    const src = a.source === "signing" ? "signing" : "authentication";
    return {
      title: "🔴 gitzilla: new key on your GitHub account",
      body: [`New ${src} key: ${cap(a.key_type)} ${cap(a.fingerprint)}`, time,
        "Review keys: https://github.com/settings/keys", "", REVOKE].join("\n"),
      priority: 5,
    };
  }
  return {
    title: "🟠 gitzilla: possible missed webhook",
    body: [`${Number(a.refs)} ref(s) in ${Number(a.repos)} repo(s) differ from the known heads (possible missed webhook).`,
      time, "", REVOKE].join("\n"),
    priority: 3,
  };
}

// Pure. Org-mode enrollment request: a warning (priority 3, so never a phone call). login and fp are validated
// by the caller (login charset [a-z0-9-], fp "SHA256:" + base64).
export function formatEnrollment({ login, fp }) {
  return {
    title: "🟠 gitzilla: enrollment request",
    body: [`Login: ${cap(login)}`, `Key: ${cap(fp)}`, "", REVOKE].join("\n"),
    priority: 3,
  };
}

async function post(name, url, payload, timeoutMs) {
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) console.error(`${name} notify failed: HTTP ${res.status}`);
  } catch (e) {
    console.error(`${name} notify failed`, e);
  }
}

const LIST_MAX = 10;
const section = (head, items) => {
  if (!items.length) return [];
  const lines = items.slice(0, LIST_MAX);
  if (items.length > LIST_MAX) lines.push(`…and ${items.length - LIST_MAX} more`);
  return ["", head, ...lines];
};

// Pure. Renders only validated repo/ref/reason fields; never free text from the caller.
export function formatReport(report) {
  const restored = report.restored ?? [], skipped = report.skipped ?? [];
  const count = (total, list) => {
    const t = Number.isInteger(total) ? total : list.length;
    return t === list.length ? `${t}` : `${t} (${list.length} listed)`;
  };
  const body = [
    `Restored ${count(report.restored_total, restored)}, skipped ${count(report.skipped_total, skipped)}`,
    ...section("Restored:", restored.map((e) => `${cap(e.repo)} ${cap(e.ref)}`)),
    ...section("Skipped:", skipped.map((e) => `${cap(e.repo)} ${cap(e.ref)}: ${String(e.reason ?? "").slice(0, 120)}`)),
    "",
    REVOKE,
  ].join("\n");
  return { title: "gitzilla: restore report", body, priority: 4 };
}

// Phone numbers for red-alert calls: comma separated +E164, deduped, at most 5.
export function parseCallNumbers(str) {
  const out = [];
  for (const part of String(str ?? "").split(",")) {
    const n = part.trim();
    if (/^\+[1-9][0-9]{6,14}$/.test(n) && !out.includes(n)) out.push(n);
  }
  return out.slice(0, 5);
}

const SPOKEN_TAIL = "Check Slack or the ntfy app, and revoke tokens if this was not you.";
const spokenName = (r) => String(r ?? "").toLowerCase().replace(/[^a-z0-9._/-]/g, "").slice(0, 60);
const spokenNames = (events) => {
  const all = [...new Set(events.map((e) => spokenName(e.repo)).filter(Boolean))];
  const shown = all.slice(0, 3);
  const more = all.length - shown.length;
  if (!shown.length) return "your repositories";
  if (more > 0) return `${shown.join(", ")} and ${more} more`;
  return shown.length > 1 ? `${shown.slice(0, -1).join(", ")} and ${shown[shown.length - 1]}` : shown[0];
};

// Pure. Spoken text for a call: no SHAs, no commit content, repo names reduced to [a-z0-9._/-].
export function formatCall(events) {
  const crit = events.filter((e) => e.level === "critical");
  const disarmed = crit.filter((e) => e.kind === "disarmed");
  if (disarmed.length && disarmed.length === crit.length) {
    return `gitzilla critical alert. gitzilla was disarmed for ${spokenNames(disarmed)}. ${SPOKEN_TAIL}`;
  }
  const list = crit.length ? crit : events;
  const n = list.length;
  return `gitzilla critical alert. Possible stolen GitHub credential. ${n} event${n === 1 ? "" : "s"} in ${spokenNames(list)}. ${SPOKEN_TAIL}`;
}

export function formatAccountCall(alert) {
  if (alert?.kind === "test") return "gitzilla test call. Your alert channels work.";
  return `gitzilla critical alert. A new key was added to your GitHub account. ${SPOKEN_TAIL}`;
}

export async function notify(event, env, timeoutMs = 8000, callGate) {
  return notifyEvents([event], env, timeoutMs, callGate);
}

// One alert for several events (one alarm run).
export async function notifyEvents(events, env, timeoutMs = 8000, callGate) {
  if (!events.length) return;
  const a = formatAlert(events, env.ALERT_TZ);
  if (a.priority === 5) a.spoken = formatCall(events);
  return send(a, env, timeoutMs, callGate);
}

export async function notifyAccountAlert(a, env, timeoutMs = 8000, callGate) {
  const m = formatAccountAlert(a, env.ALERT_TZ);
  if (m.priority === 5) m.spoken = formatAccountCall(a);
  return send(m, env, timeoutMs, callGate);
}

export async function notifyReport(report, env, timeoutMs = 8000) {
  return send(formatReport(report), env, timeoutMs);
}

// No callGate: an enrollment alert can never place a call.
export async function notifyEnrollment(e, env, timeoutMs = 8000) {
  return send(formatEnrollment(e), env, timeoutMs);
}

const mask = (n) => `+${"*".repeat(Math.max(n.length - 3, 0))}${n.slice(-2)}`;

async function call(number, { title, spoken }, env, timeoutMs, callGate) {
  try {
    if ((await callGate(number)) !== true) {
      console.error(`call suppressed (rate limit) for ${mask(number)}`);
      return;
    }
    const res = await fetch("https://ntfy.sh", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.NTFY_CALL_TOKEN}` },
      body: JSON.stringify({ topic: `${env.NTFY_TOPIC}-call`, title, message: spoken, priority: 5, call: number }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res.ok) console.error(`ntfy call failed: HTTP ${res.status} for ${mask(number)}`);
  } catch {
    console.error(`ntfy call failed for ${mask(number)}`);
  }
}

async function send({ title, body, priority, spoken }, env, timeoutMs, callGate) {
  try {
    const jobs = [];
    if (env.NTFY_TOPIC) {
      jobs.push(post("ntfy", "https://ntfy.sh", {
        topic: env.NTFY_TOPIC, title, message: body, priority,
        tags: [priority === 5 ? "rotating_light" : "warning"],
      }, timeoutMs));
    }
    if (env.SLACK_WEBHOOK_URL) {
      jobs.push(post("slack", env.SLACK_WEBHOOK_URL, { text: slackEscape(`${title}\n${body}`) }, timeoutMs));
    }
    if (priority === 5 && spoken && env.NTFY_TOPIC && typeof callGate === "function" &&
        /^tk_[A-Za-z0-9]{29}$/.test(env.NTFY_CALL_TOKEN ?? "")) {
      for (const n of parseCallNumbers(env.NTFY_CALL_NUMBERS)) {
        jobs.push(call(n, { title, spoken }, env, timeoutMs, callGate));
      }
    }
    await Promise.allSettled(jobs);
  } catch (e) {
    console.error("notify failed", e);
  }
}
