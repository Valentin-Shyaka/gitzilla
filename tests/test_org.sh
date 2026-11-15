#!/usr/bin/env bash
# Organizations, Mac side: ./install.sh --join-org (stub org Worker) and bin/org admin commands (signing namespace,
# payloads, output, errors, refusal outside a profile). Note routing to org Workers is in test_note.sh.
. "$(dirname "$0")/helpers.sh"
unset GITZILLA_CURL
INSTALL="$WD_ROOT/install.sh"
ORG="$WD_ROOT/bin/org"
export STUB_ORG_DIR="$T/org" STUB_HEALTH_BODY_FILE="$T/health.json"
mkdir -p "$STUB_ORG_DIR"

mkkey() { # name -> $T/<name>(.pub), ecdsa-sha2-nistp256 like Secretive's
  rm -f "$T/$1" "$T/$1.pub"; ssh-keygen -q -t ecdsa -b 256 -N '' -C "$1" -f "$T/$1" >/dev/null
}
fp_of() { ssh-keygen -lf "$1" | awk '{print $2}'; }
mkkey member; mkkey admin
FP_M="$(fp_of "$T/member.pub")"
export GITZILLA_SIGN_KEY="$T/member"
start_stub
LOCAL_URL="http://localhost:$STUB_PORT" # the same stub under a second URL

write_personal() {
  cat > "$GITZILLA_CONFIG_DIR/config" <<CFG
OWNER=Alice
GITZILLA_URL=https://gitzilla.alice.workers.dev
NOTE_PUBKEY_FILE=$T/member.pub
CFG
}
health() { printf '%s' "$1" > "$STUB_HEALTH_BODY_FILE"; }
reqs() { grep -c "\"path\":\"$1\"" "$STUB_LOG" | tr -d ' '; }
cfg_orgs() { ( . "$GITZILLA_CONFIG_DIR/config"; printf '%s' "${ORG_WORKERS:-}" ); }
join() { # url [stdin text]
  printf "${2:-}" | bash "$INSTALL" --join-org "$1" >"$T/out" 2>&1; echo $? > "$T/rc"
}
out() { cat "$T/out"; }
rc() { cat "$T/rc"; }
# decode_last <path> -> $T/payload, $T/sig of the last request to path
decode_last() {
  grep "\"path\":\"$1\"" "$STUB_LOG" | tail -n1 | jq -r .body > "$T/body"
  jq -r .payload "$T/body" | base64 -d > "$T/payload"; jq -r .sig "$T/body" > "$T/sig"
}
verify() { # pubfile namespace -> 0 if $T/sig verifies over $T/payload
  echo "k $(cut -d' ' -f1,2 "$1")" > "$T/signers"
  ssh-keygen -Y verify -f "$T/signers" -I k -n "$2" -s "$T/sig" < "$T/payload" >/dev/null 2>&1
}

# --- join: happy path
write_personal
health '{"ok":true,"mode":"org","org":"Acme"}'
echo '{"ok":true,"fingerprint":"x"}' > "$STUB_ORG_DIR/enroll.body"
join "$STUB_URL/"
assert_eq 0 "$(rc)" "join: ok"
assert_eq 1 "$(reqs /enroll)" "join: one /enroll"
decode_last /enroll
assert_eq '["login","nonce","pubkey","ts"]' "$(jq -c 'keys' "$T/payload")" "join: payload is exactly {login,pubkey,ts,nonce}"
assert_eq alice "$(jq -r .login "$T/payload")" "join: login is the lower-cased OWNER"
assert_eq "$(cut -d' ' -f1,2 "$T/member.pub")" "$(jq -r .pubkey "$T/payload")" "join: pubkey is the push-note key (no comment)"
[[ "$(jq -r .nonce "$T/payload")" =~ ^[0-9a-f]{32}$ ]] && _ok || _bad "join: nonce is 32 hex"
assert_eq number "$(jq -r '.ts|type' "$T/payload")" "join: ts is a number"
verify "$T/member.pub" gitzilla-enroll; assert_eq 0 "$?" "join: signed by the push-note key in gitzilla-enroll"
verify "$T/member.pub" gitzilla-note && _bad "join: valid in another namespace" || _ok
assert_eq "acme=$STUB_URL" "$(cfg_orgs)" "join: ORG_WORKERS records org=url (trailing slash dropped, org lower-cased)"
assert_contains "$(out)" "Tell your gitzilla admin this fingerprint: $FP_M" "join: prints the fingerprint"
assert_contains "$(out)" "pending approval" "join: says 202 = pending"
assert_eq 600 "$(stat -f %Lp "$GITZILLA_CONFIG_DIR/config")" "join: config stays mode 600"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "GITZILLA_URL=https://gitzilla.alice.workers.dev" "join: rest of the config kept"

