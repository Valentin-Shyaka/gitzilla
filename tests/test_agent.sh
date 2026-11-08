#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
make_test_key
STATE="$WATCHDOG_STATE_DIR"
export STUB_EVENTS="$T/events.json" STUB_HEALTH_FILE="$T/health.status"
export STUB_PAGE=40 STUB_QUEUE_CTL="$T/ctl.json"
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
start_stub
cat > "$WATCHDOG_CONFIG_DIR/config" <<CFG
WATCHDOG_URL=$STUB_URL
OWNER=alice
NOTE_PUBKEY_FILE=$T/key.pub
TZ_LOCAL=UTC
CFG
Z=0000000000000000000000000000000000000000
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222

export ALLOWED_SIGNERS_FILE="$T/allowed_signers"
export WATCHDOG_REMOTE_URL_TEMPLATE="$T/remotes/%s.git"
export WATCHDOG_NOTIFY_CMD="$T/notify.sh" WATCHDOG_RESTORE_CMD="$T/restore.sh"
export WATCHDOG_SCAN_CMD="$T/scan-ok.sh"
printf '#!/bin/sh\necho "$@" >> "%s/notify.log"\n' "$T" > "$T/notify.sh"
printf '#!/bin/sh\necho "$@" >> "%s/restore.log"\n' "$T" > "$T/restore.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/scan-ok.sh"
chmod +x "$T/notify.sh" "$T/restore.sh" "$T/scan-ok.sh"

AGENT="$WD_ROOT/bin/agent"
poll() { bash "$AGENT" poll >"$T/out" 2>&1; echo $? > "$T/rc"; }
nlines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
reset_state() { rm -rf "$STATE"; mkdir -p "$STATE"; rm -f "$T/notify.log" "$T/restore.log" "$STUB_QUEUE_CTL"; : > "$STUB_LOG"; }
ev() { # seq repo ref before after level -> event json
  jq -cn --argjson seq "$1" --arg repo "$2" --arg ref "$3" --arg b "$4" --arg a "$5" --arg l "$6" \
    '{seq:$seq,delivery:("d"+($seq|tostring)),ts:1760000000,kind:"push",repo:$repo,ref:$ref,before:$b,after:$a,forced:false,level:$l,flags:[]}'
}
set_events() { jq -s . > "$STUB_EVENTS"; }

# --- 1. silent only: heads updated, no incident, cursor advanced, auth header valid
reset_state
{ ev 1 alice/app refs/heads/main $S1 $S2 silent; ev 2 alice/app refs/heads/dev $Z $S1 silent; } | set_events
poll
assert_eq 0 "$(cat "$T/rc")" "silent: exit 0"
assert_eq "$S2" "$(jq -r '."alice/app"["refs/heads/main"]' "$STATE/heads.json")" "silent: heads main"
assert_eq "$S1" "$(jq -r '."alice/app"["refs/heads/dev"]' "$STATE/heads.json")" "silent: heads dev"
assert_eq "2" "$(cat "$STATE/queue-cursor")" "silent: cursor"
assert_eq "no" "$([ -e "$STATE/incidents" ] && ls "$STATE/incidents" | grep -q . && echo yes || echo no)" "silent: no incident"
assert_eq 0 "$(nlines "$T/notify.log")" "silent: no notification"
first="$(head -n1 "$STUB_LOG")"
assert_contains "$(echo "$first" | jq -r .path)" "/queue?after=0" "silent: first request after=0"
hdr="$(echo "$first" | jq -r '.headers["x-watchdog-auth"]')"
printf '%s' "${hdr%%.*}" | base64 -d > "$T/hdr.msg"
printf '%s' "${hdr#*.}" | base64 -d > "$T/hdr.sig"
assert_contains "$(cat "$T/hdr.msg")" '"ts":' "auth: payload has ts"
ssh-keygen -Y check-novalidate -n account-watchdog-queue -s "$T/hdr.sig" < "$T/hdr.msg" >/dev/null 2>&1
assert_eq 0 "$?" "auth: signature verifies in namespace account-watchdog-queue"
assert_eq "no" "$([ -e "$STATE/poll.lock" ] && echo yes || echo no)" "lock: released after poll"
assert_eq 0 "$(ls "$TMPDIR" | wc -l | tr -d ' ')" "tmp: no temp dir left behind"
# second poll resumes after cursor, no events
poll
assert_contains "$(tail -n1 "$STUB_LOG" | jq -r .path)" "/queue?after=2" "cursor: resumes after=2"
assert_eq "2" "$(cat "$STATE/queue-cursor")" "cursor: unchanged when empty"

# --- 2. 67 critical events over 13 repos in several pages -> one incident, one restore
reset_state
i=0
for n in $(seq 1 67); do
  r=$(( n % 13 + 1 )); ev $n "alice/r$r" refs/heads/main $S1 $S2 critical
