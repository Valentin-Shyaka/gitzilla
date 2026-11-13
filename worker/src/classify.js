// Pure push classification. Times are unix seconds.
export const BURST_WINDOW_S = 600;
const ZERO = "0".repeat(40);

// push: {repo, ref, before, after, forced, ts}; noted: a matching signed note exists;
// recentUnnoted: earlier un-noted pushes {repo, ref, ts}. Returns {level, flags}.
export function classify(push, noted, recentUnnoted) {
  const flags = [];
  if (noted) {
    if (push.before === ZERO) flags.push("created");
    if (push.after === ZERO) flags.push("deleted");
    return { level: "silent", flags };
  }
  flags.push("no-note");
  if (push.forced) flags.push("forced");

  const recent = recentUnnoted.filter((p) => push.ts - p.ts <= BURST_WINDOW_S && p.ts <= push.ts);
  const all = [...recent, push];
  const repos = new Set(all.map((p) => p.repo));
  const refs = new Set(all.map((p) => `${p.repo}|${p.ref}`));
  const burst = repos.size >= 3 || refs.size >= 5;
  if (burst) flags.push("burst");
  if (push.before === ZERO) flags.push("created");
  if (push.after === ZERO) flags.push("deleted");

  return { level: push.forced || burst ? "critical" : "warning", flags };
}

// Org mode. push additionally carries sender {login (lowercased), type} or null, and webflow (every commit
// committed by GitHub's web-flow). ctx: {logins: who signed a note for this exact repo|ref|sha, enrolled: the
// sender is a member, allowlisted: the sender is an allowlisted bot, webFlow: env.WEB_FLOW}. recentUnnoted:
// every earlier non-silent push in the window, whoever pushed it. A note only counts when the sender signed it.
export function classifyOrg(push, ctx, recentUnnoted) {
  const login = push.sender?.login;
  const edge = () => [
    ...(push.before === ZERO ? ["created"] : []),
    ...(push.after === ZERO ? ["deleted"] : []),
  ];
  if (login && (ctx.logins ?? []).includes(login)) return { level: "silent", flags: edge() };
  if (push.sender?.type === "Bot" || (login && ctx.allowlisted)) return { level: "silent", flags: ["bot", ...edge()] };
  if (push.webflow && ctx.webFlow === "silent") return { level: "silent", flags: ["web-flow", ...edge()] };

  const flags = [push.webflow ? "web-flow" : login && ctx.enrolled ? "no-note" : "unenrolled"];
  if (push.forced) flags.push("forced");
  const recent = recentUnnoted.filter((p) => push.ts - p.ts <= BURST_WINDOW_S && p.ts <= push.ts);
  const all = [...recent, push];
  const burst = new Set(all.map((p) => p.repo)).size >= 3 || new Set(all.map((p) => `${p.repo}|${p.ref}`)).size >= 5;
  if (burst) flags.push("burst");
  flags.push(...edge());
  return { level: push.forced || burst ? "critical" : "warning", flags };
}
