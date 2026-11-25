#!/usr/bin/env bash
# bin/notify-test: one signed test alert (namespace gitzilla-alert, exactly {kind, ts, nonce}) to POST /alert.
. "$(dirname "$0")/helpers.sh"
make_test_key
export STUB_ALERT_STATUS_FILE="$T/alert.status" # read by the stub at start
start_stub
cat > "$GITZILLA_CONFIG_DIR/config" <<CFG
GITZILLA_URL=$STUB_URL
OWNER=alice
NOTE_PUBKEY_FILE=$T/key.pub
CFG
nt() { bash "$WD_ROOT/bin/notify-test" >"$T/out" 2>&1 </dev/null; echo $? > "$T/rc"; }
lines() { wc -l < "$STUB_LOG" | tr -d ' '; }

# success
nt
assert_eq 0 "$(cat "$T/rc")" "exit 0 on 204"
assert_contains "$(cat "$T/out")" "test alert sent" "says sent"
assert_eq 1 "$(lines)" "one request"
req="$(head -n1 "$STUB_LOG")"
assert_eq "POST" "$(echo "$req" | jq -r .method)" "method"
assert_eq "/alert" "$(echo "$req" | jq -r .path)" "path"
echo "$req" | jq -r .body | jq -r .payload | base64 -d > "$T/payload"
echo "$req" | jq -r .body | jq -r .sig > "$T/sig"
ssh-keygen -Y verify -f "$T/allowed_signers" -I test-owner -n gitzilla-alert -s "$T/sig" < "$T/payload" >/dev/null 2>&1
assert_eq 0 "$?" "signed in namespace gitzilla-alert"
ssh-keygen -Y verify -f "$T/allowed_signers" -I test-owner -n gitzilla-report -s "$T/sig" < "$T/payload" >/dev/null 2>&1
assert_eq 255 "$?" "not valid in another namespace"
assert_eq "kind,nonce,ts" "$(jq -r 'keys | join(",")' "$T/payload")" "payload is exactly {kind, ts, nonce}"
assert_eq test "$(jq -r .kind "$T/payload")" "kind test"
now="$(date +%s)"; ts="$(jq -r .ts "$T/payload")"
[ $((now - ts)) -ge 0 ] && [ $((now - ts)) -lt 60 ] && _ok || _bad "ts recent"
case "$(jq -r .nonce "$T/payload")" in ????????????????????????????????) _ok ;; *) _bad "nonce is 32 chars" ;; esac
case "$(jq -r .nonce "$T/payload")" in *[!0-9a-f]*) _bad "nonce hex" ;; *) _ok ;; esac
nt
n1="$(sed -n 1p "$STUB_LOG" | jq -r .body | jq -r .payload | base64 -d | jq -r .nonce)"
n2="$(sed -n 2p "$STUB_LOG" | jq -r .body | jq -r .payload | base64 -d | jq -r .nonce)"
[ "$n1" != "$n2" ] && _ok || _bad "fresh nonce per run"

# 401 from the Worker
echo 401 > "$T/alert.status"
nt
assert_eq 1 "$(cat "$T/rc")" "exit 1 on 401"
assert_contains "$(cat "$T/out")" "worker returned 401" "says why (401)"
case "$(cat "$T/out")" in *"test alert sent"*) _bad "401 must not say sent" ;; *) _ok ;; esac
rm -f "$T/alert.status"

# unreachable Worker
stop_stub
nt
assert_eq 1 "$(cat "$T/rc")" "exit 1 when unreachable"
assert_contains "$(cat "$T/out")" "worker unreachable" "says unreachable"

# not configured
GITZILLA_CONFIG_DIR="$T/empty" GITZILLA_SIGN_KEY="" bash "$WD_ROOT/bin/notify-test" >"$T/out" 2>&1 </dev/null; echo $? > "$T/rc"
assert_eq 1 "$(cat "$T/rc")" "exit 1 when not configured"
assert_contains "$(cat "$T/out")" "not configured" "says not configured"

# signing failure
start_stub
GITZILLA_SIGN_KEY="$T/no-such-key" nt
assert_eq 1 "$(cat "$T/rc")" "exit 1 when signing fails"
assert_contains "$(cat "$T/out")" "signing failed" "says signing failed"
assert_eq 0 "$(lines)" "nothing sent when signing fails"
finish