done | set_events
poll
assert_eq 0 "$(cat "$T/rc")" "67: exit 0"
assert_eq 1 "$(ls "$STATE/incidents" | wc -l | tr -d ' ')" "67: one incident file"
assert_eq "1.json" "$(ls "$STATE/incidents")" "67: named by first seq"
assert_eq 67 "$(jq length "$STATE/incidents/1.json")" "67: events in incident"
assert_eq 1 "$(nlines "$T/restore.log")" "67: one restore invocation"
assert_contains "$(cat "$T/restore.log")" "--prompt $STATE/incidents/1.json" "67: restore args"
assert_eq 1 "$(nlines "$T/notify.log")" "67: one notification"
assert_eq 67 "$(cat "$STATE/queue-cursor")" "67: cursor"
assert_eq 13 "$(jq 'keys|length' "$STATE/heads.json")" "67: heads for 13 repos"
assert_eq 3 "$(grep -c '/queue' "$STUB_LOG" | tr -d ' ')" "67: three pages fetched (40+27+empty)"

# --- 2b. lock released: a second immediate poll really polls
reset_state
ev 1 alice/app refs/heads/main $S1 $S2 silent | set_events
poll; poll
assert_contains "$(tail -n1 "$STUB_LOG" | jq -r .path)" "/queue?after=1" "lock: second immediate poll hit the Worker"
assert_eq "no" "$([ -e "$STATE/poll.lock" ] && echo yes || echo no)" "lock: gone after two polls"
# live lock owned by a running process blocks; dead owner is taken over
reset_state; mkdir "$STATE/poll.lock"; echo $$ > "$STATE/poll.lock/pid"
poll; assert_eq 0 "$(grep -c '/queue' "$STUB_LOG" | tr -d ' ')" "lock: live owner blocks poll"
echo 999999 > "$STATE/poll.lock/pid"
poll; assert_eq 2 "$(grep -c '/queue' "$STUB_LOG" | tr -d ' ')" "lock: dead owner taken over"

# takeover race: the pid file changes between our read and our mv (another poller took over)
reset_state; mkdir "$STATE/poll.lock"; echo 999999 > "$STATE/poll.lock/pid"
mkdir -p "$T/shim"
printf '#!/bin/sh\ncase "$1" in *poll.lock) echo 424242 > "$1/pid" ;; esac\nexec /bin/mv "$@"\n' > "$T/shim/mv"; chmod +x "$T/shim/mv"
PATH="$T/shim:$PATH" poll
assert_eq 0 "$(cat "$T/rc")" "lock race: exit 0"
assert_eq 0 "$(grep -c '/queue' "$STUB_LOG" | tr -d ' ')" "lock race: did not poll"
assert_eq 424242 "$(cat "$STATE/poll.lock/pid" 2>/dev/null)" "lock race: other poller's lock put back"
rm -rf "$T/shim" "$STATE/poll.lock"

# --- 2c. failures leave cursor alone
reset_state; echo 5 > "$STATE/queue-cursor"
ev 6 alice/app refs/heads/main $S1 $S2 critical | set_events
echo '{"status":401}' > "$STUB_QUEUE_CTL"
poll
assert_eq 1 "$(cat "$T/rc")" "401: exit 1"
assert_eq 5 "$(cat "$STATE/queue-cursor")" "401: cursor unchanged"
assert_eq "no" "$([ -e "$STATE/heads.json" ] && echo yes || echo no)" "401: no heads written"
assert_eq "no" "$(ls "$STATE/incidents" | grep -q . && echo yes || echo no)" "401: no incident"
assert_eq 0 "$(nlines "$T/notify.log")" "401: no notification"
assert_eq "no" "$([ -e "$STATE/poll.lock" ] && echo yes || echo no)" "401: lock released"
reset_state
for n in $(seq 1 67); do ev $n alice/r1 refs/heads/main $S1 $S2 critical; done | set_events
echo '{"failAfterGte":40}' > "$STUB_QUEUE_CTL"
poll
assert_eq 1 "$(cat "$T/rc")" "page2 failure: exit 1"
assert_eq "no" "$([ -e "$STATE/queue-cursor" ] && echo yes || echo no)" "page2 failure: cursor unchanged"
assert_eq "no" "$([ -e "$STATE/heads.json" ] && echo yes || echo no)" "page2 failure: nothing written"
assert_eq 0 "$(nlines "$T/notify.log")" "page2 failure: no notification"
# cursor never regresses
reset_state; echo 10 > "$STATE/queue-cursor"
ev 5 alice/app refs/heads/main $S1 $S2 silent | set_events
echo "{\"raw\":{\"events\":[$(ev 5 alice/app refs/heads/main $S1 $S2 silent)],\"next\":5}}" > "$STUB_QUEUE_CTL"
poll
assert_eq 10 "$(cat "$STATE/queue-cursor")" "cursor: never lowered"
assert_eq "no" "$([ -e "$STATE/heads.json" ] && echo yes || echo no)" "replayed seq: heads untouched"
assert_eq "no" "$(ls "$STATE/incidents" | grep -q . && echo yes || echo no)" "replayed seq: no incident"
rm -f "$STUB_QUEUE_CTL"

