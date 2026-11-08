#!/usr/bin/env bash
# Regenerates ALL SSHSIG test fixtures together (the key is new every run).
# Private keys are deleted after use, even on failure.
set -euo pipefail
cd "$(dirname "$0")"
trap 'rm -f key other note-payload.json note-payload.json.sig note-tampered-payload.json queue-payload.json queue-payload.json.sig queue-wrongns-payload.json queue-wrongns-payload.json.sig report-*-payload.json report-*-payload.json.sig alert-*-payload.json alert-*-payload.json.sig' EXIT
rm -f key key.pub other other.pub msg.txt msg.txt.sig msg.sig note-ok.json note-tampered.json queue-auth-ok.txt queue-auth-tampered.txt queue-auth-wrongns.txt report-*.json alert-*.json
ssh-keygen -q -t ecdsa -b 256 -N '' -C fixture -f key
ssh-keygen -q -t ecdsa -b 256 -N '' -C other -f other
printf 'hello watchdog' > msg.txt
ssh-keygen -Y sign -f key -n account-watchdog-note msg.txt
mv msg.txt.sig msg.sig

# Signed push notes (Mac -> Worker wire format). ts is fixed: 2100-01-01T00:00:00Z, far future so a pinned test clock stays ahead of real time and DO alarms are never clamped to "now".
printf '%s' '{"repo":"owner/name","ref":"refs/heads/main","old_sha":"1111111111111111111111111111111111111111","new_sha":"2222222222222222222222222222222222222222","ts":4102444800,"nonce":"0123456789abcdef0123456789abcdef"}' > note-payload.json
ssh-keygen -Y sign -f key -n account-watchdog-note note-payload.json
# Tampered: same signature, payload altered after signing (new_sha changed).
sed 's/2222222222222222222222222222222222222222/3333333333333333333333333333333333333333/' note-payload.json > note-tampered-payload.json
python3 - <<'PY'
import base64, json
sig = open("note-payload.json.sig").read()
for out, src in (("note-ok.json", "note-payload.json"), ("note-tampered.json", "note-tampered-payload.json")):
    body = {"payload": base64.b64encode(open(src, "rb").read()).decode(), "sig": sig}
    open(out, "w").write(json.dumps(body))
PY

# Queue auth header values: base64(JSON).base64(armored SSHSIG over exactly those JSON bytes).
# ts is fixed (same instant as the notes); tests pin the clock around it.
printf '%s' '{"ts":4102444800}' > queue-payload.json
ssh-keygen -Y sign -f key -n account-watchdog-queue queue-payload.json
# Wrong namespace: signed as a note, must not authenticate the queue.
cp queue-payload.json queue-wrongns-payload.json
ssh-keygen -Y sign -f key -n account-watchdog-note queue-wrongns-payload.json
python3 - <<'PY'
import base64
b = lambda x: base64.b64encode(x).decode()
rd = lambda f: open(f, "rb").read()
sig = rd("queue-payload.json.sig")
open("queue-auth-ok.txt", "w").write(b(rd("queue-payload.json")) + "." + b(sig))
# Tampered: valid signature, but the ts in the JSON was changed afterwards.
open("queue-auth-tampered.txt", "w").write(b(b'{"ts":4102444801}') + "." + b(sig))
open("queue-auth-wrongns.txt", "w").write(b(rd("queue-wrongns-payload.json")) + "." + b(rd("queue-wrongns-payload.json.sig")))
PY

# Signed restore reports (POST /report). Namespace account-watchdog-report; ts fixed like the notes.
python3 - <<'PY'
import json
B = {"ts": 4102444800, "nonce": "0123456789abcdef0123456789abcdef"}
def rep(restored, skipped, rt=None, st=None, totals=True):
    d = dict(B, restored=restored, skipped=skipped)
    if totals:
        d["restored_total"] = len(restored) if rt is None else rt
        d["skipped_total"] = len(skipped) if st is None else st
    return d
