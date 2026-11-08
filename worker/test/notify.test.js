import { describe, it, expect, afterEach, vi } from "vitest";
import { formatAlert, formatAccountAlert, alertTz, notify } from "../src/notify.js";

const REVOKE = "If this wasn't you: revoke tokens at https://github.com/settings/applications";
const base = {
  seq: 1, delivery: "d1", ts: 1790000000, kind: "push", repo: "owner/repo",
  ref: "refs/heads/main", before: "abc1234ffffffff", after: "def5678eeeeeeee",
  forced: true, level: "critical", flags: ["force-push", "unsigned"],
};

afterEach(() => vi.restoreAllMocks());

describe("formatAlert", () => {
  it("critical forced push", () => {
    const { title, body, priority } = formatAlert([base], "Africa/Kigali");
    expect(title.startsWith("🔴 gitzilla:")).toBe(true);
    expect(title).toContain("owner/repo");
    expect(priority).toBe(5);
    expect(body).toContain("refs/heads/main");
    expect(body).toContain("abc1234 → def5678");
    expect(body).toContain("UTC");
    expect(body).toContain("2026-09-21 14:13:20 UTC");
    expect(body).toMatch(/16:13:20 \(Africa\/Kigali\)/);
    expect(body).toContain("force-push");
    expect(body).toContain("unsigned");
    expect(body.endsWith(REVOKE)).toBe(true);
  });

  it("warning", () => {
    const r = formatAlert([{ ...base, level: "warning", forced: false }]);
    expect(r.title).toContain("🟠");
    expect(r.priority).toBe(3);
    expect(r.body.endsWith(REVOKE)).toBe(true);
  });

  it("disarmed", () => {
    const r = formatAlert([{ ...base, kind: "disarmed", repo: "a,b", ref: "", before: "", after: "", forced: false }]);
    expect(r.title).toContain("disarmed");
    expect(r.body.endsWith(REVOKE)).toBe(true);
  });

  it("all-zero sha renders (none)", () => {
    const r = formatAlert([{ ...base, before: "0".repeat(40) }]);
    expect(r.body).toContain("(none) → def5678");
  });

  it("never includes extra fields", () => {
    const r = formatAlert([{ ...base, diff: "SECRET_DIFF_CONTENT", delivery: "DELIVERY-XYZ" }]);
    expect(r.body).not.toContain("SECRET_DIFF_CONTENT");
    expect(r.body).not.toContain("DELIVERY-XYZ");
    expect(r.title).not.toContain("SECRET_DIFF_CONTENT");
  });
});

describe("alert time zone", () => {
  it("custom zone from ALERT_TZ", () => {
    const { body } = formatAlert([base], "America/New_York");
    expect(body).toContain("2026-09-21 14:13:20 UTC / 21/09/2026, 10:13:20 (America/New_York)");
  });
  it("defaults to UTC", () => {
    expect(formatAlert([base]).body).toContain("2026-09-21 14:13:20 UTC / 21/09/2026, 14:13:20 (UTC)");
    expect(formatAlert([base], undefined).body).toContain("(UTC)");
    expect(formatAlert([base], "").body).toContain("(UTC)");
  });
  it("invalid zone falls back to UTC", () => {
    expect(alertTz("Not/AZone")).toBe("UTC");
    expect(alertTz(42)).toBe("UTC");
    const { body } = formatAlert([base], "Not/AZone");
    expect(body).toContain("14:13:20 (UTC)");
    expect(body).not.toContain("Not/AZone");
    expect(formatAccountAlert({ kind: "new-key", source: "auth", key_type: "ssh-ed25519", fingerprint: "SHA256:x", ts: 1790000000 }, "Bad/Zone").body)
      .toContain("14:13:20 (UTC)");
  });
  it("notify passes env.ALERT_TZ through", async () => {
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
    await notify(base, { NTFY_TOPIC: "t", ALERT_TZ: "Asia/Tokyo" });
    expect(JSON.parse(f.mock.calls[0][1].body).message).toContain("23:13:20 (Asia/Tokyo)");
    f.mockClear();
    await notify(base, { NTFY_TOPIC: "t", ALERT_TZ: "Nope/Nope" });
    expect(JSON.parse(f.mock.calls[0][1].body).message).toContain("14:13:20 (UTC)");
  });
});

