#!/usr/bin/env bash
# Regenerates the org-mode SSHSIG fixtures (POST /enroll, POST /admin, member-signed POST /note, org-mode queue/alert auth).
# Every key is new on each run; private keys live only in a temp dir that is removed on exit.
# Run with an isolated HOME (ssh-keygen never needs the real one).
set -euo pipefail
cd "$(dirname "$0")"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
rm -f ./*.pub ./*.fp ./*.json ./*.txt
for k in admin admin2 alice alice2 bob carol; do
  ssh-keygen -q -t ecdsa -b 256 -N '' -C "$k" -f "$W/$k"
  cp "$W/$k.pub" "$k.pub"
  # fingerprint exactly as ssh-keygen -lf prints it (field 2)
  ssh-keygen -lf "$k.pub" | awk '{print $2}' > "$k.fp"
done

W="$W" python3 - <<'PY'
import base64, json, os, subprocess
W = os.environ["W"]
TS = 4102444800  # 2100-01-01T00:00:00Z, same instant as the other fixtures
rd = lambda f: open(f, "rb").read()
pub = lambda k: rd(k + ".pub").decode().strip()
fp = lambda k: rd(k + ".fp").decode().strip()
n = [0]
def nonce():
    n[0] += 1
    return "%032x" % (0xabc0000000000000000000000000000 + n[0])

def sign(key, ns, data):
    p = os.path.join(W, "payload")
    open(p, "wb").write(data)
    if os.path.exists(p + ".sig"):
        os.remove(p + ".sig")
    subprocess.run(["ssh-keygen", "-q", "-Y", "sign", "-f", os.path.join(W, key), "-n", ns, p], check=True)
    return rd(p + ".sig").decode()

def body(name, key, ns, obj, sign_obj=None):
    data = json.dumps(obj, separators=(",", ":")).encode()
    sdata = data if sign_obj is None else json.dumps(sign_obj, separators=(",", ":")).encode()
    out = {"payload": base64.b64encode(data).decode(), "sig": sign(key, ns, sdata)}
    open(name + ".json", "w").write(json.dumps(out))

# --- enrollments: signed by the enrolling key itself, namespace gitzilla-enroll
E = lambda login, key, **o: dict({"login": login, "pubkey": pub(key), "ts": TS, "nonce": nonce()}, **o)
body("enroll-alice", "alice", "gitzilla-enroll", E("alice", "alice"))
body("enroll-alice-again", "alice", "gitzilla-enroll", E("alice", "alice"))
body("enroll-alice2", "alice2", "gitzilla-enroll", E("alice", "alice2"))
body("enroll-bob", "bob", "gitzilla-enroll", E("bob", "bob"))
body("enroll-upper", "bob", "gitzilla-enroll", E("Bob", "bob"))
body("enroll-wrongns", "alice", "gitzilla-admin", E("alice", "alice"))
# pubkey says bob, signature is alice's
body("enroll-badsig", "alice", "gitzilla-enroll", E("alice", "bob"))
# tampered: login changed after signing
t = E("alice", "alice")
body("enroll-tampered", "alice", "gitzilla-enroll", dict(t, login="mallory"), sign_obj=t)
body("enroll-badlogin", "alice", "gitzilla-enroll", E("al_ice!", "alice"))
body("enroll-dashlogin", "alice", "gitzilla-enroll", E("-alice", "alice"))
body("enroll-extra", "alice", "gitzilla-enroll", E("alice", "alice", note="hi"))
body("enroll-later", "alice", "gitzilla-enroll", E("alice", "alice", ts=TS + 600))
# carol enrolls but is never approved: her notes must never verify
body("enroll-carol", "carol", "gitzilla-enroll", E("carol", "carol"))

# --- admin commands: namespace gitzilla-admin
A = lambda cmd, args, **o: dict({"cmd": cmd, "args": args, "ts": TS, "nonce": nonce()}, **o)
body("admin-approve-alice", "admin", "gitzilla-admin", A("approve", {"login": "alice", "fingerprint": fp("alice")}))
body("admin-approve-alice2", "admin", "gitzilla-admin", A("approve", {"login": "alice", "fingerprint": fp("alice2")}))
body("admin-approve-bob", "admin", "gitzilla-admin", A("approve", {"login": "bob", "fingerprint": fp("bob")}))
body("admin-approve-bob-by-admin2", "admin2", "gitzilla-admin", A("approve", {"login": "bob", "fingerprint": fp("bob")}))
body("admin-revoke-alice", "admin", "gitzilla-admin", A("revoke", {"login": "alice"}))
body("admin-revoke-alice-fp", "admin", "gitzilla-admin", A("revoke", {"login": "alice", "fingerprint": fp("alice")}))
body("admin-revoke-bob", "admin", "gitzilla-admin", A("revoke", {"login": "bob"}))
for i in range(4):
    body("admin-list-%d" % i, "admin", "gitzilla-admin", A("list", {}))
body("admin-list-admin2", "admin2", "gitzilla-admin", A("list", {}))
body("admin-allow-bot", "admin", "gitzilla-admin", A("allow-bot", {"login": "dependabot[bot]"}))
body("admin-disallow-bot", "admin", "gitzilla-admin", A("disallow-bot", {"login": "dependabot[bot]"}))
body("admin-unknown", "admin", "gitzilla-admin", A("delete-everything", {}))
body("admin-badargs", "admin", "gitzilla-admin", A("approve", {"login": "alice"}))
body("admin-extraargs", "admin", "gitzilla-admin", A("list", {"x": 1}))
body("admin-badfp", "admin", "gitzilla-admin", A("approve", {"login": "alice", "fingerprint": "SHA256:nope"}))
body("admin-by-member", "alice", "gitzilla-admin", A("list", {}))
body("admin-approve-by-member", "alice", "gitzilla-admin", A("approve", {"login": "alice", "fingerprint": fp("alice")}))
body("admin-wrongns", "admin", "gitzilla-enroll", A("list", {}))
body("admin-late", "admin", "gitzilla-admin", A("list", {}, ts=TS + 360))

# --- member-signed push notes (namespace gitzilla-note), all for the same push acme/app refs/heads/main -> 4444...
N = lambda **o: dict({"repo": "acme/app", "ref": "refs/heads/main", "old_sha": "1" * 40, "new_sha": "4" * 40,
                      "ts": TS, "nonce": nonce()}, **o)
body("note-alice", "alice", "gitzilla-note", N())
body("note-alice-again", "alice", "gitzilla-note", N())
body("note-alice2", "alice2", "gitzilla-note", N())
body("note-bob", "bob", "gitzilla-note", N())
body("note-carol", "carol", "gitzilla-note", N())
body("note-admin", "admin", "gitzilla-note", N())
body("note-alice-wrongns", "alice", "gitzilla-admin", N())
# a login claimed in the payload is ignored: the signer is whoever owns the key
body("note-alice-claims-bob", "alice", "gitzilla-note", N(login="bob"))

# --- org-mode auth for the existing routes, signed by the admin key
b = lambda x: base64.b64encode(x).decode()
q = b'{"ts":%d}' % TS
open("queue-auth-admin.txt", "w").write(b(q) + "." + b(sign("admin", "gitzilla-queue", q).encode()))
body("alert-test-admin", "admin", "gitzilla-alert", {"kind": "test", "ts": TS, "nonce": nonce()})
body("report-admin", "admin", "gitzilla-report", {"ts": TS, "nonce": nonce(), "restored": [{"repo": "owner/name", "ref": "refs/heads/main"}], "skipped": [], "restored_total": 1, "skipped_total": 0})
PY