R = lambda ref, repo="owner/name": {"repo": repo, "ref": ref}
S = lambda reason, ref="refs/heads/main": {"repo": "owner/name", "ref": ref, "reason": reason}
cases = {
    "ok": rep([R("refs/heads/main")], [S("ref moved since the incident", "refs/heads/dev"), S("could not send note (worker returned 500)", "refs/heads/x")]),
    "badreason": rep([], [S("made up reason")]),
    "toomany": rep([R("refs/heads/b%d" % i) for i in range(51)], []),
    "escape": rep([R("refs/heads/<!channel>&x")], []),
    "partial": rep([R("refs/heads/b%d" % i) for i in range(50)], [S("push failed")], rt=80, st=1),
    "lowtotal": rep([R("refs/heads/a"), R("refs/heads/b")], [], rt=1),
    "nototals": rep([R("refs/heads/a")], [], totals=False),
    "nl": rep([], [S("push failed (a\nb)")]),
    "url": rep([], [S("push failed (http://x.test/?a=1&b=2)")]),
    "star": rep([], [S("push failed (a*b)")]),
    "junk": rep([], [S("no changeX")]),
    "trail": rep([], [S("push failed (ok) tail")]),
    "longdetail": rep([], [S("push failed (" + "a" * 101 + ")")]),
    "unverified": rep([], [S("restore target not verified — review manually")]),
}
# Max budget: grow until the request body is just under 7600 bytes.
import base64
n = 1
while True:
    d = rep([R("refs/heads/" + "r" * 150 + str(i)) for i in range(min(n, 50))], [S("push failed", "refs/heads/" + "s" * 150 + str(i)) for i in range(max(0, min(n - 50, 50)))])
    p = json.dumps(d, separators=(",", ":"))
    if 4 * ((len(p) + 2) // 3) + 700 > 7550 or n >= 100: break
    n += 1
cases["big"] = d
for k, v in cases.items():
    open("report-%s-payload.json" % k, "w").write(json.dumps(v, separators=(",", ":")))
PY
for f in report-*-payload.json; do
  n=${f#report-}; n=${n%-payload.json}
  ssh-keygen -Y sign -f key -n account-watchdog-report "$f"
done
# Wrong namespace: same payload as ok, signed as a note.
cp report-ok-payload.json report-wrongns-payload.json
ssh-keygen -Y sign -f key -n account-watchdog-note -q report-wrongns-payload.json
sed 's/owner\/name/owner\/evil/' report-ok-payload.json > report-tampered-payload.json
python3 - <<'PY'
import base64, glob, json
rd = lambda f: open(f, "rb").read()
def out(name, src, sigsrc):
    body = {"payload": base64.b64encode(rd(src)).decode(), "sig": rd(sigsrc).decode()}
    open("report-%s.json" % name, "w").write(json.dumps(body))
for f in glob.glob("report-*-payload.json"):
    n = f[len("report-"):-len("-payload.json")]
    if n != "tampered":
        out(n, f, f + ".sig")
out("tampered", "report-tampered-payload.json", "report-ok-payload.json.sig")
big = len(rd("report-big.json"))
assert 7000 < big <= 7600, big
PY

# Signed account alerts (POST /alert). Namespace account-watchdog-alert; same nonce as report-ok on purpose
# (the nonce store is shared across routes).
python3 - <<'PY'
import json
B = {"ts": 4102444800, "nonce": "0123456789abcdef0123456789abcdef"}
FP = "SHA256:" + "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789+/AbCdE"
assert len(FP) == 7 + 43
def K(**o):
    d = dict(B, kind="new-key", key_type="ssh-ed25519", fingerprint=FP, source="auth")
    d.update(o)
    return d
def M(**o):
    d = dict(B, kind="missed-webhook", refs=3, repos=2)
    d.update(o)
    return d
cases = {
    "newkey": K(),
    "newkey-signing": K(source="signing", nonce="fedcba9876543210fedcba9876543210"),
    "missed": M(),
    "badfp": K(fingerprint="SHA256:short"),
    "md5fp": K(fingerprint="MD5:00:11:22"),
    "badsource": K(source="ssh"),
    "badkind": K(kind="other"),
    "extra": K(note="hello"),
    "freetext": K(key_type="ssh-ed25519 <!channel>"),
    "missing": {k: v for k, v in K().items() if k != "source"},
    "refsstr": M(refs="3"),
    "refszero": M(refs=0),
    "reposfloat": M(repos=1.5),
    "missedextra": M(text="hi"),
    "missednonce": M(nonce="xyz"),
}
for k, v in cases.items():
    open("alert-%s-payload.json" % k, "w").write(json.dumps(v, separators=(",", ":")))
PY
for f in alert-*-payload.json; do
  ssh-keygen -q -Y sign -f key -n account-watchdog-alert "$f"
done
# Wrong namespace: same payload as newkey, signed as a report.
cp alert-newkey-payload.json alert-wrongns-payload.json
rm -f alert-wrongns-payload.json.sig
ssh-keygen -q -Y sign -f key -n account-watchdog-report alert-wrongns-payload.json
sed 's/ssh-ed25519/ssh-rsa/' alert-newkey-payload.json > alert-tampered-payload.json
python3 - <<'PY'
import base64, glob
rd = lambda f: open(f, "rb").read()
def out(name, src, sigsrc):
    body = {"payload": base64.b64encode(rd(src)).decode(), "sig": rd(sigsrc).decode()}
    import json
    open("alert-%s.json" % name, "w").write(json.dumps(body))
for f in glob.glob("alert-*-payload.json"):
    n = f[len("alert-"):-len("-payload.json")]
    if n != "tampered":
        out(n, f, f + ".sig")
out("tampered", "alert-tampered-payload.json", "alert-newkey-payload.json.sig")
PY