# --- repos for deep-check tests
GC() { git -c gpg.format=ssh -c user.signingkey="$T/key" -c commit.gpgsign=true "$@"; }
mkdir -p "$T/remotes/alice"
git init -q --bare "$T/remotes/alice/app.git"
W="$T/work"; git init -q -b main "$W"
git -C "$W" commit -q --allow-empty -m base
BASE="$(git -C "$W" rev-parse HEAD)"
git -C "$W" push -q "$T/remotes/alice/app.git" main
echo a > "$W/a.txt"; git -C "$W" add a.txt
GC -C "$W" commit -q -m signed-one
SIGNED="$(git -C "$W" rev-parse HEAD)"
echo b > "$W/b.txt"; git -C "$W" add b.txt
git -C "$W" commit -q -m unsigned-one
UNSIGNED="$(git -C "$W" rev-parse HEAD)"
git -C "$W" push -q "$T/remotes/alice/app.git" main
git -C "$W" checkout -q -b feature "$SIGNED"
echo c > "$W/c.txt"; git -C "$W" add c.txt
GC -C "$W" commit -q -m signed-two
SIGNED2="$(git -C "$W" rev-parse HEAD)"
git -C "$W" push -q "$T/remotes/alice/app.git" feature
# payload commit (signed so only payload can be responsible)
git -C "$W" checkout -q -b stager "$BASE"
base64 -d < "$WD_ROOT/tests/fixtures/stager.js.b64" > "$W/vite.config.js"
git -C "$W" add vite.config.js
GC -C "$W" commit -q -m stager
STAGER="$(git -C "$W" rev-parse HEAD)"
git -C "$W" push -q "$T/remotes/alice/app.git" stager
rm -f "$W/vite.config.js"   # never leave the decoded file around

# unsigned commit that lives ONLY on the branches under test (not on main)
git -C "$W" checkout -q -b evilbase "$BASE"
echo e > "$W/e.txt"; git -C "$W" add e.txt
git -C "$W" commit -q -m unsigned-evil
EVIL="$(git -C "$W" rev-parse HEAD)"

# --- 3. unsigned commit in range -> critical + unsigned
reset_state
ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning | set_events
poll
inc="$STATE/incidents/1.json"
assert_eq critical "$(jq -r '.[0].level' "$inc")" "unsigned: upgraded to critical"
assert_contains "$(jq -c '.[0].flags' "$inc")" unsigned "unsigned: flag"
assert_eq 1 "$(nlines "$T/restore.log")" "unsigned: restore called"
assert_eq 1 "$(nlines "$T/notify.log")" "unsigned: notified"
assert_eq "no" "$(grep -q 'signed-one\|unsigned-one' "$T/notify.log" && echo yes || echo no)" "notify has no commit content"
# signed-only range stays warning
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "signed: stays warning"
assert_eq "no" "$(jq -c '.[0].flags' "$STATE/incidents/1.json" | grep -q unsigned && echo yes || echo no)" "signed: no unsigned flag"
assert_eq 0 "$(nlines "$T/restore.log")" "signed warning: no restore"
assert_eq 1 "$(nlines "$T/notify.log")" "signed warning: notified"
# allowed_signers resolved from git config gpg.ssh.allowedSignersFile (leading ~ expanded) when not overridden
mkdir -p "$HOME/sig"; cp "$T/allowed_signers" "$HOME/sig/as"
git config --global gpg.ssh.allowedSignersFile '~/sig/as'
assert_eq "$HOME/sig/as" "$(bash -c '. "$1/bin/lib.sh"; wd_allowed_signers' _ "$WD_ROOT")" "signers: gpg.ssh.allowedSignersFile with ~ expanded"
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
ALLOWED_SIGNERS_FILE= poll
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "signers from git config: signed range stays warning"
git config --global gpg.ssh.allowedSignersFile "$HOME/sig/missing"
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
ALLOWED_SIGNERS_FILE= poll
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" unsigned "signers from git config: a missing file flags signed commits unsigned"
git config --global --unset gpg.ssh.allowedSignersFile
printf '[gpg "ssh"]\n\tallowedSignersFile = ~/sig/as\n' > "$T/inc.gitconfig"; git config --global include.path "$T/inc.gitconfig"
assert_eq "$HOME/sig/as" "$(bash -c '. "$1/bin/lib.sh"; wd_allowed_signers' _ "$WD_ROOT")" "I2 signers: gpg.ssh.allowedSignersFile from an included file"
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
ALLOWED_SIGNERS_FILE= poll
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "I2 signers from an included file: signed range stays warning"
git config --global --unset-all include.path
assert_eq "$HOME/.config/git/allowed_signers" "$(bash -c '. "$1/bin/lib.sh"; wd_allowed_signers' _ "$WD_ROOT")" "signers: default ~/.config/git/allowed_signers"
mkdir -p "$HOME/.config/git"; cp "$T/allowed_signers" "$HOME/.config/git/allowed_signers"
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
ALLOWED_SIGNERS_FILE= poll
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "signers default path: signed range stays warning"
rm -rf "$HOME/sig" "$HOME/.config/git/allowed_signers"
# new ref: only commits not on other refs are checked (feature adds one signed commit on top of SIGNED)
reset_state
ev 1 alice/app refs/heads/feature $Z $SIGNED2 warning | set_events
poll
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "new ref: signed-only stays warning"
# deleted ref -> skipped, removed from heads
reset_state
{ ev 1 alice/app refs/heads/feature $Z $SIGNED2 silent; ev 2 alice/app refs/heads/feature $SIGNED2 $Z warning; } | set_events
poll
assert_eq "null" "$(jq -r '."alice/app"["refs/heads/feature"]' "$STATE/heads.json")" "deleted: ref removed from heads"
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/2.json")" "deleted: no deep-check upgrade"

