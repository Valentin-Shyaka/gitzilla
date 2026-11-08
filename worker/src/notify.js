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
      ? `${icon} Watchdog: disarmed (${repos})`
      : `${icon} Watchdog: ${repos}`;
  const ordered = events.length > ALERT_LIST_MAX
    ? [...events.filter((e) => e.level === "critical"), ...events.filter((e) => e.level !== "critical")]
    : events;
  const lines = ordered.slice(0, ALERT_LIST_MAX).map((e) => {
    const flags = (e.flags ?? []).join(", ") || "-";
    if (e.kind === "disarmed") {
      return `Watchdog disarmed: ${cap(e.repo)}\nTime: ${utc(e.ts)} / ${local(e.ts, tz)}\nFlags: ${flags}`;
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
  if (a.kind === "new-key") {
    const src = a.source === "signing" ? "signing" : "authentication";
    return {
      title: "🔴 Watchdog: new key on your GitHub account",
      body: [`New ${src} key: ${cap(a.key_type)} ${cap(a.fingerprint)}`, time,
        "Review keys: https://github.com/settings/keys", "", REVOKE].join("\n"),
      priority: 5,
    };
  }
  return {
    title: "🟠 Watchdog: possible missed webhook",
    body: [`${Number(a.refs)} ref(s) in ${Number(a.repos)} repo(s) differ from the known heads (possible missed webhook).`,
      time, "", REVOKE].join("\n"),
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
  return { title: "Account watchdog: restore report", body, priority: 4 };
}

export async function notify(event, env, timeoutMs = 8000) {
  return send(formatAlert([event], env.ALERT_TZ), env, timeoutMs);
}

// One alert for several events (one alarm run).
export async function notifyEvents(events, env, timeoutMs = 8000) {
  if (!events.length) return;
  return send(formatAlert(events, env.ALERT_TZ), env, timeoutMs);
}

export async function notifyAccountAlert(a, env, timeoutMs = 8000) {
  return send(formatAccountAlert(a, env.ALERT_TZ), env, timeoutMs);
}

export async function notifyReport(report, env, timeoutMs = 8000) {
  return send(formatReport(report), env, timeoutMs);
}

async function send({ title, body, priority }, env, timeoutMs) {
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
    await Promise.allSettled(jobs);
  } catch (e) {
    console.error("notify failed", e);
  }
}
