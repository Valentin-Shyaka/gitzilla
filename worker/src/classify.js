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