# two NEW branches carrying the same unsigned commit in one poll (fresh clone): both must be flagged
reset_state
git -C "$W" push -q "$T/remotes/alice/app.git" "$EVIL:refs/heads/evil1" "$EVIL:refs/heads/evil2"
{ ev 1 alice/app refs/heads/evil1 $Z $EVIL warning; ev 2 alice/app refs/heads/evil2 $Z $EVIL warning; } | set_events
poll
for q in 0 1; do
  assert_eq critical "$(jq -r ".[$q].level" "$STATE/incidents/1.json")" "two-ref: event $q critical"
  assert_contains "$(jq -c ".[$q].flags" "$STATE/incidents/1.json")" unsigned "two-ref: event $q unsigned"
done
# same with a mirror that existed before the push (the fetch brings both branches in)
git -C "$W" push -q "$T/remotes/alice/app.git" ":refs/heads/evil1" ":refs/heads/evil2"
reset_state
git clone -q --mirror "$T/remotes/alice/app.git" "$STATE/mirrors/alice__app.git"
git -C "$W" push -q "$T/remotes/alice/app.git" "$EVIL:refs/heads/evil1" "$EVIL:refs/heads/evil2"
{ ev 1 alice/app refs/heads/evil1 $Z $EVIL warning; ev 2 alice/app refs/heads/evil2 $Z $EVIL warning; } | set_events
poll
for q in 0 1; do
  assert_eq critical "$(jq -r ".[$q].level" "$STATE/incidents/1.json")" "two-ref (existing mirror): event $q critical"
done
# missing `before` takes the same path
git -C "$W" push -q "$T/remotes/alice/app.git" ":refs/heads/evil1"
reset_state
{ ev 1 alice/app refs/heads/main 3333333333333333333333333333333333333333 $EVIL warning; ev 2 alice/app refs/heads/evil2 $Z $EVIL warning; } | set_events
poll
assert_eq critical "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "missing before: critical"
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" unsigned "missing before: unsigned"
git -C "$W" push -q "$T/remotes/alice/app.git" ":refs/heads/evil2"

# timing: branch fetched into the mirror by poll N, its event processed by poll N+1
reset_state
git -C "$W" push -q "$T/remotes/alice/app.git" "$EVIL:refs/heads/evil1"
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "timing: poll N clean"
assert_eq "$EVIL" "$(git -C "$STATE/mirrors/alice__app.git" rev-parse refs/heads/evil1)" "timing: mirror already holds evil1"
{ ev 1 alice/app refs/heads/main $BASE $SIGNED warning; ev 2 alice/app refs/heads/evil1 $Z $EVIL warning; } | set_events
poll
assert_eq critical "$(jq -r '.[0].level' "$STATE/incidents/2.json")" "timing: poll N+1 critical"
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/2.json")" unsigned "timing: poll N+1 unsigned"
# crash replay: mirror fetched, heads and cursor never written
reset_state
git clone -q --mirror "$T/remotes/alice/app.git" "$STATE/mirrors/alice__app.git"
ev 1 alice/app refs/heads/evil1 $Z $EVIL warning | set_events
poll
assert_eq critical "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "replay: critical"
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" unsigned "replay: unsigned"
git -C "$W" push -q "$T/remotes/alice/app.git" ":refs/heads/evil1"

# annotated tag over old unsigned history must not make a new signed branch unsigned
git -C "$W" tag -a -m t oldtag "$EVIL"
git -C "$W" push -q "$T/remotes/alice/app.git" refs/tags/oldtag
git -C "$W" checkout -q -b tagged-new "$EVIL"
echo t > "$W/t.txt"; git -C "$W" add t.txt
GC -C "$W" commit -q -m signed-on-tagged
TAGNEW="$(git -C "$W" rev-parse HEAD)"
git -C "$W" push -q "$T/remotes/alice/app.git" tagged-new
reset_state
ev 1 alice/app refs/heads/tagged-new $Z $TAGNEW warning | set_events
poll
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "annotated tag: signed branch stays warning"
assert_eq "no" "$(jq -c '.[0].flags' "$STATE/incidents/1.json" | grep -q 'unsigned\|check-failed' && echo yes || echo no)" "annotated tag: no unsigned flag"
git -C "$W" push -q "$T/remotes/alice/app.git" ":refs/heads/tagged-new" ":refs/tags/oldtag"