describe("notify", () => {
  const env = { NTFY_TOPIC: "t0pic", SLACK_WEBHOOK_URL: "https://hooks.slack.test/x" };

  it("posts JSON to ntfy and Slack", async () => {
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
    await notify(base, env);
    const ntfy = f.mock.calls.find((c) => c[0] === "https://ntfy.sh");
    const slack = f.mock.calls.find((c) => c[0] === env.SLACK_WEBHOOK_URL);
    const nb = JSON.parse(ntfy[1].body);
    expect(nb).toMatchObject({ topic: "t0pic", priority: 5, tags: ["rotating_light"] });
    expect(nb.title.startsWith("🔴")).toBe(true);
    expect(nb.message.endsWith(REVOKE)).toBe(true);
    expect(JSON.parse(slack[1].body).text).toContain(nb.title + "\n" + nb.message);
  });

  it("Slack is optional: no SLACK_WEBHOOK_URL -> ntfy only", async () => {
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
    await notify(base, { NTFY_TOPIC: "t0pic" });
    expect(f).toHaveBeenCalledTimes(1);
    expect(f.mock.calls[0][0]).toBe("https://ntfy.sh");
  });

  it("ntfy 500 still calls Slack and resolves", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const f = vi.spyOn(globalThis, "fetch").mockImplementation(async (u) =>
      u === "https://ntfy.sh" ? new Response("no", { status: 500 }) : new Response("ok"));
    await expect(notify(base, env)).resolves.toBeUndefined();
    expect(f.mock.calls.some((c) => c[0] === env.SLACK_WEBHOOK_URL)).toBe(true);
    expect(err).toHaveBeenCalled();
  });

  it("thrown fetch is contained; unset senders skipped", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const f = vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("boom"));
    await expect(notify(base, env)).resolves.toBeUndefined();
    f.mockClear();
    await notify(base, {});
    expect(f).not.toHaveBeenCalled();
  });

  it("escapes Slack text, keeps ntfy plain", async () => {
    const f = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("ok"));
    await notify({ ...base, ref: "refs/heads/<!channel>" }, env);
    await notify({ ...base, ref: "<https://evil.example|x>" }, env);
    const slack = f.mock.calls.filter((c) => c[0] === env.SLACK_WEBHOOK_URL).map((c) => JSON.parse(c[1].body).text);
    const ntfy = f.mock.calls.filter((c) => c[0] === "https://ntfy.sh").map((c) => JSON.parse(c[1].body).message);
    expect(slack[0]).toContain("&lt;!channel&gt;");
    expect(slack[1]).toContain("&lt;https://evil.example|x&gt;");
    for (const t of slack) expect(t).not.toMatch(/[<>]/);
    expect(ntfy[0]).toContain("<!channel>");
    expect(slack[0].endsWith(REVOKE)).toBe(true);
  });

  it("truncates long repo/ref to 200 + ellipsis", () => {
    const r = formatAlert([{ ...base, ref: "r".repeat(300), repo: "p".repeat(300) }]);
    expect(r.body).toContain("r".repeat(200) + "…");
    expect(r.body).not.toContain("r".repeat(201));
    expect(r.title).toContain("p".repeat(200) + "…");
    expect(r.title).not.toContain("p".repeat(201));
  });

  it("hung sender times out; other sender still called", async () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    const f = vi.spyOn(globalThis, "fetch").mockImplementation((u, init) =>
      u === "https://ntfy.sh"
        ? new Promise((_, rej) => init.signal.addEventListener("abort", () => rej(init.signal.reason)))
        : Promise.resolve(new Response("ok")));
    await expect(notify(base, env, 20)).resolves.toBeUndefined();
    expect(f.mock.calls.some((c) => c[0] === env.SLACK_WEBHOOK_URL)).toBe(true);
  });
});
