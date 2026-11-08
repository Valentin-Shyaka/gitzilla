#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
STATE="$GITZILLA_STATE_DIR"
cat > "$GITZILLA_CONFIG_DIR/config" <<CFG
GITZILLA_URL=http://127.0.0.1:1
OWNER=Alice
CFG
NOW=1760000000
DAY=86400
OLDTOK=github_pat_OLDOLDOLDOLD1111
NEWTOK=github_pat_NEWNEWNEWNEW2222
NAME="github-auth-$(date -u -r $NOW +%F)"
SSHD="$HOME/.ssh"
SEC="$T/secretive"

# Every external command is a stub; nothing here can reach the real ~/.ssh, gh, clipboard, Secretive or Terminal.
export GITZILLA_NOW=$NOW GITZILLA_POLL_INTERVAL=0 GITZILLA_POLL_TIMEOUT=3 GITZILLA_SEED_RETRY_SLEEP=0
export GITZILLA_OPEN_CMD="$T/open.sh" GITZILLA_PBPASTE_CMD="$T/pbpaste.sh" GITZILLA_PBCOPY_CMD="$T/pbcopy.sh"
export GITZILLA_GH_CMD="$T/gh.sh" GITZILLA_CURL="$T/curl.sh" GITZILLA_DIALOG_CMD="$T/dialog.sh"
export GITZILLA_TERMINAL_CMD="$T/terminal.sh" GITZILLA_SECRETIVE_DIR="$SEC" GITZILLA_SSH_CMD="$T/ssh.sh"
export GITZILLA_SSH_ADD="$T/sshadd.sh" GITZILLA_NOTIFY_CMD="$T/notify.sh"
export GITZILLA_REMOTE_URL_TEMPLATE="$T/remote/%s.git"

printf '#!/bin/sh\necho "$*" >> "%s/open.log"\n[ -f "%s/lockswap.flag" ] && echo 99999999 > "%s/rotate.lock/pid"\nexit 0\n' "$T" "$T" "$STATE" > "$T/open.sh"
printf '#!/bin/sh\necho "$@" >> "%s/terminal.log"\n' "$T" > "$T/terminal.sh"
printf '#!/bin/sh\necho "$1|$2" >> "%s/notify.log"\n' "$T" > "$T/notify.sh"
printf '#!/bin/sh\necho "$*" >> "%s/pbcopy.log"\ntee -a "%s/clip.hist" > "%s/clip"\n' "$T" "$T" "$T" > "$T/pbcopy.sh"
printf '#!/bin/sh\necho "pbpaste $*" >> "%s/pbpaste.log"\ncat "%s/clip"\n' "$T" "$T" > "$T/pbpaste.sh"
printf '#!/bin/sh\necho "$1|$2" >> "%s/dialog.log"\ncat "%s/dialog.answer"\n' "$T" "$T" > "$T/dialog.sh"
cat > "$T/gh.sh" <<STUB
#!/bin/sh
echo "\$*" >> "$T/gh.log"
case "\$1 \$2" in
  "auth token") cat "$T/gh.token" ;;
  "auth login") tok="\$(cat)"; if [ -f "$T/gh.loginfail" ] && [ "\$tok" = "$NEWTOK" ]; then exit 1; fi; echo "\$tok" > "$T/gh.token" ;;
  "api user") if [ "\$(cat "$T/gh.token")" = "$NEWTOK" ]; then cat "$T/gh.newuser"; else echo Alice; fi ;;
  "repo list") cat "$T/gh.repos.json" ;;
esac
STUB
# curl stub: argv -> curl.log, stdin of the revoke POST -> curl.stdin; .keys served from keys.<n> (n-th call) or keys
cat > "$T/curl.sh" <<STUB
#!/bin/sh
out=""; url=""; stdin=0
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; --max-time|-w|-H|-X) shift ;; --data-binary) stdin=1; shift ;; -*) ;; *) url="\$1" ;; esac; shift; done
echo "\$url" >> "$T/curl.log"
case "\$url" in
  https://api.github.com/credentials/revoke) cat > "$T/curl.stdin"; printf '%s' "\${REVOKE_CODE:-202}"; exit 0 ;;
  https://github.com/alice.keys)
    n=\$(( \$(cat "$T/keys.n" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/keys.n"
    if [ -f "$T/kill.flag" ]; then [ -f "$T/rotate.pid" ] || sleep 1; kill -\$(cat "$T/kill.flag") \$(cat "$T/rotate.pid"); sleep 1; fi
    [ -f "$T/keys.fail" ] && { printf 500; exit 0; }
    f="$T/keys.\$n"; [ -f "\$f" ] || f="$T/keys"
    if [ -f "$T/keys.removed" ] && grep -q 'settings/keys\$' "$T/open.log" 2>/dev/null; then f="$T/keys.removed"; fi ;;
  "https://api.github.com/users/alice/ssh_signing_keys?per_page=100") f="$T/signing.json" ;;
  *) printf 404; exit 0 ;;
esac
cat >> "$T/curl.otherstdin"
[ -f "\$f" ] || { printf 404; exit 0; }
cp "\$f" "\$out"; printf 200
STUB
cat > "$T/sshadd.sh" <<STUB
#!/bin/sh
[ "\$1" = -L ] && { cat "$T/sshadd.L"; exit 0; }
echo "\$*|\$SSH_AUTH_SOCK" >> "$T/sshadd.log"
n=\$(( \$(cat "$T/sshadd.n" 2>/dev/null || echo 0) + 1 )); echo \$n > "$T/sshadd.n"
f="$T/sshadd.\$n"; [ -f "\$f" ] || f="$T/sshadd.out"
cat "\$f"; exit \$(cat "$T/sshadd.rc" 2>/dev/null || echo 0)
STUB
mk_ssh_stub() {
cat > "$T/ssh.sh" <<STUB
#!/bin/sh
echo "\$*" >> "$T/ssh.log"
if [ -f "$T/sshkill.flag" ]; then [ -f "$T/rotate.pid" ] || sleep 1; kill -\$(cat "$T/sshkill.flag") \$(cat "$T/rotate.pid"); sleep 1; fi
cat "$T/ssh.out"
exit 1
STUB
chmod +x "$T/ssh.sh"
}
mk_ssh_stub
mkdir -p "$T/bin"; REALJQ="$(command -v jq)"
cat > "$T/bin/jq" <<STUB
#!/bin/sh
if [ -f "$T/jqsig.flag" ]; then
  read -r pat sig < "$T/jqsig.flag"
  case "\$*" in *"\$pat"*) rm -f "$T/jqsig.flag"; kill -\$sig \$(cat "$T/rotate.pid") ;; esac