# deep_check subshell dies -> check-failed, level unchanged
reset_state
printf '#!/bin/sh\nkill -9 $PPID\nexit 0\n' > "$T/scan-kill.sh"; chmod +x "$T/scan-kill.sh"
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
WATCHDOG_SCAN_CMD="$T/scan-kill.sh" poll 2>/dev/null
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" check-failed "dead deep_check: check-failed"
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "dead deep_check: level unchanged"
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll
assert_eq "[]" "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" "clean deep_check: no flags"

# --- 3b. mirror fetch failure -> check-failed, level unchanged; notification mentions it
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll   # builds the mirror
mv "$T/remotes/alice/app.git" "$T/remotes/alice/app.git.away"
reset_state_keep_mirror() { rm -rf "$STATE/incidents" "$STATE/queue-cursor" "$STATE/heads.json"; mkdir -p "$STATE/incidents"; rm -f "$T/notify.log" "$T/restore.log"; }
reset_state_keep_mirror
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" check-failed "fetch failure: check-failed"
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "fetch failure: level unchanged"
assert_contains "$(cat "$T/notify.log")" "could not be deep-checked" "fetch failure: notification mentions it"
assert_eq 0 "$(nlines "$T/restore.log")" "fetch failure: no restore"
mv "$T/remotes/alice/app.git.away" "$T/remotes/alice/app.git"
# scan-failed also mentioned
reset_state
WATCHDOG_SCAN_CMD="$T/nonexistent-scan" poll
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
WATCHDOG_SCAN_CMD="$T/nonexistent-scan" poll
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" scan-failed "scan-failed: flag"
assert_contains "$(cat "$T/notify.log")" "1 could not be deep-checked" "scan-failed: notification mentions count"

# --- 3c. crash after cursor (notify dies): next poll re-issues notify + restore exactly once
reset_state
ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning | set_events
printf '#!/bin/sh\nif [ ! -e "%s/crashed" ]; then touch "%s/crashed"; kill -9 $PPID; exit 0; fi\necho "$@" >> "%s/notify.log"\n' "$T" "$T" "$T" > "$T/notify-crash.sh"
chmod +x "$T/notify-crash.sh"; rm -f "$T/crashed"
WATCHDOG_NOTIFY_CMD="$T/notify-crash.sh" bash "$AGENT" poll >/dev/null 2>&1
assert_eq 1 "$(cat "$STATE/queue-cursor")" "crash: cursor already advanced"
assert_eq "yes" "$([ -e "$STATE/incidents/1.pending" ] && echo yes || echo no)" "crash: pending marker left"
assert_eq 0 "$(nlines "$T/notify.log")" "crash: nothing notified yet"
WATCHDOG_NOTIFY_CMD="$T/notify-crash.sh" poll
assert_eq 1 "$(nlines "$T/notify.log")" "crash: notify re-issued once"
assert_eq 1 "$(nlines "$T/restore.log")" "crash: restore re-issued once"
assert_eq "no" "$([ -e "$STATE/incidents/1.pending" ] && echo yes || echo no)" "crash: pending cleared"
WATCHDOG_NOTIFY_CMD="$T/notify-crash.sh" poll
assert_eq 1 "$(nlines "$T/notify.log")" "crash: not repeated on later poll"
assert_eq 1 "$(nlines "$T/restore.log")" "crash: restore not repeated"
reset_state
ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning | set_events
poll
assert_eq "no" "$([ -e "$STATE/incidents/1.pending" ] && echo yes || echo no)" "normal run: pending cleared"

# --- 3d. restore exits 3 (dialog unanswered): marker kept, re-delivered next poll; exit 0 clears it
reset_state
ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning | set_events
printf '#!/bin/sh\necho "$@" >> "%s/restore.log"\nexit 3\n' "$T" > "$T/restore3.sh"; chmod +x "$T/restore3.sh"
WATCHDOG_RESTORE_CMD="$T/restore3.sh" poll
assert_eq 1 "$(nlines "$T/restore.log")" "timeout: restore called"
assert_eq "yes" "$([ -e "$STATE/incidents/1.pending" ] && echo yes || echo no)" "timeout: pending kept on exit 3"
WATCHDOG_RESTORE_CMD="$T/restore3.sh" poll
assert_eq 2 "$(nlines "$T/restore.log")" "timeout: re-delivered on next poll"
assert_eq "yes" "$([ -e "$STATE/incidents/1.pending" ] && echo yes || echo no)" "timeout: still pending while unanswered"
poll
assert_eq 3 "$(nlines "$T/restore.log")" "timeout: re-delivered once more"
assert_eq "no" "$([ -e "$STATE/incidents/1.pending" ] && echo yes || echo no)" "timeout: cleared after exit 0"
poll
assert_eq 3 "$(nlines "$T/restore.log")" "timeout: not repeated after answered"

