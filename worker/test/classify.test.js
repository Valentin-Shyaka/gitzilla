import { describe, it, expect } from "vitest";
import { classify } from "../src/classify.js";

const A = "a".repeat(40), B = "b".repeat(40), Z = "0".repeat(40);
const NOW = 1_790_812_800; // seconds
const push = (o = {}) => ({ repo: "o/r", ref: "refs/heads/main", before: A, after: B, forced: false, ts: NOW, ...o });
const un = (repo, ref, age = 60) => ({ repo, ref, ts: NOW - age });

describe("classify", () => {
  it("noted, not forced -> silent", () => {
    expect(classify(push(), true, [])).toEqual({ level: "silent", flags: [] });
  });
  it("not noted -> warning no-note", () => {
    expect(classify(push(), false, [])).toEqual({ level: "warning", flags: ["no-note"] });
  });
  it("not noted, forced -> critical no-note,forced", () => {
    expect(classify(push({ forced: true }), false, [])).toEqual({ level: "critical", flags: ["no-note", "forced"] });
  });
  it("3 repos in the last 10 minutes -> critical burst", () => {
    const r = classify(push(), false, [un("o/x", "refs/heads/a"), un("o/y", "refs/heads/a")]);
    expect(r.level).toBe("critical");
    expect(r.flags).toEqual(["no-note", "burst"]);
  });
  it("5 refs in one repo -> critical burst", () => {
    const recent = [1, 2, 3, 4].map((i) => un("o/r", `refs/heads/b${i}`));
    const r = classify(push(), false, recent);
    expect(r.level).toBe("critical");
    expect(r.flags).toContain("burst");
  });
  it("3 refs in repo A + 2 refs in repo B (refs counted across repos) -> critical burst", () => {
    const recent = [un("o/a", "refs/heads/1"), un("o/a", "refs/heads/2"), un("o/b", "refs/heads/1")];
    const r = classify(push({ repo: "o/a", ref: "refs/heads/3" }), false, [...recent, un("o/b", "refs/heads/2")]);
    expect(r).toEqual({ level: "critical", flags: ["no-note", "burst"] });
  });
  it("4 distinct refs across 2 repos -> warning", () => {
    const recent = [un("o/a", "refs/heads/1"), un("o/a", "refs/heads/2"), un("o/b", "refs/heads/1")];
    expect(classify(push({ repo: "o/b", ref: "refs/heads/2" }), false, recent)).toEqual({ level: "warning", flags: ["no-note"] });
  });
  it("the same pushes 11 minutes old -> warning", () => {
    const recent = [1, 2, 3, 4].map((i) => un("o/r", `refs/heads/b${i}`, 660));
    expect(classify(push(), false, recent)).toEqual({ level: "warning", flags: ["no-note"] });
    expect(classify(push(), false, [un("o/x", "r", 660), un("o/y", "r", 660)]).level).toBe("warning");
  });
  it("repeated pushes to the same ref are not a burst", () => {
    const recent = [1, 2, 3, 4, 5].map(() => un("o/r", "refs/heads/main"));
    expect(classify(push(), false, recent).level).toBe("warning");
  });
  it("before all zeros -> created, after all zeros -> deleted", () => {
    expect(classify(push({ before: Z }), false, []).flags).toEqual(["no-note", "created"]);
    expect(classify(push({ after: Z }), false, []).flags).toEqual(["no-note", "deleted"]);
  });
  it("an un-noted tag push is a warning", () => {
    expect(classify(push({ ref: "refs/tags/v1" }), false, [])).toEqual({ level: "warning", flags: ["no-note"] });
  });
});