fi
exec "$REALJQ" "\$@"
STUB
chmod +x "$T/bin/jq"
export PATH="$T/bin:$PATH"
chmod +x "$T"/*.sh

ROTATE="$WD_ROOT/bin/rotate"
run() { bash "$ROTATE" "$@" >"$T/out" 2>&1 </dev/null; echo $? > "$T/rc"; }
runin() { local in="$1"; shift; printf "$in" | bash "$ROTATE" "$@" >"$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
rj() { jq -r "$1" "$STATE/rotation.json"; }
nmatch() { [ -f "$2" ] && { grep -c -- "$1" "$2" || true; } || echo 0; }
nlines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
reset() {
  rm -rf "$STATE" "$SSHD" "$SEC" "$T/remote" "$T/work"
  rm -f "$T"/*.log "$T"/*.n "$T"/keys "$T"/keys.* "$T"/jqsig.flag "$T"/lockswap.flag "$T"/clip "$T"/clip.hist "$T"/curl.stdin "$T"/gh.token "$T"/dialog.answer "$T"/kill.flag "$T"/sshkill.flag "$T"/gh.loginfail "$T"/curl.otherstdin "$T"/sshadd.L "$T"/rotate.pid "$T"/signing.json "$T"/sshadd.out "$T"/sshadd.[0-9]* "$T"/sshadd.rc
  mkdir -p "$STATE" "$SSHD" "$SEC" "$T/remote"; mk_ssh_stub
  echo Alice > "$T/gh.newuser"; echo "Hi alice! You've successfully authenticated, but GitHub does not provide shell access." > "$T/ssh.out"
  : > "$T/sshadd.out"; echo '[]' > "$T/signing.json"
}
setrot() { jq -cn "$1" > "$STATE/rotation.json"; }
# no token may sit in state, logs, rotation.json or any recorded argv
assert_no_tokens() {
  local f hit=""
  for f in $(find "$STATE" -type f) "$T/out" "$T/curl.otherstdin" "$T/open.log" "$T/gh.log" "$T/curl.log" "$T/pbcopy.log" "$T/pbpaste.log" "$T/notify.log" "$T/ssh.log"; do
    [ -f "$f" ] || continue
    grep -q -E "$OLDTOK|$NEWTOK|github_pat_[A-Za-z0-9_]{8,}" "$f" && hit="$hit $f"
  done
  assert_eq "" "$hit" "$1: no token in state, logs or argv"
}

# --- 1. check: prompts only when >= 5 days old and not snoozed
reset
echo "Snooze 1 day" > "$T/dialog.answer"
setrot '{gh:{last:('$NOW'-4*86400),step:null,snooze_until:0},ssh:{last:('$NOW'-3*86400),step:null,snooze_until:0}}'
run check
assert_eq 0 "$(rc)" "check fresh: exit 0"
assert_eq 0 "$(nlines "$T/dialog.log")" "check fresh (<5 d): no dialog"
setrot '{gh:{last:('$NOW'-5*86400),step:null,snooze_until:0},ssh:{last:('$NOW'-9*86400),step:null,snooze_until:'$((NOW+10))'}}'
run check
assert_eq 1 "$(nlines "$T/dialog.log")" "check: gh due (exactly 5 d), ssh snoozed -> one dialog"
assert_contains "$(cat "$T/dialog.log")" "gh" "check: dialog names gh"
assert_contains "$(cat "$T/dialog.log")" "Rotate now,Snooze 1 day" "check: buttons"
assert_eq $((NOW+DAY)) "$(rj .gh.snooze_until)" "check: Snooze 1 day -> snooze_until = now + 86400"
assert_eq $((NOW-5*DAY)) "$(rj .gh.last)" "check: snooze leaves last alone"
assert_eq $((NOW+10)) "$(rj .ssh.snooze_until)" "check: other flow untouched"
run check
assert_eq 0 "$(nlines "$T/terminal.log")" "check: nothing launched when snoozed"
assert_eq 1 "$(nlines "$T/dialog.log")" "check: snoozed gh not asked again"
# missing rotation.json: both due
reset
echo "Snooze 1 day" > "$T/dialog.answer"
run check
assert_eq 2 "$(nlines "$T/dialog.log")" "check: never rotated -> both asked"
# snooze elapsed -> asked again
setrot '{gh:{last:0,step:null,snooze_until:'$NOW'},ssh:{last:'$NOW',step:null,snooze_until:0}}'
rm -f "$T/dialog.log"; run check
assert_eq 1 "$(nlines "$T/dialog.log")" "check: snooze_until reached -> asked"

# --- 2. check: Rotate now opens Terminal running the flow; timeout takes no action
reset
echo "Rotate now" > "$T/dialog.answer"
setrot '{gh:{last:0,step:null,snooze_until:0},ssh:{last:'$NOW',step:null,snooze_until:0}}'
run check
assert_eq "$ROTATE gh" "$(cat "$T/terminal.log")" "check: Rotate now launches '<rotate> gh' in Terminal"
assert_eq 0 "$(rj .gh.last)" "check: launch does not change last"
reset
echo TIMEOUT > "$T/dialog.answer"
setrot '{gh:{last:0,step:null,snooze_until:0},ssh:{last:'$NOW',step:null,snooze_until:0}}'
cp "$STATE/rotation.json" "$T/rot.before"
run check
assert_eq 0 "$(rc)" "check timeout: exit 0"
assert_eq 0 "$(nlines "$T/terminal.log")" "check timeout: no Terminal"
assert_eq "$(cat "$T/rot.before")" "$(cat "$STATE/rotation.json")" "check timeout: rotation.json unchanged"
echo "garbage" > "$T/dialog.answer"
run check
assert_eq 0 "$(nlines "$T/terminal.log")" "check unknown answer: no action"

# --- 3. gh flow: happy path
# fake remotes for the repos refresh
mkrepo() { # slug (lowercase owner/name)
  local d="$T/remote/$1.git" w="$T/work/$1"
  mkdir -p "$(dirname "$d")" "$w"; git init -q --bare "$d"; git init -q "$w"
  git -C "$w" commit -q --allow-empty -m one; git -C "$w" branch -M main; git -C "$w" push -q "$d" main 2>/dev/null
}
reset
mkrepo alice/foo; mkrepo alice/bar
cat > "$T/gh.repos.json" <<JSON
[{"nameWithOwner":"Alice/Foo","visibility":"PUBLIC"},{"nameWithOwner":"Alice/Bar","visibility":"PRIVATE"},{"nameWithOwner":"Other/Thing","visibility":"PUBLIC"}]
JSON
# bar already has a stale mirror: the refresh must fetch --prune it before seeding
git clone -q --mirror "$T/remote/alice/bar.git" "$STATE/mirrors/alice__bar.git" 2>/dev/null || { mkdir -p "$STATE/mirrors"; git clone -q --mirror "$T/remote/alice/bar.git" "$STATE/mirrors/alice__bar.git"; }
git -C "$T/work/alice/bar" commit -q --allow-empty -m two; git -C "$T/work/alice/bar" push -q "$T/remote/alice/bar.git" main
git -C "$T/work/alice/bar" push -q "$T/remote/alice/bar.git" main:gone
git -C "$STATE/mirrors/alice__bar.git" fetch -q; git -C "$T/work/alice/bar" push -q "$T/remote/alice/bar.git" :gone
BAR2="$(git -C "$T/work/alice/bar" rev-parse HEAD)"
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
setrot '{gh:{last:0,step:null,snooze_until:0},ssh:{last:'$NOW',step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 0 "$(rc)" "gh: exit 0 ($(cat "$T/out" | tail -3))"
assert_eq "https://github.com/settings/personal-access-tokens/new" "$(sed -n 1p "$T/open.log")" "gh: opens the new-token page first"
for want in "Fine-grained personal access token" "7 days" "Contents: read" "Metadata: read" "Pull requests: read and write" "Issues: read and write" "All repositories"; do
  assert_contains "$(cat "$T/out")" "$want" "gh: prints setting '$want'"
done
assert_eq "$NEWTOK" "$(cat "$T/gh.token")" "gh: gh now holds the new token"
assert_eq "" "$(cat "$T/clip")" "gh: clipboard cleared after reading"
assert_contains "$(cat "$T/curl.log")" "https://api.github.com/credentials/revoke" "gh: revoke endpoint called"
assert_eq "{\"credentials\":[\"$OLDTOK\"]}" "$(cat "$T/curl.stdin")" "gh: curl saw the old token on stdin"
assert_eq $NOW "$(rj .gh.last)" "gh: last set"
assert_eq "null" "$(rj .gh.step)" "gh: step null when done"
assert_eq $NOW "$(rj .ssh.last)" "gh: ssh entry untouched"
assert_eq "alice/bar private
alice/foo public" "$(sort "$STATE/repos.txt")" "gh: repos.txt is the owner's repos, lowercase, public|private"
assert_eq "alice/bar
alice/foo" "$(sort "$STATE/seeded.txt")" "gh: both repos seeded"
assert_eq "$BAR2" "$(jq -r '.["alice/bar"]["refs/heads/main"]' "$STATE/heads.json")" "gh: stale mirror fetched before seeding"
assert_eq "null" "$(jq -r '.["alice/bar"]["refs/heads/gone"]' "$STATE/heads.json")" "gh: pruned ref not seeded"
assert_eq "yes" "$([ -d "$STATE/mirrors/alice__foo.git" ] && echo yes || echo no)" "gh: missing mirror cloned"
assert_eq "0 never always" "$(git -C "$STATE/mirrors/alice__foo.git" config gc.auto) $(git -C "$STATE/mirrors/alice__foo.git" config gc.pruneExpire) $(git -C "$STATE/mirrors/alice__foo.git" config core.logAllRefUpdates)" "I3 gh: cloned mirror never auto-gcs, never prunes, logs ref updates"
assert_eq 0 "$(nlines "$T/notify.log")" "gh: no notification when all seeded"
assert_no_tokens "gh happy path"
assert_eq "" "$(grep -l "github_pat_" "$STATE/rotation.json" || true)" "gh: rotation.json clean"

# --- 4. gh: clipboard is not a token -> stop at read-token, no login, no revoke
reset
echo "$OLDTOK" > "$T/gh.token"; echo "hello world" > "$T/clip"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 1 "$(rc)" "gh bad clipboard: exit 1"
assert_eq "$OLDTOK" "$(cat "$T/gh.token")" "gh bad clipboard: old login kept"
assert_eq 0 "$(nmatch 'auth login' "$T/gh.log")" "gh bad clipboard: no login call"
assert_eq 0 "$(nlines "$T/curl.log")" "gh bad clipboard: nothing revoked"
assert_eq "open-page" "$(rj .gh.step)" "gh bad clipboard: stopped before read-token completed"
assert_eq 0 "$(rj .gh.last)" "gh bad clipboard: last unchanged"
# rerun with a good clipboard resumes at read-token (page not reopened)
echo "$NEWTOK" > "$T/clip"; : > "$T/open.log"
echo '[]' > "$T/gh.repos.json"
runin '\ny\n' gh
assert_eq 0 "$(rc)" "gh rerun: exit 0"
assert_contains "$(cat "$T/out")" "resumed an earlier one" "gh rerun: resumed run forces manual confirm even though the API said 202"
assert_contains "$(cat "$T/out")" "created before today" "gh rerun: says which token to delete"
assert_eq 0 "$(nmatch 'personal-access-tokens/new' "$T/open.log")" "gh rerun: resumes at read-token (no page reopen)"
assert_eq $NOW "$(rj .gh.last)" "gh rerun: completes"
assert_no_tokens "gh rerun"

# --- 5. gh: new token belongs to someone else -> old token restored
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"; echo mallory > "$T/gh.newuser"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 1 "$(rc)" "gh mismatch: exit 1"
assert_eq "$OLDTOK" "$(cat "$T/gh.token")" "gh mismatch: old token restored"
assert_eq 0 "$(nlines "$T/curl.log")" "gh mismatch: nothing revoked"
assert_eq 0 "$(rj .gh.last)" "gh mismatch: last unchanged"
assert_contains "$(cat "$T/out")" "mallory" "gh mismatch: says which account"
assert_no_tokens "gh mismatch"

# --- 6. gh: resume at revoke-old without the old token -> manual deletion
reset
echo "$NEWTOK" > "$T/gh.token"; echo '[]' > "$T/gh.repos.json"
setrot '{gh:{last:0,step:"login",snooze_until:0}}'
runin 'y\n' gh
assert_eq 0 "$(rc)" "gh resume: exit 0"
assert_eq 0 "$(nlines "$T/curl.log")" "gh resume: no revoke call without the old token"
assert_eq "https://github.com/settings/personal-access-tokens" "$(cat "$T/open.log")" "gh resume: opens tokens page"
assert_eq $NOW "$(rj .gh.last)" "gh resume: done after owner confirms"
assert_eq 0 "$(nmatch 'auth login' "$T/gh.log")" "gh resume: no new login"
setrot '{gh:{last:0,step:"login",snooze_until:0}}'
runin 'n\n' gh
assert_eq 1 "$(rc)" "gh resume: N -> stop"
assert_eq "login" "$(rj .gh.step)" "gh resume: N keeps the step"
assert_eq 0 "$(rj .gh.last)" "gh resume: N leaves last"
# revoke endpoint refusing -> manual fallback too
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"; echo '[]' > "$T/gh.repos.json"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
REVOKE_CODE=500 runin '\ny\n' gh
assert_eq 0 "$(rc)" "gh revoke 500: manual fallback completes"
assert_contains "$(cat "$T/open.log")" "settings/personal-access-tokens" "gh revoke 500: opens tokens page"
assert_no_tokens "gh revoke 500"

# --- 7. gh: seed retry and "not yet seeded" notification; never fails the rotation
reset
mkrepo alice/foo
echo '[{"nameWithOwner":"Alice/Foo","visibility":"PUBLIC"}]' > "$T/gh.repos.json"
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
mkdir -p "$STATE/poll.lock"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 0 "$(rc)" "seed busy: rotation still succeeds"
assert_eq $NOW "$(rj .gh.last)" "seed busy: last set"
assert_contains "$(cat "$T/notify.log")" "1 repos not yet seeded — run reconcile seed" "seed busy: notifies after retries"
# lock released mid-retries -> a retry seeds it
reset
mkrepo alice/foo
echo '[{"nameWithOwner":"Alice/Foo","visibility":"PUBLIC"}]' > "$T/gh.repos.json"
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
mkdir -p "$STATE/poll.lock"; ( sleep 2; rmdir "$STATE/poll.lock" ) &
setrot '{gh:{last:0,step:null,snooze_until:0}}'
GITZILLA_SEED_RETRY_SLEEP=1 runin '\n' gh
wait
assert_eq "alice/foo" "$(cat "$STATE/seeded.txt")" "seed retry: seeded on a later attempt"
assert_eq 0 "$(nlines "$T/notify.log")" "seed retry: no notification"


# --- 7b. gh: the clipboard holds the token gh already uses -> refuse before logging in
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$OLDTOK" > "$T/clip"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 1 "$(rc)" "gh same token: exit 1"
assert_contains "$(cat "$T/out")" "that is the current token; create a new one" "gh same token: message"
assert_eq 0 "$(nmatch 'auth login' "$T/gh.log")" "gh same token: no login"
assert_eq 0 "$(nlines "$T/curl.log")" "gh same token: nothing revoked"
assert_eq 0 "$(rj .gh.last)" "gh same token: last unchanged"

# --- 7c. gh: `gh auth login` fails for the new token -> old login restored
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"; touch "$T/gh.loginfail"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 1 "$(rc)" "gh login fail: exit 1"
assert_eq "$OLDTOK" "$(cat "$T/gh.token")" "gh login fail: old token still in use"
assert_eq 0 "$(nlines "$T/curl.log")" "gh login fail: nothing revoked"
assert_eq 0 "$(rj .gh.last)" "gh login fail: last unchanged"
assert_no_tokens "gh login fail"

# --- 7d. gh: empty repo list is refused; repos that vanished from the list are kept
reset
printf 'alice/foo public\nalice/gone private\n' > "$STATE/repos.txt"
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"; echo '[]' > "$T/gh.repos.json"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 0 "$(rc)" "gh empty list: rotation itself succeeds"
assert_eq "alice/foo public
alice/gone private" "$(cat "$STATE/repos.txt")" "gh empty list: repos.txt kept"
assert_contains "$(cat "$T/notify.log")" "returned no repos" "gh empty list: notified"
reset
mkrepo alice/foo
printf 'alice/foo public\nalice/gone private\n' > "$STATE/repos.txt"
echo '[{"nameWithOwner":"Alice/Foo","visibility":"PUBLIC"}]' > "$T/gh.repos.json"
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq "alice/foo public
alice/gone private" "$(cat "$STATE/repos.txt")" "gh partial list: vanished repo kept (union)"
assert_contains "$(cat "$T/notify.log")" "1 repos disappeared from gh repo list — check the token's repository access" "gh partial list: notified"
assert_eq $NOW "$(rj .gh.last)" "gh partial list: rotation done"

# --- 7e. gh: a repo that is already seeded but has no mirror still gets one
reset
mkrepo alice/foo
echo 'alice/foo public' > "$STATE/repos.txt"; echo 'alice/foo' > "$STATE/seeded.txt"
echo '[{"nameWithOwner":"Alice/Foo","visibility":"PUBLIC"}]' > "$T/gh.repos.json"
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq "yes" "$([ -d "$STATE/mirrors/alice__foo.git" ] && echo yes || echo no)" "gh seeded-without-mirror: mirror cloned"

# --- 7f. one flow at a time
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
mkdir -p "$STATE/rotate.lock"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
runin '\n' gh
assert_eq 1 "$(rc)" "lock busy: exit 1"
assert_contains "$(cat "$T/out")" "another rotation is" "lock busy: message"
assert_eq "yes" "$([ -d "$STATE/rotate.lock" ] && echo yes || echo no)" "lock busy: foreign lock left alone"
touch -t 202001010000 "$STATE/rotate.lock"
echo '[]' > "$T/gh.repos.json"
runin '\n' gh
assert_eq 0 "$(rc)" "lock stale: taken over"
assert_eq "no" "$([ -d "$STATE/rotate.lock" ] && echo yes || echo no)" "lock released at exit"

# --- ssh helpers
mkkey() { rm -f "$1" "$1.pub"; ssh-keygen -q -t ed25519 -N '' -C "$2" -f "$1" >/dev/null </dev/null; }
blobof() { cut -d' ' -f2 "$1"; }
ssh_setup() { # old auth key in ~/.ssh, a decoy + old key in known-keys, new key in Secretive
  reset
  mkkey "$T/oldk" oldkey; mkkey "$T/newk" "$NAME"; mkkey "$T/other" other; mkkey "$T/sign" signing
  cp "$T/oldk.pub" "$SSHD/github-auth.pub"; cp "$T/sign.pub" "$SSHD/git-signing.pub"
  cp "$T/newk.pub" "$SEC/abc123.pub"; cp "$T/other.pub" "$SEC/def456.pub"
  OLDB="$(blobof "$T/oldk.pub")"; NEWB="$(blobof "$T/newk.pub")"; OTHERB="$(blobof "$T/other.pub")"
  cp "$T/oldk.pub" "$STATE/known-keys.txt"; cat "$T/other.pub" >> "$STATE/known-keys.txt"
  setrot '{ssh:{last:0,step:null,snooze_until:0}}'
  printf 'ssh-ed25519 %s\nssh-ed25519 %s\nssh-ed25519 %s\n' "$OLDB" "$OTHERB" "$NEWB" > "$T/keys"
  printf 'ssh-ed25519 %s\nssh-ed25519 %s\n' "$OTHERB" "$NEWB" > "$T/keys.removed"
  cat "$T/oldk.pub" "$T/newk.pub" > "$T/sshadd.L"
  FP="$(ssh-keygen -lf "$T/oldk.pub" | awk '{print $2}')"
  echo "256 $FP oldkey (ED25519)" > "$T/sshadd.1"; echo "256 SHA256:someotherkey x (ED25519)" > "$T/sshadd.2"
  SIGN_BEFORE="$(cat "$SSHD/git-signing.pub")"
}
# run ssh in the background with its own signal disposition; the stubs deliver <SIG> to it
run_sig() { # kill.flag-or-sshkill.flag SIG
  echo "$2" > "$T/$1"; rm -f "$T/rotate.pid"
  ( printf '\n\n' | perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' bash "$ROTATE" ssh >"$T/out" 2>&1 & echo $! > "$T/rotate.pid"; wait $!; echo $? > "$T/rc" ) >/dev/null 2>&1
  rm -f "$T/$1" "$T/keys.n"
}

# --- 8. ssh: full flow
ssh_setup
printf '%s' "$(cat "$STATE/known-keys.txt")" > "$STATE/known-keys.txt"   # no trailing newline (I6)
runin '\n\n' ssh
assert_eq 0 "$(rc)" "ssh: exit 0 ($(tail -3 "$T/out" | tr '\n' ' '))"
assert_eq "$NEWB" "$(blobof "$SSHD/github-auth.pub")" "ssh: github-auth.pub is the new key"
assert_eq "no" "$([ -e "$SSHD/github-auth.prev.pub" ] && echo yes || echo no)" "ssh: .prev removed at done"
assert_eq "$SIGN_BEFORE" "$(cat "$SSHD/git-signing.pub")" "ssh: signing key untouched"
assert_eq "ssh-ed25519 $OTHERB
ssh-ed25519 $NEWB" "$(awk '{print $1" "$2}' "$STATE/known-keys.txt")" "ssh: known-keys: old removed, new appended on its own line, others kept"
assert_eq 2 "$(nlines "$STATE/known-keys.txt")" "ssh: known-keys lines not glued together"
assert_eq "$(cat "$SEC/abc123.pub")" "$(cat "$T/clip.hist")" "ssh: the Secretive public key was copied to the clipboard"
assert_eq "" "$(cat "$T/clip")" "ssh: clipboard cleared once the key is on GitHub"
assert_eq "https://github.com/settings/ssh/new
https://github.com/settings/keys" "$(cat "$T/open.log")" "ssh: add page, then keys page"
assert_contains "$(cat "$T/out")" "Authentication Key" "ssh: reminds Authentication Key"
assert_contains "$(cat "$T/out")" "keep:   $(ssh-keygen -lf "$T/newk.pub" | awk '{print $2}')" "ssh: remove-old shows the fingerprint to keep"
assert_contains "$(cat "$T/out")" "delete: $FP" "ssh: remove-old shows the fingerprint to delete"
assert_contains "$(cat "$T/ssh.log")" "-o ControlMaster=no -o ControlPath=none -T git@github.com" "ssh: test without a shared connection"
assert_eq 2 "$(nlines "$T/ssh.log")" "ssh: test before and again before cleanup"
assert_contains "$(cat "$T/sshadd.log")" "-l|$SECRETIVE_SOCK" "ssh: ssh-add -l on the Secretive socket"
assert_eq 2 "$(nlines "$T/sshadd.log")" "ssh: waited for the owner between cleanup checks"
assert_eq $NOW "$(rj .ssh.last)" "ssh: last set"
assert_eq "null" "$(rj .ssh.step)" "ssh: step null when done"
assert_eq "yes" "$([ -f "$SEC/abc123.pub" ] && [ -f "$SEC/def456.pub" ] && echo yes || echo no)" "ssh: never deletes Secretive files"
assert_no_tokens "ssh happy path"

# --- 9. ssh: signals during the add poll leave the old key in place
for sig in HUP INT; do
  ssh_setup
  run_sig kill.flag $sig
  assert_eq 130 "$(rc)" "ssh $sig in add: exit 130"
  assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh $sig in add: github-auth.pub unchanged (old key)"
  assert_eq 0 "$(grep -c "$NEWB" "$STATE/known-keys.txt")" "ssh $sig in add: new blob removed from known-keys"
  assert_eq 1 "$(grep -c "$OLDB" "$STATE/known-keys.txt")" "ssh $sig in add: old blob still known"
  assert_eq 0 "$(rj .ssh.last)" "ssh $sig in add: last unchanged"
done

# --- 9b. ssh: SIGINT during the test (after the swap) restores the old key
ssh_setup
run_sig sshkill.flag INT
assert_eq 130 "$(rc)" "ssh INT in test: exit 130"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh INT in test: old key restored"
assert_eq 0 "$(grep -c "$NEWB" "$STATE/known-keys.txt")" "ssh INT in test: new blob removed from known-keys"
assert_eq "add" "$(rj .ssh.step)" "ssh INT in test: step add (rerun re-exports and re-tests)"
# rerun is safe: it goes to export, not back to create
: > "$T/open.log"; rm -f "$T/keys.n" "$T/sshadd.n" "$T/sshadd.log" "$T/ssh.log"
runin '\n\n' ssh
assert_eq 0 "$(rc)" "ssh INT in test rerun: exit 0 ($(tail -3 "$T/out" | tr '\n' ' '))"
assert_eq "$NEWB" "$(blobof "$SSHD/github-auth.pub")" "ssh INT in test rerun: new key in place"
assert_eq 1 "$(grep -c "$NEWB" "$STATE/known-keys.txt")" "ssh INT in test rerun: new blob known exactly once"

# --- 9c. ssh: resume add -> export, and test -> remove-old
ssh_setup
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub"}}'
runin '\n\n' ssh
assert_eq 0 "$(rc)" "ssh resume at export: exit 0 ($(tail -3 "$T/out" | tr '\n' ' '))"
assert_eq 0 "$(nmatch settings/ssh/new "$T/open.log")" "ssh resume at export: no add page, no Secretive create"
assert_eq "$NEWB" "$(blobof "$SSHD/github-auth.pub")" "ssh resume at export: swapped"
assert_eq $NOW "$(rj .ssh.last)" "ssh resume at export: completes"
ssh_setup
cp "$T/newk.pub" "$SSHD/github-auth.pub"; cp "$T/oldk.pub" "$SSHD/github-auth.prev.pub"
setrot '{ssh:{last:0,step:"test",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub",old_blob:"'$OLDB'"}}'
runin '\n\n' ssh
assert_eq 0 "$(rc)" "ssh resume at remove-old: exit 0 ($(tail -3 "$T/out" | tr '\n' ' '))"
assert_eq "https://github.com/settings/keys" "$(cat "$T/open.log")" "ssh resume at remove-old: starts at remove-old"
assert_eq $NOW "$(rj .ssh.last)" "ssh resume at remove-old: completes"

# --- 10. ssh: new key never appears on .keys -> old key never touched
ssh_setup
printf 'ssh-ed25519 %s\nssh-ed25519 %s\n' "$OLDB" "$OTHERB" > "$T/keys"
run ssh
assert_eq 1 "$(rc)" "ssh timeout: exit 1"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh timeout: github-auth.pub never changed"
assert_eq "no" "$([ -e "$SSHD/github-auth.prev.pub" ] && echo yes || echo no)" "ssh timeout: no .prev created"
assert_eq 0 "$(grep -c "$NEWB" "$STATE/known-keys.txt")" "ssh timeout: new blob removed from known-keys"
assert_eq 1 "$(grep -c "$OLDB" "$STATE/known-keys.txt")" "ssh timeout: old blob still known"
assert_eq "null" "$(rj .ssh.step)" "ssh timeout: step null"
assert_eq 0 "$(rj .ssh.last)" "ssh timeout: last unchanged"
assert_contains "$(cat "$T/out")" "delete it there" "ssh timeout: tells the owner to delete a key they may have added"
case "$(cat "$T/out")" in *"added as a Signing Key?"*) _bad "ssh timeout: wrong signing-key message" ;; *) _ok ;; esac

# --- 11. ssh: added as signing key only
ssh_setup
printf 'ssh-ed25519 %s\nssh-ed25519 %s\n' "$OLDB" "$OTHERB" > "$T/keys"
printf '[{"id":1,"key":"ssh-ed25519 %s","title":"x"}]\n' "$NEWB" > "$T/signing.json"
run ssh
assert_eq 1 "$(rc)" "ssh signing-only: exit 1"
assert_contains "$(cat "$T/out")" "added as a Signing Key? Add it as an Authentication Key" "ssh signing-only: message"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh signing-only: old key kept"
assert_eq 0 "$(grep -c "$NEWB" "$STATE/known-keys.txt")" "ssh signing-only: new blob removed from known-keys"

# --- 12. ssh: test fails after the swap -> old key restored, even with a stale .prev
ssh_setup
cp "$T/other.pub" "$SSHD/github-auth.prev.pub"     # stale leftover from an earlier run
echo "git@github.com: Permission denied (publickey)." > "$T/ssh.out"
run ssh
assert_eq 1 "$(rc)" "ssh test fail: exit 1"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh test fail: the real old key is back (not the stale .prev)"
assert_eq 0 "$(grep -c "$NEWB" "$STATE/known-keys.txt")" "ssh test fail: new blob removed from known-keys"
assert_eq "add" "$(rj .ssh.step)" "ssh test fail: step add"
assert_eq 0 "$(rj .ssh.last)" "ssh test fail: last unchanged"
assert_contains "$(cat "$T/out")" "delete it there" "ssh test fail: tells the owner how to abandon the key"
# a test that authenticates as someone else does not count
ssh_setup
echo "Hi mallory! You've successfully authenticated, but GitHub does not provide shell access." > "$T/ssh.out"
run ssh
assert_eq 1 "$(rc)" "ssh test wrong user: exit 1"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh test wrong user: old key restored"

# --- 13. ssh: old key never leaves .keys -> stop
ssh_setup
rm -f "$T/keys.removed"
run ssh
assert_eq 1 "$(rc)" "ssh remove-old timeout: exit 1"
assert_eq "test" "$(rj .ssh.step)" "ssh remove-old timeout: step stays test"
assert_eq "$NEWB" "$(blobof "$SSHD/github-auth.pub")" "ssh remove-old timeout: new key kept"

# --- 13b. ssh: owner deleted BOTH keys -> stop, never reaches cleanup
ssh_setup
printf 'ssh-ed25519 %s\n' "$OTHERB" > "$T/keys.removed"
run ssh
assert_eq 1 "$(rc)" "ssh both deleted: exit 1"
assert_contains "$(cat "$T/out")" "Both keys are gone" "ssh both deleted: says so"
assert_eq 0 "$(nlines "$T/sshadd.log")" "ssh both deleted: cleanup never reached"
assert_eq 0 "$(rj .ssh.last)" "ssh both deleted: last not set"
assert_eq "test" "$(rj .ssh.step)" "ssh both deleted: step stays test"

# --- 13c. ssh: new key stops authenticating before cleanup -> stop
ssh_setup
printf '#!/bin/sh\necho "$*" >> "%s/ssh.log"\nif [ "$(wc -l < "%s/ssh.log" | tr -d " ")" -ge 2 ]; then echo "Permission denied (publickey)."; else cat "%s/ssh.out"; fi\nexit 1\n' "$T" "$T" "$T" > "$T/ssh.sh"
run ssh
assert_eq 1 "$(rc)" "ssh retest: exit 1"
assert_eq 0 "$(nlines "$T/sshadd.log")" "ssh retest: cleanup never reached"
assert_eq 0 "$(rj .ssh.last)" "ssh retest: last not set"
assert_eq "$NEWB" "$(blobof "$SSHD/github-auth.pub")" "ssh retest: nothing rolled back"

# --- 14. ssh: secretive cleanup waits while the old key is still loaded; no input -> stops
ssh_setup
echo "256 $FP oldkey (ED25519)" > "$T/sshadd.out"; rm -f "$T/sshadd.1" "$T/sshadd.2"
runin '\n' ssh
assert_eq 1 "$(rc)" "ssh cleanup pending: stops at EOF"
assert_eq "remove-old" "$(rj .ssh.step)" "ssh cleanup pending: step remove-old"
assert_eq 0 "$(rj .ssh.last)" "ssh cleanup pending: last unchanged"
assert_eq "yes" "$(grep -q "$OLDB" "$STATE/known-keys.txt" && echo yes || echo no)" "ssh cleanup pending: old blob still in known-keys"
assert_eq "yes" "$([ -e "$SSHD/github-auth.prev.pub" ] && echo yes || echo no)" "ssh cleanup pending: .prev kept until done"

# --- 15. missing known-keys.txt is not created
ssh_setup
rm -f "$STATE/known-keys.txt"
runin '\n\n' ssh
assert_eq 0 "$(rc)" "ssh no known-keys: exit 0"
assert_eq "no" "$([ -e "$STATE/known-keys.txt" ] && echo yes || echo no)" "ssh no known-keys: file not created"

# --- 15b. create refuses: the current key, several matching keys, a key the agent does not have
ssh_setup
cp "$T/oldk.pub" "$SEC/abc123.pub"; sed -i.bak "s/oldkey\$/$NAME/" "$SEC/abc123.pub"; rm -f "$SEC/abc123.pub.bak"
run ssh
assert_eq 1 "$(rc)" "ssh create current key: exit 1"
assert_contains "$(cat "$T/out")" "already in use" "ssh create current key: message"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh create current key: nothing changed"
ssh_setup
cp "$T/other.pub" "$SEC/ghi789.pub"; sed -i.bak "s/other\$/$NAME-b/" "$SEC/ghi789.pub"; rm -f "$SEC/ghi789.pub.bak"
run ssh
assert_eq 1 "$(rc)" "ssh create two matches: exit 1"
assert_contains "$(cat "$T/out")" "keep exactly one" "ssh create two matches: message"
ssh_setup
cat "$T/oldk.pub" > "$T/sshadd.L"
run ssh
assert_eq 1 "$(rc)" "ssh create not in agent: exit 1"
assert_contains "$(cat "$T/out")" "not loaded in the Secretive agent" "ssh create not in agent: message"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "ssh create not in agent: nothing changed"

# --- 15c. check launches the ssh flow in Terminal too
reset
echo "Rotate now" > "$T/dialog.answer"
setrot '{gh:{last:'$NOW',step:null,snooze_until:0},ssh:{last:0,step:null,snooze_until:0}}'
run check
assert_eq "$ROTATE ssh" "$(cat "$T/terminal.log")" "check: Rotate now launches '<rotate> ssh' in Terminal"

# --- N1. a signal before the swap never touches github-auth.pub (second rotation, then the first-ever key)
ssh_setup
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub"}}'
cp "$SSHD/github-auth.pub" "$T/pub.before"
echo "old_blob TERM" > "$T/jqsig.flag"
run_sig unused.flag X
assert_eq 130 "$(rc)" "N1 second rotation: exit 130"
assert_eq "yes" "$(cmp -s "$SSHD/github-auth.pub" "$T/pub.before" && echo yes || echo no)" "N1 second rotation: github-auth.pub byte-identical"
assert_contains "$(cat "$T/out")" "no ~/.ssh file was changed" "N1 second rotation: truthful message"
ssh_setup
rm -f "$SSHD/github-auth.pub"; rm -f "$STATE/known-keys.txt"
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub"}}'
echo "old_blob TERM" > "$T/jqsig.flag"
run_sig unused.flag X
assert_eq 130 "$(rc)" "N1 first rotation: exit 130"
assert_eq "no" "$([ -e "$SSHD/github-auth.pub" ] && echo yes || echo no)" "N1 first rotation: nothing written to ~/.ssh"
assert_contains "$(cat "$T/out")" "no ~/.ssh file was changed" "N1 first rotation: truthful message"
# first-ever key, signal right after the swap: the new key is removed (explicit 'none' sentinel), nothing else
ssh_setup
rm -f "$SSHD/github-auth.pub"
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub"}}'
echo '"export" TERM' > "$T/jqsig.flag"
run_sig unused.flag X
assert_eq 130 "$(rc)" "N1 swap interrupted, first key: exit 130"
assert_eq "none" "$(rj .ssh.old_blob)" "N1: first-ever key recorded as none"
assert_eq "no" "$([ -e "$SSHD/github-auth.pub" ] && echo yes || echo no)" "N1 first key: new key removed on rollback"
# unrecorded old_blob never deletes: the file holds the new key, old_blob is empty
ssh_setup
cp "$T/newk.pub" "$SSHD/github-auth.pub"
setrot '{ssh:{last:0,step:"export",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub"}}'
echo "Permission denied (publickey)." > "$T/ssh.out"
run ssh
assert_eq 1 "$(rc)" "N1 unrecorded: exit 1"
assert_eq "$NEWB" "$(blobof "$SSHD/github-auth.pub")" "N1 unrecorded: github-auth.pub never deleted"
assert_contains "$(cat "$T/out")" "not recorded" "N1 unrecorded: says so"
# done clears old_*
ssh_setup
runin '\n\n' ssh
assert_eq "null" "$(jq -r '.ssh.old_blob // "null"' "$STATE/rotation.json")" "N4: done clears old_blob"

# --- N2. abandoned key: export checks the new key is still on GitHub
ssh_setup
printf 'ssh-ed25519 %s\nssh-ed25519 %s\n' "$OLDB" "$OTHERB" > "$T/keys"
cat "$T/newk.pub" >> "$STATE/known-keys.txt"
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub"}}'
run ssh
assert_eq 1 "$(rc)" "N2 abandoned: exit 1"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "N2 abandoned: never swapped"
assert_eq 0 "$(grep -c "$NEWB" "$STATE/known-keys.txt")" "N2 abandoned: blob cleared from known-keys"
assert_eq "null" "$(rj .ssh.step)" "N2 abandoned: step null"
assert_contains "$(cat "$T/out")" "from scratch" "N2 abandoned: tells the owner to start over"
# the rerun reaches create (and completes once the key is back on GitHub)
printf 'ssh-ed25519 %s\nssh-ed25519 %s\nssh-ed25519 %s\n' "$OLDB" "$OTHERB" "$NEWB" > "$T/keys"
runin '\n\n' ssh
assert_eq 0 "$(rc)" "N2 rerun: exit 0"
assert_contains "$(cat "$T/out")" "create a new key named exactly" "N2 rerun: reaches create"
# no information -> nothing changes
ssh_setup
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub"}}'
touch "$T/keys.fail"
cp "$STATE/known-keys.txt" "$T/kk.before"; cp "$STATE/rotation.json" "$T/rot.before"
run ssh
assert_eq 1 "$(rc)" "N2 no information: exit 1"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "N2 no information: never swapped"
assert_eq "$(cat "$T/kk.before")" "$(cat "$STATE/known-keys.txt")" "N2 no information: known-keys unchanged"
assert_eq "$(cat "$T/rot.before")" "$(cat "$STATE/rotation.json")" "N2 no information: rotation.json unchanged"

# --- M-a. a swap left behind by a killed run is undone when the key was abandoned
ssh_setup
printf 'ssh-ed25519 %s\nssh-ed25519 %s\n' "$OLDB" "$OTHERB" > "$T/keys"
cp "$T/newk.pub" "$SSHD/github-auth.pub"; cp "$T/oldk.pub" "$SSHD/github-auth.prev.pub"
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub",old_blob:"'$OLDB'"}}'
run ssh
assert_eq 1 "$(rc)" "M-a abandoned after swap: exit 1"
assert_eq "$OLDB" "$(blobof "$SSHD/github-auth.pub")" "M-a: old key restored"
assert_eq "null" "$(rj .ssh.step)" "M-a: step null"
assert_contains "$(cat "$T/out")" "previous key restored" "M-a: message says it restored the key"
ssh_setup
cp "$T/newk.pub" "$SSHD/github-auth.pub"; cp "$T/oldk.pub" "$SSHD/github-auth.prev.pub"
setrot '{ssh:{last:0,step:"add",snooze_until:0,name:"'$NAME'",pub:"'$SEC'/abc123.pub",old_blob:"'$OLDB'"}}'
touch "$T/keys.fail"
run ssh
assert_eq 1 "$(rc)" "M-a no information after swap: exit 1"
assert_eq "$NEWB" "$(blobof "$SSHD/github-auth.pub")" "M-a no information: file untouched"
assert_contains "$(cat "$T/out")" "already holds the new key" "M-a no information: truthful message"
assert_eq "add" "$(rj .ssh.step)" "M-a no information: step unchanged"

# --- M-b. takeover is atomic and leaves nothing behind
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"; echo '[]' > "$T/gh.repos.json"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
sleep 1 & DEAD=$!; wait $DEAD
mkdir -p "$STATE/rotate.lock"; echo $DEAD > "$STATE/rotate.lock/pid"
runin '\n' gh
assert_eq 0 "$(rc)" "takeover: exit 0"
assert_eq 0 "$(ls -d "$STATE"/rotate.lock.stale.* 2>/dev/null | wc -l | tr -d ' ')" "takeover: no .stale directory left"
# a contender arriving while the new owner is alive is refused
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
sleep 30 & LIVE=$!
mkdir -p "$STATE/rotate.lock"; echo $LIVE > "$STATE/rotate.lock/pid"
runin '\n' gh
assert_eq 1 "$(rc)" "contender vs live lock: refused"
assert_eq "$LIVE" "$(cat "$STATE/rotate.lock/pid")" "contender: lock untouched"
assert_eq 0 "$(ls -d "$STATE"/rotate.lock.stale.* 2>/dev/null | wc -l | tr -d ' ')" "contender: no .stale directory"
kill $LIVE 2>/dev/null; wait $LIVE 2>/dev/null

# --- N3. lock ownership
reset
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"; echo '[]' > "$T/gh.repos.json"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
sleep 30 & HOLDER=$!
mkdir -p "$STATE/rotate.lock"; echo $HOLDER > "$STATE/rotate.lock/pid"; touch -t 202001010000 "$STATE/rotate.lock"
runin '\n' gh
assert_eq 1 "$(rc)" "lock live owner (aged >60 min): refused"
assert_contains "$(cat "$T/out")" "another rotation is running" "lock live owner: message"
assert_eq "$HOLDER" "$(cat "$STATE/rotate.lock/pid")" "lock live owner: lock untouched"
kill $HOLDER 2>/dev/null; wait $HOLDER 2>/dev/null
runin '\n' gh
assert_eq 0 "$(rc)" "lock dead pid: taken over"
assert_eq "no" "$([ -d "$STATE/rotate.lock" ] && echo yes || echo no)" "lock dead pid: released at exit"
# A's cleanup must not remove a lock that now belongs to someone else
echo "$OLDTOK" > "$T/gh.token"; echo "$NEWTOK" > "$T/clip"
setrot '{gh:{last:0,step:null,snooze_until:0}}'
touch "$T/lockswap.flag"
runin '\n' gh
rm -f "$T/lockswap.flag"
assert_eq "99999999" "$(cat "$STATE/rotate.lock/pid" 2>/dev/null)" "lock: a taken-over lock is not removed by the old owner"
rm -rf "$STATE/rotate.lock"

# --- 16. usage
run bogus
assert_eq 2 "$(rc)" "usage: exit 2"

finish