# --- 3e. two incidents: first pending after an unanswered prompt, second created next poll => ONE restore call with both
reset_state
ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning | set_events
WATCHDOG_RESTORE_CMD="$T/restore3.sh" poll
assert_eq 1 "$(nlines "$T/restore.log")" "batch: first restore call"
{ ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning; ev 2 alice/app refs/heads/main $UNSIGNED $S2 critical; } | set_events
poll
assert_eq 2 "$(nlines "$T/restore.log")" "batch: exactly one more invocation"
assert_eq "--prompt $STATE/incidents/1.json $STATE/incidents/2.json" "$(tail -n1 "$T/restore.log")" "batch: both files, oldest first"
assert_eq 0 "$(ls "$STATE/incidents" | grep -c pending | tr -d ' ')" "batch: all markers cleared on exit 0"
# exit 3 keeps every marker
reset_state
ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning | set_events
WATCHDOG_RESTORE_CMD="$T/restore3.sh" poll
{ ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning; ev 2 alice/app refs/heads/main $UNSIGNED $S2 critical; } | set_events
WATCHDOG_RESTORE_CMD="$T/restore3.sh" poll
assert_eq 2 "$(ls "$STATE/incidents" | grep -c pending | tr -d ' ')" "batch: exit 3 keeps both markers"

# --- 3f. leftover warning-only pending incident + new critical incident => restore gets BOTH files
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll
assert_eq 0 "$(nlines "$T/restore.log")" "warn+crit: warning-only did not call restore"
: > "$STATE/incidents/1.pending"
{ ev 1 alice/app refs/heads/main $BASE $SIGNED warning; ev 2 alice/app refs/heads/main $SIGNED $S2 critical; } | set_events
poll
assert_eq 1 "$(nlines "$T/restore.log")" "warn+crit: one restore call"
assert_eq "--prompt $STATE/incidents/1.json $STATE/incidents/2.json" "$(tail -n1 "$T/restore.log")" "warn+crit: both files passed"

# --- 3g. I1 (probe P3): attacker's first push A1 is a warning whose deep check fails (mirror unreachable); a later
# critical push A2 on the same ref must restore to the owner's commit S, never to A1.
P3O="$T/remotes/alice/p3.git"; git init -q --bare "$P3O"
P3W="$T/p3work"; git init -q -b main "$P3W"
echo s > "$P3W/s.txt"; git -C "$P3W" add s.txt; GC -C "$P3W" commit -q -m owner-base; P3S="$(git -C "$P3W" rev-parse HEAD)"
git -C "$P3W" push -q "$P3O" main
echo payload > "$P3W/p.js"; git -C "$P3W" add p.js; git -C "$P3W" commit -q -m attacker-a1; P3A1="$(git -C "$P3W" rev-parse HEAD)"
git -C "$P3W" commit -q --allow-empty -m attacker-a2; P3A2="$(git -C "$P3W" rev-parse HEAD)"
p3ev() { jq -cn --argjson seq "$1" --arg b "$2" --arg a "$3" --arg l "$4" \
  '{seq:$seq,delivery:("d"+($seq|tostring)),ts:1760000000,kind:"push",repo:"alice/p3",ref:"refs/heads/main",before:$b,after:$a,forced:false,level:$l,flags:["no-note"]}'; }
printf '#!/bin/sh\necho Restore\n' > "$T/dialog-restore.sh"; chmod +x "$T/dialog-restore.sh"
reset_state
git clone -q --mirror "$P3O" "$STATE/mirrors/alice__p3.git"     # mirror from before the attack
git -C "$P3W" push -q "$P3O" "$P3A1:refs/heads/main"             # attacker's first push (fast-forward)
# poll 1: only A1 is known; the mirror cannot be reached (owner away, Touch ID unanswered)
p3ev 1 "$P3S" "$P3A1" warning | set_events
mv "$P3O" "$P3O.off"
WATCHDOG_RESTORE_CMD="$WD_ROOT/bin/restore" WATCHDOG_DIALOG_CMD="$T/dialog-restore.sh" poll
mv "$P3O.off" "$P3O"
assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" check-failed "P3: poll 1 check-failed"
assert_eq warning "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "P3: poll 1 stays a warning"
assert_eq held "$(cat "$STATE/incidents/1.pending" 2>/dev/null)" "P3: marker of the unchecked warning is kept (held)"
assert_eq 1 "$(nlines "$T/notify.log")" "P3: warning notified once"
# a quiet poll: the held incident is not re-notified and no restore runs
WATCHDOG_RESTORE_CMD="$WD_ROOT/bin/restore" WATCHDOG_DIALOG_CMD="$T/dialog-restore.sh" poll
assert_eq 1 "$(nlines "$T/notify.log")" "P3: held incident not re-notified"
assert_eq held "$(cat "$STATE/incidents/1.pending" 2>/dev/null)" "P3: still held"
# poll 2: A2 arrives (critical); the real restore runs over both incidents
git -C "$P3W" push -q "$P3O" "$P3A2:refs/heads/main"             # attacker's second push
{ p3ev 1 "$P3S" "$P3A1" warning; p3ev 2 "$P3A1" "$P3A2" critical; } | set_events
WATCHDOG_RESTORE_CMD="$WD_ROOT/bin/restore" WATCHDOG_DIALOG_CMD="$T/dialog-restore.sh" poll
assert_eq "$P3S" "$(git --git-dir="$P3O" rev-parse refs/heads/main)" "P3: origin main back at the owner's S, not A1"
assert_eq 1 "$(jq '.restored|length' "$STATE/incidents/2.json.result.json")" "P3: result lists the restore"
assert_eq 0 "$(ls "$STATE/incidents" | grep -c pending | tr -d ' ')" "P3: markers cleared after the restore run"
# a warning without a check failure does not hold its marker
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll
assert_eq "no" "$([ -e "$STATE/incidents/1.pending" ] && echo yes || echo no)" "hold: clean warning marker cleared"