# --- rerun, same org and URL: re-posts /enroll only; 409 = already a member
cp "$GITZILLA_CONFIG_DIR/config" "$T/cfg.before"
echo 409 > "$STUB_ORG_DIR/enroll.status"; echo '{"error":"already a member"}' > "$STUB_ORG_DIR/enroll.body"
join "$STUB_URL"
assert_eq 0 "$(rc)" "rerun: ok"
assert_eq 2 "$(reqs /enroll)" "rerun: /enroll posted again"
assert_contains "$(out)" "already a member" "rerun: says 409 = member"
assert_contains "$(out)" "Tell your gitzilla admin this fingerprint: $FP_M" "rerun: prints the fingerprint"
assert_eq "" "$(diff "$T/cfg.before" "$GITZILLA_CONFIG_DIR/config")" "rerun: config unchanged"
rm -f "$STUB_ORG_DIR/enroll.status"; echo '{"ok":true}' > "$STUB_ORG_DIR/enroll.body"

# --- a different URL for a joined org: asks, default no
join "$LOCAL_URL"
assert_eq 1 "$(rc)" "new url: refused by default"
assert_contains "$(out)" "Replace it with $LOCAL_URL?" "new url: asks"
assert_eq 2 "$(reqs /enroll)" "new url: no /enroll without a yes"
assert_eq "" "$(diff "$T/cfg.before" "$GITZILLA_CONFIG_DIR/config")" "new url: config unchanged"
join "$LOCAL_URL" 'y\n'
assert_eq 0 "$(rc)" "new url: yes replaces"
assert_eq "acme=$LOCAL_URL" "$(cfg_orgs)" "new url: one entry, the new URL"

# --- a second org is appended
health '{"ok":true,"mode":"org","org":"beta-co"}'
join "$STUB_URL"
assert_eq 0 "$(rc)" "second org: ok"
assert_eq "acme=$LOCAL_URL beta-co=$STUB_URL" "$(cfg_orgs)" "second org: appended"
assert_eq 1 "$(grep -c '^ORG_WORKERS=' "$GITZILLA_CONFIG_DIR/config" | tr -d ' ')" "second org: one ORG_WORKERS line"

