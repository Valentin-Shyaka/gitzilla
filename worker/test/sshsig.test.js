import { describe, it, expect } from "vitest";
import { verifySshSig } from "../src/sshsig.js";
import SIG from "./fixtures/msg.sig?raw";
import PUB from "./fixtures/key.pub?raw";
import OTHER from "./fixtures/other.pub?raw";
import MSG_TXT from "./fixtures/msg.txt?raw";

const enc = (s) => new TextEncoder().encode(s);
const MSG = enc(MSG_TXT);

describe("verifySshSig", () => {
  it("accepts a valid signature", async () =>
    expect(await verifySshSig(SIG, MSG, "account-watchdog-note", PUB)).toBe(true));
  it("rejects a tampered message", async () =>
    expect(await verifySshSig(SIG, enc("tampered"), "account-watchdog-note", PUB)).toBe(false));
  it("rejects the wrong namespace", async () =>
    expect(await verifySshSig(SIG, MSG, "account-watchdog-queue", PUB)).toBe(false));
  it("rejects a different key", async () =>
    expect(await verifySshSig(SIG, MSG, "account-watchdog-note", OTHER)).toBe(false));
  it("returns false on garbage", async () =>
    expect(await verifySshSig("nope", MSG, "account-watchdog-note", PUB)).toBe(false));
});