# --- 3h. I3: a mirror cloned by the agent never auto-gcs; a commit copied in by `note` survives gc
M="$STATE/mirrors/alice__app.git"
assert_eq 0 "$(git -C "$M" config gc.auto)" "I3: agent clone sets gc.auto 0"
assert_eq never "$(git -C "$M" config gc.pruneExpire)" "I3: agent clone sets gc.pruneExpire never"
assert_eq always "$(git -C "$M" config core.logAllRefUpdates)" "I3: agent clone sets core.logAllRefUpdates always"
git -C "$W" checkout -q -b noted "$BASE"; echo n > "$W/n.txt"; git -C "$W" add n.txt; GC -C "$W" commit -q -m noted
NOTED="$(git -C "$W" rev-parse HEAD)"
( cd "$W" && printf 'refs/heads/noted %s refs/heads/noted %s\n' "$NOTED" "$Z" | bash "$WD_ROOT/bin/note" origin git@github.com:alice/app.git >/dev/null 2>&1 )
assert_eq commit "$(git -C "$M" cat-file -t "$NOTED" 2>/dev/null)" "I3: note copied the commit into the mirror"
# the copied objects are unreferenced; age them past git's default 2-week prune window, then gc as auto-gc would
find "$M/objects" -type f -exec touch -t 202501010000 {} +
git -C "$M" gc -q 2>/dev/null
assert_eq commit "$(git -C "$M" cat-file -t "$NOTED" 2>/dev/null)" "I3: unreferenced noted commit survives git gc"

# --- 3i. I4: events pruned by the Worker while the Mac was offline -> one CRITICAL alert, cursor past the gap
reset_state; echo 5 > "$STATE/queue-cursor"
{ ev 9 alice/app refs/heads/main $S1 $S2 silent; ev 10 alice/app refs/heads/dev $Z $S1 silent; } | set_events
poll
assert_eq 1 "$(nlines "$T/notify.log")" "I4: one notification for the gap"
assert_contains "$(cat "$T/notify.log")" "Account watchdog: CRITICAL" "I4: critical"
assert_contains "$(cat "$T/notify.log")" "3 event(s) were lost while this Mac was offline — check phone/Slack alerts and run \`reconcile all\`" "I4: message"
case "$(cat "$T/notify.log")" in *"revoke tokens at https://github.com/settings/applications") _ok ;; *) _bad "I4: ends with the revoke line" ;; esac
assert_contains "$(cat "$STATE/log/watchdog.log")" "3 event(s) lost" "I4: logged"
assert_eq 10 "$(cat "$STATE/queue-cursor")" "I4: events after the gap processed"
poll
assert_eq 1 "$(nlines "$T/notify.log")" "I4: not repeated"
# the Worker's `oldest` field is used when present, even with no events left at all
reset_state; echo 5 > "$STATE/queue-cursor"
echo '[]' | set_events
echo '{"raw":{"events":[],"next":5,"oldest":12}}' > "$STUB_QUEUE_CTL"
poll
assert_contains "$(cat "$T/notify.log")" "6 event(s) were lost" "I4: oldest field, empty queue"
assert_eq 11 "$(cat "$STATE/queue-cursor")" "I4: cursor moved to oldest-1"
poll
assert_eq 1 "$(nlines "$T/notify.log")" "I4: oldest-based alert not repeated"
# no gap, and a fresh cursor (0), stay quiet
echo '{"raw":{"events":[],"next":11,"oldest":12}}' > "$STUB_QUEUE_CTL"; poll
reset_state; echo '{"raw":{"events":[],"next":0,"oldest":40}}' > "$STUB_QUEUE_CTL"; poll
assert_eq 0 "$(nlines "$T/notify.log")" "I4: fresh install (cursor 0) is not a gap"
rm -f "$STUB_QUEUE_CTL"

# --- 3j. M3: local incident alerts end with the revoke line
reset_state
ev 1 alice/app refs/heads/main $BASE $SIGNED warning | set_events
poll
case "$(cat "$T/notify.log")" in *"revoke tokens at https://github.com/settings/applications") _ok ;; *) _bad "M3: warning ends with the revoke line" ;; esac
reset_state
ev 1 alice/app refs/heads/main $SIGNED $UNSIGNED warning | set_events
poll
case "$(cat "$T/notify.log")" in *"revoke tokens at https://github.com/settings/applications") _ok ;; *) _bad "M3: critical ends with the revoke line" ;; esac