# --- refusals: nothing posted, config unchanged
cp "$GITZILLA_CONFIG_DIR/config" "$T/cfg.before"; n0="$(reqs /enroll)"
refused() { # msg needle
  assert_eq 1 "$(rc)" "$1: exit 1"
  assert_contains "$(out)" "$2" "$1: says why"
  assert_eq "$n0" "$(reqs /enroll)" "$1: no /enroll"
  assert_eq "" "$(diff "$T/cfg.before" "$GITZILLA_CONFIG_DIR/config")" "$1: config unchanged"
}
health '{"ok":true}'; join "$STUB_URL"; refused "personal worker" 'does not report mode "org"'
health '{"ok":true,"mode":"org","org":null}'; join "$STUB_URL"; refused "no org login" "does not name its organization"
health '{"ok":true,"mode":"org","org":"alice"}'; join "$STUB_URL"; refused "own account" "your own account"
health '{"ok":true,"mode":"org","org":"acme"}'
join "http://gitzilla.example.com"; refused "plain http" "https URL"
join "https://gz.example.com/x"; refused "url with a path" "https URL"
join "https://gz.example.com?x=1"; refused "url with a query" "https URL"
GITZILLA_PROFILE=org-acme join "$STUB_URL"; refused "in a profile" "personal profile only"
o="$(bash "$INSTALL" --join-org 2>&1)"; assert_eq 2 "$?" "no url: usage exit 2"; assert_contains "$o" "usage: install.sh --join-org" "no url: usage"
o="$(bash "$INSTALL" --join-org "$STUB_URL" --from-step hook 2>&1 </dev/null)"; assert_eq 2 "$?" "with --from-step: exit 2"
echo 429 > "$STUB_ORG_DIR/enroll.status"; echo '{"error":"rate limited"}' > "$STUB_ORG_DIR/enroll.body"
health '{"ok":true,"mode":"org","org":"gamma"}'; join "$STUB_URL"
assert_eq 1 "$(rc)" "enroll refused: exit 1"
assert_contains "$(out)" "refused the enrollment: rate limited (HTTP 429)" "enroll refused: prints the Worker's error"
assert_eq "" "$(diff "$T/cfg.before" "$GITZILLA_CONFIG_DIR/config")" "enroll refused: config unchanged"
rm -f "$STUB_ORG_DIR/enroll.status"; echo '{"ok":true}' > "$STUB_ORG_DIR/enroll.body"
n0="$(reqs /enroll)"
ssh-keygen -q -t ed25519 -N '' -f "$T/ed" >/dev/null
sed -i.bak "s#^NOTE_PUBKEY_FILE=.*#NOTE_PUBKEY_FILE=$T/ed.pub#" "$GITZILLA_CONFIG_DIR/config"; cp "$GITZILLA_CONFIG_DIR/config" "$T/cfg.before"
join "$STUB_URL"; refused "ed25519 key" "ecdsa-sha2-nistp256"
rm -f "$GITZILLA_CONFIG_DIR/config"; cp "$T/cfg.before" "$T/cfg.keep"; : > "$T/cfg.before"; touch "$GITZILLA_CONFIG_DIR/config"
join "$STUB_URL"; refused "no personal config" "no personal config"
cp "$T/cfg.keep" "$GITZILLA_CONFIG_DIR/config"
hit="$(grep -rl "$FP_M" "$HOME" "$GITZILLA_STATE_DIR" 2>/dev/null | grep -v '/log/')"
assert_eq "" "$hit" "join: nothing but the log mentions the fingerprint"

# --- bin/org
: > "$STUB_LOG"
o="$(bash "$ORG" list 2>&1)"; rc_=$?
assert_eq 2 "$rc_" "org outside a profile: exit 2"
assert_contains "$o" "GITZILLA_PROFILE=<org-profile>" "org outside a profile: says how"
assert_eq 0 "$(reqs /admin)" "org outside a profile: nothing sent"

OC="$T/orgcfg"; mkdir -p "$OC"
cat > "$OC/config" <<CFG
OWNER=acme
GITZILLA_URL=$STUB_URL
NOTE_PUBKEY_FILE=$T/admin.pub
CFG
org() { GITZILLA_PROFILE=org-acme GITZILLA_CONFIG_DIR="$OC" GITZILLA_STATE_DIR="$T/orgstate" GITZILLA_SIGN_KEY="$T/admin" \
          bash "$ORG" "$@" >"$T/out" 2>&1; echo $? > "$T/rc"; }
FPX="SHA256:$(printf 'A%.0s' $(seq 43))"
admin_payload() { decode_last /admin; jq -c '{cmd,args}' "$T/payload"; }

org approve Alice "$FP_M"
assert_eq 0 "$(rc)" "approve: ok"
assert_eq "{\"cmd\":\"approve\",\"args\":{\"login\":\"alice\",\"fingerprint\":\"$FP_M\"}}" "$(admin_payload)" "approve: payload"
assert_eq '["args","cmd","nonce","ts"]' "$(jq -c keys "$T/payload")" "approve: envelope is exactly {cmd,args,ts,nonce}"
[[ "$(jq -r .nonce "$T/payload")" =~ ^[0-9a-f]{32}$ ]] && _ok || _bad "approve: nonce is 32 hex"
verify "$T/admin.pub" gitzilla-admin; assert_eq 0 "$?" "approve: signed by the admin key in gitzilla-admin"
verify "$T/admin.pub" gitzilla-note && _bad "approve: valid as a note" || _ok
assert_contains "$(out)" "approved: alice" "approve: prints the result"
assert_eq 1 "$(reqs /admin)" "approve: one request"

org approve alice
assert_eq 2 "$(rc)" "approve without fingerprint: exit 2"
assert_contains "$(out)" "needs the key's fingerprint" "approve without fingerprint: says why"
org approve alice SHA256:short; assert_eq 2 "$(rc)" "approve with a bad fingerprint: exit 2"
org approve -bad "$FP_M"; assert_eq 2 "$(rc)" "approve with a bad login: exit 2"
org frobnicate; assert_eq 2 "$(rc)" "unknown command: exit 2"
org list extra; assert_eq 2 "$(rc)" "list with args: exit 2"
assert_eq 1 "$(reqs /admin)" "bad usage: nothing sent"

