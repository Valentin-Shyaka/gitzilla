// OpenSSH SSHSIG verification for ecdsa-sha2-nistp256 keys (e.g. Secure Enclave).
// Format: https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.sshsig

const KEY_TYPE = "ecdsa-sha2-nistp256";
const HASHES = { sha256: "SHA-256", sha512: "SHA-512" };
const BEGIN = "-----BEGIN SSH SIGNATURE-----";
const END = "-----END SSH SIGNATURE-----";

const te = new TextEncoder();
const td = new TextDecoder("utf-8", { fatal: true });

function b64decode(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function equal(a, b) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

// SSH wire reader: throws RangeError on truncation (caught by caller).
class Reader {
  constructor(buf) {
    this.buf = buf;
    this.off = 0;
  }
  u32() {
    if (this.off + 4 > this.buf.length) throw new RangeError("truncated");
    const v = new DataView(this.buf.buffer, this.buf.byteOffset + this.off, 4).getUint32(0);
    this.off += 4;
    return v;
  }
  bytes() {
    const n = this.u32();
    if (this.off + n > this.buf.length) throw new RangeError("truncated");
    const out = this.buf.subarray(this.off, this.off + n);
    this.off += n;
    return out;
  }
  string() {
    return td.decode(this.bytes());
  }
  done() {
    return this.off === this.buf.length;
  }
}

function sshString(bytes) {
  const b = typeof bytes === "string" ? te.encode(bytes) : bytes;
  const out = new Uint8Array(4 + b.length);
  new DataView(out.buffer).setUint32(0, b.length);
  out.set(b, 4);
  return out;
}

// mpint -> fixed 32-byte big-endian
function mpintTo32(m) {
  let i = 0;
  while (i < m.length && m[i] === 0) i++;
  const v = m.subarray(i);
  if (v.length > 32) throw new RangeError("mpint too large");
  const out = new Uint8Array(32);
  out.set(v, 32 - v.length);
  return out;
}

export async function verifySshSig(armoredSig, message, namespace, publicKeyLine) {
  try {
    // Expected public key blob
    const parts = String(publicKeyLine).trim().split(/\s+/);
    if (parts[0] !== KEY_TYPE || !parts[1]) return false;
    const expectedBlob = b64decode(parts[1]);

    // De-armor
    const lines = String(armoredSig).trim().split(/\r?\n/).map((l) => l.trim());
    if (lines[0] !== BEGIN || lines[lines.length - 1] !== END) return false;
    const raw = b64decode(lines.slice(1, -1).join(""));

    if (!equal(raw.subarray(0, 6), te.encode("SSHSIG"))) return false;
    const r = new Reader(raw.subarray(6));
    if (r.u32() !== 1) return false;
    const blob = r.bytes();
    const ns = r.string();
    const reserved = r.bytes();
    const hashAlg = r.string();
    const sigOuter = r.bytes();
    if (!r.done()) return false;

    if (!equal(blob, expectedBlob)) return false;
    if (ns !== namespace) return false;
    const hashName = HASHES[hashAlg];
    if (!hashName) return false;

    // Public key blob: string type, string curve, string point
    const k = new Reader(blob);
    if (k.string() !== KEY_TYPE) return false;
    if (k.string() !== "nistp256") return false;
    const point = k.bytes();
    if (!k.done() || point.length !== 65 || point[0] !== 4) return false;

    // Signature blob: string type, string (mpint r || mpint s)
    const s = new Reader(sigOuter);
    if (s.string() !== KEY_TYPE) return false;
    const inner = new Reader(s.bytes());
    if (!s.done()) return false;
    const rawSig = concat(mpintTo32(inner.bytes()), mpintTo32(inner.bytes()));
    if (!inner.done()) return false;

    const msgHash = new Uint8Array(await crypto.subtle.digest(hashName, message));
    const signedData = concat(
      te.encode("SSHSIG"),
      sshString(ns),
      sshString(reserved),
      sshString(hashAlg),
      sshString(msgHash),
    );

    const key = await crypto.subtle.importKey(
      "raw",
      point,
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, rawSig, signedData);
  } catch {
    return false;
  }
}