# --- 4. payload via the bundled scanner (the agent's default SCAN)
REAL_SCAN="$WD_ROOT/scanner/scan.sh"
if [ -f "$REAL_SCAN" ] && [ -n "$NODE_BIN" ]; then
  unset WATCHDOG_SCAN_CMD # the default must be the bundled scanner
  reset_state
  ev 1 alice/app refs/heads/stager $BASE $STAGER warning | set_events
  PATH="$(dirname "$NODE_BIN"):$PATH" poll
  assert_contains "$(jq -c '.[0].flags' "$STATE/incidents/1.json")" payload "payload: flag"
  assert_eq critical "$(jq -r '.[0].level' "$STATE/incidents/1.json")" "payload: critical"
  export WATCHDOG_SCAN_CMD="$T/scan-ok.sh"
else
  _bad "payload: $REAL_SCAN or a usable node not found"
fi

# --- 5. disarmed: incident + notification, no restore
reset_state
jq -cn '{seq:1,delivery:"d",ts:1760000000,kind:"disarmed",repo:"alice/app",ref:"",before:"",after:"",forced:false,level:"critical",flags:["app-removed"]}' | set_events
poll
assert_eq 1 "$(jq length "$STATE/incidents/1.json")" "disarmed: in incident"
assert_eq 1 "$(nlines "$T/notify.log")" "disarmed: notified"
assert_eq 0 "$(nlines "$T/restore.log")" "disarmed: no restore (nothing restorable)"
assert_eq "{}" "$(jq -c . "$STATE/heads.json")" "disarmed: heads untouched"
assert_eq 1 "$(cat "$STATE/queue-cursor")" "disarmed: cursor"

# --- 6. queue failure: cursor not advanced, nonzero exit
reset_state
ev 1 alice/app refs/heads/main $S1 $S2 silent | set_events
cp "$WATCHDOG_CONFIG_DIR/config" "$T/config.bak"
sed 's|^WATCHDOG_URL=.*|WATCHDOG_URL=http://127.0.0.1:1|' "$T/config.bak" > "$WATCHDOG_CONFIG_DIR/config"
bash "$AGENT" poll >/dev/null 2>&1; rc=$?
cp "$T/config.bak" "$WATCHDOG_CONFIG_DIR/config"
assert_eq 1 "$rc" "unreachable: exit 1"
assert_eq "no" "$([ -e "$STATE/queue-cursor" ] && echo yes || echo no)" "unreachable: no cursor"

# --- 7. health
reset_state
echo 503 > "$T/health.status"
bash "$AGENT" health >/dev/null 2>&1
assert_eq 0 "$(nlines "$T/notify.log")" "health: first failure silent"
assert_eq "yes" "$([ -s "$STATE/health-fail-since" ] && echo yes || echo no)" "health: fail-since recorded"
echo $(( $(date +%s) - 7200 )) > "$STATE/health-fail-since"
bash "$AGENT" health >/dev/null 2>&1
assert_eq 1 "$(nlines "$T/notify.log")" "health: notified after 2h"
bash "$AGENT" health >/dev/null 2>&1
assert_eq 1 "$(nlines "$T/notify.log")" "health: not repeated"
echo 200 > "$T/health.status"
bash "$AGENT" health >/dev/null 2>&1
assert_eq "no" "$([ -e "$STATE/health-fail-since" ] && echo yes || echo no)" "health: cleared on recovery"

# --- 8. M8: /queue unreadable for over an hour -> health notifies once; a readable queue clears it
reset_state; echo 200 > "$T/health.status"
ev 1 alice/app refs/heads/main $S1 $S2 silent | set_events
echo '{"status":401}' > "$STUB_QUEUE_CTL"
poll
assert_eq "yes" "$([ -s "$STATE/queue-fail-since" ] && echo yes || echo no)" "M8: queue failure recorded"
bash "$AGENT" health >/dev/null 2>&1
assert_eq 0 "$(nlines "$T/notify.log")" "M8: not yet an hour"
echo $(( $(date +%s) - 7200 )) > "$STATE/queue-fail-since"
poll
bash "$AGENT" health >/dev/null 2>&1
assert_eq 1 "$(nlines "$T/notify.log")" "M8: notified after an hour of failures"
assert_contains "$(cat "$T/notify.log")" "queue unreadable" "M8: says the queue is unreadable"
bash "$AGENT" health >/dev/null 2>&1
assert_eq 1 "$(nlines "$T/notify.log")" "M8: not repeated"
rm -f "$STUB_QUEUE_CTL"
poll
assert_eq "no" "$([ -e "$STATE/queue-fail-since" ] && echo yes || echo no)" "M8: cleared by a readable queue"
assert_eq "no" "$([ -e "$STATE/queue-notified" ] && echo yes || echo no)" "M8: notified mark cleared"
# a signing failure counts too
reset_state
echo $(( $(date +%s) - 7200 )) > "$STATE/queue-fail-since"
WATCHDOG_SIGN_KEY="$T/nonexistent-key" poll
assert_eq "yes" "$([ -s "$STATE/queue-fail-since" ] && echo yes || echo no)" "M8: signing failure keeps the failure time"
bash "$AGENT" health >/dev/null 2>&1
assert_eq 1 "$(nlines "$T/notify.log")" "M8: signing failure notified"

finish