org revoke Alice
assert_eq 0 "$(rc)" "revoke login: ok"
assert_eq '{"cmd":"revoke","args":{"login":"alice"}}' "$(admin_payload)" "revoke login: payload"
assert_contains "$(out)" "pending requests" "revoke login: mentions pending requests"
org revoke alice "$FPX"
assert_eq "{\"cmd\":\"revoke\",\"args\":{\"login\":\"alice\",\"fingerprint\":\"$FPX\"}}" "$(admin_payload)" "revoke key: payload"
org allow-bot 'Dependabot[bot]'
assert_eq '{"cmd":"allow-bot","args":{"login":"dependabot[bot]"}}' "$(admin_payload)" "allow-bot: payload"
org disallow-bot renovate
assert_eq '{"cmd":"disallow-bot","args":{"login":"renovate"}}' "$(admin_payload)" "disallow-bot: payload"
org allow-bot 'x;rm'; assert_eq 2 "$(rc)" "allow-bot: bad name refused"

now="$(date +%s)"
jq -cn --arg a "$FP_M" --arg x "$FPX" --argjson t1 $((now - 7500)) --argjson t2 $((now - 3 * 86400 - 3600)) \
  '{members:[{login:"bob",fps:[$x]},{login:"alice",fps:[$a,$x]}],pending:[{login:"carol",fp:$a,ts:$t1},{login:"dave",fp:$x,ts:$t2}],bots:["dependabot[bot]"]}' \
  > "$STUB_ORG_DIR/admin.body"
org list
assert_eq 0 "$(rc)" "list: ok"
assert_eq '{"cmd":"list","args":{}}' "$(admin_payload)" "list: payload"
assert_contains "$(out)" "Members (2):" "list: member count"
assert_contains "$(out)" "$(printf '  %-39s  %s' alice "$FP_M")" "list: member row"
assert_contains "$(out)" "Pending enrollments (2)" "list: pending count"
assert_contains "$(out)" "$(printf '  %-39s  %-50s  %s' carol "$FP_M" '2h 5m')" "list: pending row with login, fingerprint, age"
assert_contains "$(out)" "$(printf '  %-39s  %-50s  %s' dave "$FPX" '3d 1h')" "list: pending age in days"
assert_contains "$(out)" "approve only a fingerprint the member gave you directly" "list: approval warning"
assert_contains "$(out)" "  dependabot[bot]" "list: bots"
echo '{"members":[],"pending":[],"bots":[]}' > "$STUB_ORG_DIR/admin.body"
org list
assert_eq 3 "$(grep -c '(none)' "$T/out" | tr -d ' ')" "list: empty sections say (none)"

echo 404 > "$STUB_ORG_DIR/admin.status"; echo '{"error":"no such pending enrollment"}' > "$STUB_ORG_DIR/admin.body"
org approve alice "$FP_M"
assert_eq 1 "$(rc)" "HTTP error: exit 1"
assert_contains "$(out)" "approve failed: no such pending enrollment (HTTP 404)" "HTTP error: prints the Worker's error"
echo 401 > "$STUB_ORG_DIR/admin.status"; echo '{"error":"bad signature"}' > "$STUB_ORG_DIR/admin.body"
org list
assert_eq 1 "$(rc)" "401: exit 1"; assert_contains "$(out)" "bad signature" "401: prints it"
echo 404 > "$STUB_ORG_DIR/admin.status"; echo 'not found' > "$STUB_ORG_DIR/admin.body"
org list
assert_eq 1 "$(rc)" "non-JSON error: exit 1"; assert_contains "$(out)" "HTTP 404" "non-JSON error: shows the status"
rm -f "$STUB_ORG_DIR/admin.status"
stop_stub
org list
assert_eq 1 "$(rc)" "unreachable: exit 1"; assert_contains "$(out)" "cannot reach" "unreachable: says so"
[ -e "$GITZILLA_STATE_DIR/log" ] && grep -q 'org:' "$GITZILLA_STATE_DIR/log/gitzilla.log" && _bad "org: wrote to the personal log" || _ok

finish
