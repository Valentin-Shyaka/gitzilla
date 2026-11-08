import { describe, it, expect } from "vitest";
import { verifyGithubSignature } from "../src/hmac.js";

const enc = (s) => new TextEncoder().encode(s);
const body = enc('{"hello":"world"}');

async function header(secret, data) {
  const key = await crypto.subtle.importKey("raw", enc(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, data));
  return "sha256=" + [...mac].map((b) => b.toString(16).padStart(2, "0")).join("");
}

describe("verifyGithubSignature", () => {
  it("accepts a valid header", async () =>
    expect(await verifyGithubSignature("s3cret", body, await header("s3cret", body))).toBe(true));
  it("rejects the wrong secret", async () =>
    expect(await verifyGithubSignature("other", body, await header("s3cret", body))).toBe(false));
  it("rejects a tampered body", async () =>
    expect(await verifyGithubSignature("s3cret", enc("x"), await header("s3cret", body))).toBe(false));
  it("rejects a missing header", async () =>
    expect(await verifyGithubSignature("s3cret", body, null)).toBe(false));
  it("rejects a header without the sha256= prefix", async () => {
    const h = (await header("s3cret", body)).slice("sha256=".length);
    expect(await verifyGithubSignature("s3cret", body, h)).toBe(false);
  });
  it("rejects non-hex or wrong-length digests", async () => {
    expect(await verifyGithubSignature("s3cret", body, "sha256=zz")).toBe(false);
    expect(await verifyGithubSignature("s3cret", body, "sha256=")).toBe(false);
  });
});
