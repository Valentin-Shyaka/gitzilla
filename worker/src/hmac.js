const enc = new TextEncoder();

// Verifies GitHub's X-Hub-Signature-256 header ("sha256=<hex>") over the raw body.
export async function verifyGithubSignature(secret, body, header) {
  if (!header || !header.startsWith("sha256=")) return false;
  const hex = header.slice("sha256=".length);
  if (!/^[0-9a-f]{64}$/i.test(hex)) return false;
  const given = new Uint8Array(32);
  for (let i = 0; i < 32; i++) given[i] = parseInt(hex.substr(i * 2, 2), 16);
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  // subtle.verify compares in constant time.
  return crypto.subtle.verify("HMAC", key, given, body);
}
