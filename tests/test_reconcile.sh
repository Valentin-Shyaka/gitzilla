#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
STATE="$GITZILLA_STATE_DIR"
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
cat > "$GITZILLA_CONFIG_DIR/config" <<CFG
GITZILLA_URL=http://127.0.0.1:1
OWNER=Alice
CFG
Z=0000000000000000000000000000000000000000
S1=1111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222
S3=3333333333333333333333333333333333333333
S4=4444444444444444444444444444444444444444
T0=1760000000

export GITZILLA_NOTIFY_CMD="$T/notify.sh" GITZILLA_GIT_LS_REMOTE="$T/lsr.sh" GITZILLA_CURL="$T/curl.sh" GITZILLA_SSH_PROBE="$T/probe.sh"
printf '#!/bin/sh\n[ -f "%s/notify.fail" ] && exit 1\necho "$1|$2" >> "%s/notify.log"\n' "$T" "$T" > "$T/notify.sh"
# ls-remote stub: $T/remote/<owner>__<repo> holds "sha<TAB>ref" lines; a missing file is a failure.
cat > "$T/lsr.sh" <<STUB
#!/bin/sh
echo "\$1|\${GIT_SSH_COMMAND:+ssh}" >> "$T/lsr.log"
u="\${1#git@github.com:}"; u="\${u#https://github.com/}"; u="\${u%.git}"
f="$T/remote/\$(echo "\$u" | sed 's|/|__|')"
[ -f "\$f" ] || exit 128
cat "\$f"
STUB
# ssh probe stub: succeeds unless $T/probe.fail exists
cat > "$T/probe.sh" <<STUB
#!/bin/sh
echo probe >> "$T/probe.log"
[ -f "$T/probe.fail" ] && { echo "Permission denied (publickey)."; exit 255; }
echo "Hi alice! You've successfully authenticated, but GitHub does not provide shell access."
exit 1
STUB
# curl stub: serves $T/curl/auth.keys and $T/curl/signing.json; writes -o file, prints the status code.
cat > "$T/curl.sh" <<STUB
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; --max-time|-w) shift ;; -*) ;; *) url="\$1" ;; esac; shift; done
echo "\$url" >> "$T/curl.log"
case "\$url" in
  https://github.com/alice.keys) f="$T/curl/auth.keys" ;;
  "https://api.github.com/users/alice/ssh_signing_keys?per_page=100") f="$T/curl/signing.json" ;;
  *) printf 404; exit 0 ;;
esac
[ -f "\$f.status" ] && { printf '%s' "\$(cat "\$f.status")"; exit 0; }
[ -f "\$f" ] || exit 7
cp "\$f" "\$out"; printf 200
STUB
chmod +x "$T/notify.sh" "$T/lsr.sh" "$T/curl.sh" "$T/probe.sh"

RECONCILE="$WD_ROOT/bin/reconcile"
AGENT="$WD_ROOT/bin/agent"
run() { bash "$RECONCILE" "$@" >"$T/out" 2>&1; echo $? > "$T/rc"; }
runat() { local n="$1"; shift; GITZILLA_NOW="$n" run "$@"; }
nlines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
nincs() { ls "$STATE/incidents" 2>/dev/null | grep -c '^r-.*\.json$' | tr -d ' '; }
lastinc() { echo "$STATE/incidents/$(ls "$STATE/incidents" | grep '^r-.*\.json$' | tail -n1)"; }
reset_state() {
  rm -rf "$STATE" "$T/remote" "$T/curl"; mkdir -p "$STATE/incidents" "$T/remote" "$T/curl"
  rm -f "$T/notify.log" "$T/lsr.log" "$T/curl.log" "$T/probe.log" "$T/notify.fail" "$T/probe.fail"
}
setremote() { # slug sha ref...   (repeat pairs)
  local f="$T/remote/$(echo "$1" | sed 's|/|__|')"; shift; : > "$f"
  while [ $# -gt 1 ]; do printf '%s\t%s\n' "$1" "$2" >> "$f"; shift 2; done
}
sethead() { # slug ref sha   (also lists the slug as seeded)
  grep -qxF -- "$1" "$STATE/seeded.txt" 2>/dev/null || echo "$1" >> "$STATE/seeded.txt"
  [ -s "$STATE/heads.json" ] || echo '{}' > "$STATE/heads.json"
  jq --arg r "$1" --arg ref "$2" --arg s "$3" '.[$r][$ref]=$s' "$STATE/heads.json" > "$T/h.tmp" && mv "$T/h.tmp" "$STATE/heads.json"
}
seen_first() { jq -r --arg k "$1" '.[$k].first // "none"' "$STATE/reconcile-seen.json"; }
seen_alerted() { jq -r --arg k "$1" '.[$k].alerted | tostring' "$STATE/reconcile-seen.json"; }
# A real key pair for the key tests.
ssh-keygen -q -t ed25519 -N '' -C known -f "$T/k1" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C newone -f "$T/k2" >/dev/null
blob() { cut -d' ' -f1,2 "$1.pub"; }

# --- 1. matching heads: nothing happens
reset_state
echo "alice/app public" > "$STATE/repos.txt"
sethead alice/app refs/heads/main $S1
sethead alice/app refs/tags/v1 $S3
setremote alice/app $S1 refs/heads/main $S1 HEAD $S2 refs/pull/3/head $S3 refs/tags/v1 $S3 refs/tags/v1^{}
runat $T0 public
assert_eq 0 "$(cat "$T/rc")" "match: exit 0"
assert_eq 0 "$(nincs)" "match: no incident (HEAD, pull, peeled ignored)"
assert_eq 0 "$(nlines "$T/notify.log")" "match: no notification"
assert_contains "$(cat "$T/lsr.log")" "https://github.com/alice/app.git|" "match: public url, no ssh env"
assert_eq "no" "$([ -e "$STATE/poll.lock" ] && echo yes || echo no)" "match: lock released"
assert_eq 0 "$(ls "$TMPDIR" | wc -l | tr -d ' ')" "match: no temp left behind"

# --- 2. two strikes: a moved ref alerts only once the same sha is seen >= 600 s later
cp "$STATE/heads.json" "$T/heads.before"
setremote alice/app $S2 refs/heads/main $S3 refs/tags/v1
runat $T0 public
assert_eq 0 "$(nincs)" "strike1: no incident on first sighting"
assert_eq 0 "$(nlines "$T/notify.log")" "strike1: no notification"
assert_eq "$T0" "$(seen_first 'alice/app|refs/heads/main')" "strike1: first recorded"
assert_eq "false" "$(seen_alerted 'alice/app|refs/heads/main')" "strike1: not alerted"
runat $((T0 + 599)) public
assert_eq 0 "$(nincs)" "strike1: still quiet at 599 s"
runat $((T0 + 700)) public
assert_eq 1 "$(nincs)" "strike2: one r-* incident"
inc="$(lastinc)"
assert_eq 1 "$(jq length "$inc")" "strike2: one event"
assert_eq "push" "$(jq -r '.[0].kind' "$inc")" "strike2: kind push"
assert_eq "warning" "$(jq -r '.[0].level' "$inc")" "strike2: level warning"
assert_eq "missed-webhook" "$(jq -r '.[0].flags|join(",")' "$inc")" "strike2: flag"
assert_eq "alice/app" "$(jq -r '.[0].repo' "$inc")" "strike2: repo"
assert_eq "refs/heads/main" "$(jq -r '.[0].ref' "$inc")" "strike2: ref"
assert_eq "$S1" "$(jq -r '.[0].before' "$inc")" "strike2: before = heads value"
assert_eq "$S2" "$(jq -r '.[0].after' "$inc")" "strike2: after = remote"
assert_eq "null" "$(jq -r '.[0].seq' "$inc")" "strike2: no seq"
assert_eq 1 "$(nlines "$T/notify.log")" "strike2: one notification"
assert_contains "$(cat "$T/notify.log")" "gitzilla: warning|" "strike2: warning title"
assert_eq "no" "$(ls "$STATE/incidents" | grep -q pending && echo yes || echo no)" "strike2: no .pending marker"
assert_eq "$(cat "$T/heads.before")" "$(cat "$STATE/heads.json")" "strike2: heads.json untouched"
assert_eq "true" "$(seen_alerted 'alice/app|refs/heads/main')" "strike2: marked alerted"
runat $((T0 + 800)) public
assert_eq 1 "$(nincs)" "dedupe: same sha not alerted twice"
assert_eq 1 "$(nlines "$T/notify.log")" "dedupe: no second notification"
setremote alice/app $S4 refs/heads/main $S3 refs/tags/v1
runat $((T0 + 900)) public
assert_eq 2 "$(nincs)" "dedupe: a new sha on an old mismatch re-arms and alerts at once"
assert_eq "$T0" "$(seen_first 'alice/app|refs/heads/main')" "dedupe: first is kept per (repo,ref)"
setremote alice/app $S1 refs/heads/main $S3 refs/tags/v1
runat $((T0 + 1700)) public
assert_eq "{}" "$(jq -c . "$STATE/reconcile-seen.json")" "dedupe: entry dropped when back at baseline"
# a normal push that the agent records before the second run never alerts
setremote alice/app $S2 refs/heads/main $S3 refs/tags/v1
runat $((T0 + 2000)) public
assert_eq "false" "$(seen_alerted 'alice/app|refs/heads/main')" "agent-resolved: first sighting recorded"
sethead alice/app refs/heads/main $S2
runat $((T0 + 2700)) public
assert_eq 2 "$(nincs)" "agent-resolved: no alert once heads.json caught up"
assert_eq "{}" "$(jq -c . "$STATE/reconcile-seen.json")" "agent-resolved: seen cleared"
assert_eq 2 "$(nlines "$T/notify.log")" "agent-resolved: notification count unchanged"
# notify failure: not marked alerted, no incident; alerts again when notify works
sethead alice/app refs/heads/main $S1
runat $((T0 + 3000)) public
touch "$T/notify.fail"
runat $((T0 + 3700)) public
assert_eq 2 "$(nincs)" "notify fail: no incident"
assert_eq "false" "$(seen_alerted 'alice/app|refs/heads/main')" "notify fail: not marked alerted"
rm -f "$T/notify.fail"
runat $((T0 + 4300)) public
assert_eq 3 "$(nincs)" "notify fail: alerts on the next run"
assert_eq "true" "$(seen_alerted 'alice/app|refs/heads/main')" "notify fail: alerted once notify worked"

# --- 3. agent ignores r-* incident files, even with a stray r-*.pending
export STUB_EVENTS="$T/events.json" STUB_HEALTH_FILE="$T/health.status" STUB_QUEUE_CTL="$T/ctl.json"
make_test_key
start_stub
cat > "$GITZILLA_CONFIG_DIR/config" <<CFG
GITZILLA_URL=$STUB_URL
OWNER=Alice
NOTE_PUBKEY_FILE=$T/key.pub
CFG
echo '[]' > "$STUB_EVENTS"
export GITZILLA_RESTORE_CMD="$T/restore.sh"
printf '#!/bin/sh\necho "$@" >> "%s/restore.log"\n' "$T" > "$T/restore.sh"; chmod +x "$T/restore.sh"
jq -cn --arg z "$Z" --arg s "$S2" '[{seq:null,delivery:"x",ts:1,kind:"push",repo:"alice/app",ref:"refs/heads/main",before:$z,after:$s,forced:false,level:"critical",flags:["unsigned"]}]' > "$STATE/incidents/r-5-5.json"
: > "$STATE/incidents/r-5-5.pending"
rm -f "$T/restore.log" "$T/notify.log"
bash "$AGENT" poll >/dev/null 2>&1
assert_eq 0 "$(nlines "$T/restore.log")" "agent: r-* file never reaches restore, even with a stray .pending"
assert_eq 0 "$(nlines "$T/notify.log")" "agent: r-* incidents not re-notified"
assert_eq 4 "$(nincs)" "agent: r-* files left alone"
stop_stub

# N1: sha changing on every run still alerts on run 2 and again on run 3
reset_state
echo "alice/app public" > "$STATE/repos.txt"; sethead alice/app refs/heads/main $S1
setremote alice/app $S2 refs/heads/main; runat $T0 public
setremote alice/app $S3 refs/heads/main; runat $((T0 + 700)) public
assert_eq 1 "$(nincs)" "N1: run 2 alerts although the sha changed"
setremote alice/app $S4 refs/heads/main; runat $((T0 + 1400)) public
assert_eq 2 "$(nincs)" "N1: run 3 alerts for the new sha"
setremote alice/app $S1 refs/heads/main; runat $((T0 + 1500)) public
assert_eq "{}" "$(jq -c . "$STATE/reconcile-seen.json")" "N1: dropped at baseline"

# --- 4. missed new ref, missed delete (baseline from heads.json)
reset_state
echo "alice/app public" > "$STATE/repos.txt"
sethead alice/app refs/heads/main $S1
sethead alice/app refs/heads/gone $S2
setremote alice/app $S1 refs/heads/main $S3 refs/heads/evil
runat $T0 public; runat $((T0 + 700)) public
inc="$(lastinc)"
assert_eq 2 "$(jq length "$inc")" "new/delete: two events"
assert_eq "$Z $S3" "$(jq -r '.[]|select(.ref=="refs/heads/evil")|"\(.before) \(.after)"' "$inc")" "new ref: before zeros"
assert_eq "$S2 $Z" "$(jq -r '.[]|select(.ref=="refs/heads/gone")|"\(.before) \(.after)"' "$inc")" "delete: after zeros"
assert_eq 1 "$(nlines "$T/notify.log")" "new/delete: one notification for the run"

# --- 5. heads.json is the only baseline; seed
reset_state
echo "alice/app public" > "$STATE/repos.txt"
M="$(. "$WD_ROOT/bin/lib.sh"; mirror_path alice/app)"
git init -q --bare "$M"
tree="$(git -C "$M" hash-object -t tree -w /dev/null)"
c1="$(git -C "$M" commit-tree "$tree" -m one)"; c2="$(git -C "$M" commit-tree "$tree" -m two)"
git -C "$M" update-ref refs/heads/main "$c1"
git -C "$M" update-ref refs/pull/9/head "$c2"
git -C "$M" tag -a -m rel v1 "$c1"
tagobj="$(git -C "$M" rev-parse refs/tags/v1)"
setremote alice/app $c2 refs/heads/main
runat $T0 public; runat $((T0 + 700)) public
assert_eq 0 "$(nincs)" "unseeded: no alert even though remote differs from the mirror"
assert_eq 0 "$(nlines "$T/lsr.log")" "unseeded: no ls-remote"
assert_contains "$(cat "$STATE/log/gitzilla.log")" "alice/app not seeded" "unseeded: logged"
assert_eq "no" "$([ -e "$STATE/heads.json" ] && echo yes || echo no)" "unseeded: reconcile never writes heads.json"
# seed adds missing repos only
M2="$(. "$WD_ROOT/bin/lib.sh"; mirror_path alice/other)"; git init -q --bare "$M2"
o2="$(git -C "$M2" commit-tree "$(git -C "$M2" hash-object -t tree -w /dev/null)" -m other)"; git -C "$M2" update-ref refs/heads/main "$o2"
M3="$(. "$WD_ROOT/bin/lib.sh"; mirror_path alice/seeded)"; git init -q --bare "$M3"
git -C "$M3" update-ref refs/heads/main "$(git -C "$M3" commit-tree "$(git -C "$M3" hash-object -t tree -w /dev/null)" -m s)"
printf 'alice/app public\nalice/other private\nalice/seeded public\nalice/nomirror public\n' > "$STATE/repos.txt"
echo '{"alice/seeded":{"refs/heads/main":"'$S1'"}}' > "$STATE/heads.json"
run seed
assert_eq 0 "$(cat "$T/rc")" "seed: exit 0"
assert_eq "$c1" "$(jq -r '."alice/app"["refs/heads/main"]' "$STATE/heads.json")" "seed: branch from mirror"
assert_eq "$tagobj" "$(jq -r '."alice/app"["refs/tags/v1"]' "$STATE/heads.json")" "seed: tag-object sha as ls-remote prints it"
assert_eq "null" "$(jq -r '."alice/app"["refs/pull/9/head"]' "$STATE/heads.json")" "seed: pull refs not seeded"
assert_eq "$o2" "$(jq -r '."alice/other"["refs/heads/main"]' "$STATE/heads.json")" "seed: private repo seeded too"
assert_eq "$S1" "$(jq -r '."alice/seeded"["refs/heads/main"]' "$STATE/heads.json")" "seed: existing entry never modified"
assert_eq "null" "$(jq -r '."alice/nomirror"' "$STATE/heads.json")" "seed: repo without mirror skipped"
assert_eq "no" "$([ -e "$STATE/poll.lock" ] && echo yes || echo no)" "seed: lock released"
cp "$STATE/heads.json" "$T/heads.seeded"; run seed
assert_eq "$(cat "$T/heads.seeded")" "$(cat "$STATE/heads.json")" "seed: idempotent"
# seeded and matching (annotated tag has a peeled line) -> quiet
printf 'alice/app public\n' > "$STATE/repos.txt"
setremote alice/app $c1 refs/heads/main $tagobj refs/tags/v1 $c1 refs/tags/v1^{}
runat $T0 public; runat $((T0 + 700)) public
assert_eq 0 "$(nincs)" "seeded: matching remote is quiet"
# I4: a missed new ref alerts even when the mirror already has it
git -C "$M" update-ref refs/heads/evil "$c2"
setremote alice/app $c1 refs/heads/main $tagobj refs/tags/v1 $c2 refs/heads/evil
runat $((T0 + 1000)) public; runat $((T0 + 1700)) public
assert_eq 1 "$(nincs)" "I4: new ref alerts although the mirror has it"
assert_eq "$Z $c2" "$(jq -r '.[0]|"\(.before) \(.after)"' "$(lastinc)")" "I4: before zeros, after remote"
assert_eq "$c1" "$(git -C "$M" rev-parse refs/heads/main)" "I4: mirror never modified"
# seed busy: exit 1, message, heads untouched
rm -rf "$STATE/poll.lock"; mkdir "$STATE/poll.lock"; echo $$ > "$STATE/poll.lock/pid"
jq 'del(."alice/other")' "$STATE/heads.json" > "$T/h.tmp" && mv "$T/h.tmp" "$STATE/heads.json"; cp "$STATE/heads.json" "$T/heads.seeded"
run seed
assert_eq 1 "$(cat "$T/rc")" "seed busy: exit 1"
assert_contains "$(cat "$T/out")" "busy" "seed busy: message"
assert_eq "$(cat "$T/heads.seeded")" "$(cat "$STATE/heads.json")" "seed busy: heads untouched"
echo 999999 > "$STATE/poll.lock/pid"
run seed
assert_eq 1 "$(cat "$T/rc")" "seed stale lock: not taken over"
rm -rf "$STATE/poll.lock"

# N4: agent pre-recorded main; seed adds only the absent refs and never changes existing values
rm -rf "$T/m.bak"; cp -R "$M" "$T/m.bak"
reset_state; mkdir -p "$(dirname "$M")"; cp -R "$T/m.bak" "$M"
echo "alice/app public" > "$STATE/repos.txt"
git -C "$M" update-ref -d refs/heads/evil
git -C "$M" update-ref refs/heads/dev "$c2"
echo '{"alice/app":{"refs/heads/main":"'$S1'"}}' > "$STATE/heads.json"
run seed
assert_eq "$S1" "$(jq -r '."alice/app"["refs/heads/main"]' "$STATE/heads.json")" "N4: pre-recorded main untouched"
assert_eq "$c2" "$(jq -r '."alice/app"["refs/heads/dev"]' "$STATE/heads.json")" "N4: dev added"
assert_eq "$tagobj" "$(jq -r '."alice/app"["refs/tags/v1"]' "$STATE/heads.json")" "N4: v1 added"
assert_eq "alice/app" "$(cat "$STATE/seeded.txt")" "N4: listed in seeded.txt"
setremote alice/app $S1 refs/heads/main $c2 refs/heads/dev $tagobj refs/tags/v1
runat $T0 public; runat $((T0 + 700)) public
assert_eq 0 "$(nincs)" "N4: no false incident for the partially recorded repo"
# seeded repo whose heads entry was removed (agent saw every branch deleted), remote empty: quiet; new branch: alert
jq 'del(."alice/app")' "$STATE/heads.json" > "$T/h.tmp" && mv "$T/h.tmp" "$STATE/heads.json"
: > "$T/remote/alice__app"
runat $((T0 + 1000)) public; runat $((T0 + 1700)) public
assert_eq 0 "$(nincs)" "N4: empty baseline + empty remote is quiet"
setremote alice/app $S3 refs/heads/fresh
runat $((T0 + 2000)) public; runat $((T0 + 2700)) public
assert_eq 1 "$(nincs)" "N4: a new branch on an empty baseline alerts"
run seed
assert_eq "null" "$(jq -r '."alice/app"' "$STATE/heads.json")" "N4: already-seeded repo is not re-seeded"
# N5: corrupt heads.json is left alone
echo '[1,2]' > "$STATE/heads.json"
printf 'alice/app public\nalice/new public\n' > "$STATE/repos.txt"
M4="$(. "$WD_ROOT/bin/lib.sh"; mirror_path alice/new)"; git init -q --bare "$M4"
git -C "$M4" update-ref refs/heads/main "$(git -C "$M4" commit-tree "$(git -C "$M4" hash-object -t tree -w /dev/null)" -m n)"
run seed
assert_eq 1 "$(cat "$T/rc")" "N5: seed refuses a corrupt heads.json"
assert_contains "$(cat "$T/out")" "not a JSON object" "N5: message"
assert_eq "[1,2]" "$(cat "$STATE/heads.json")" "N5: heads.json untouched"
assert_eq "no" "$(grep -q alice/new "$STATE/seeded.txt" && echo yes || echo no)" "N5: nothing marked seeded"

# --- 6. ls-remote failure for a repo: nothing for that repo, others still checked
reset_state
printf 'alice/down public\nalice/app public\n' > "$STATE/repos.txt"
sethead alice/down refs/heads/main $S1
sethead alice/app refs/heads/main $S1
setremote alice/app $S2 refs/heads/main
runat $T0 public; runat $((T0 + 700)) public
assert_eq 1 "$(nincs)" "lsr fail: other repo still checked"
assert_eq 1 "$(jq length "$(lastinc)")" "lsr fail: failed repo raised nothing"

# --- 7. busy lock: exit 0, nothing done, foreign lock untouched
reset_state
echo "alice/app public" > "$STATE/repos.txt"; sethead alice/app refs/heads/main $S1; setremote alice/app $S2 refs/heads/main
runat $T0 public
mkdir "$STATE/poll.lock"; echo $$ > "$STATE/poll.lock/pid"
runat $((T0 + 700)) public
assert_eq 0 "$(cat "$T/rc")" "busy: exit 0"
assert_eq 0 "$(nincs)" "busy: no incident"
assert_eq "$$" "$(cat "$STATE/poll.lock/pid")" "busy: foreign lock untouched (cleanup only removes its own)"
echo 999999 > "$STATE/poll.lock/pid"
runat $((T0 + 700)) public
assert_eq 0 "$(nincs)" "busy: stale lock is not taken over"
assert_eq "999999" "$(cat "$STATE/poll.lock/pid")" "busy: stale lock left in place"
rm -rf "$STATE/poll.lock"
runat $((T0 + 700)) public
assert_eq 1 "$(nincs)" "busy: next run alerts (seen survived)"

# --- 8. keys
reset_state
: > "$STATE/repos.txt"
{ echo "# known keys"; echo "  $(cat "$T/k1.pub")  "; echo; } > "$STATE/known-keys.txt"   # comment line, trailing key comment, spaces
cp "$T/k1.pub" "$T/curl/auth.keys"
echo '[]' > "$T/curl/signing.json"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "keys: only known keys (with comments in known-keys), no alert"
assert_contains "$(cat "$T/curl.log")" "https://github.com/alice.keys" "keys: auth endpoint (lower-case owner)"
assert_contains "$(cat "$T/curl.log")" "https://api.github.com/users/alice/ssh_signing_keys?per_page=100" "keys: signing endpoint, per_page=100"
cp "$STATE/known-keys.txt" "$T/known.before"
{ cat "$T/k1.pub"; cat "$T/k2.pub"; } > "$T/curl/auth.keys"
run public
assert_eq 1 "$(nlines "$T/notify.log")" "auth key: one notification"
assert_contains "$(cat "$T/notify.log")" "gitzilla: CRITICAL|" "auth key: critical title"
assert_contains "$(cat "$T/notify.log")" "New key on your GitHub account" "auth key: message"
assert_contains "$(cat "$T/notify.log")" "ssh-ed25519" "auth key: type"
assert_contains "$(cat "$T/notify.log")" "SHA256:" "auth key: fingerprint"
case "$(cat "$T/notify.log")" in *newone*) _bad "auth key: comment leaked" ;; *) _ok ;; esac
run public
assert_eq 1 "$(nlines "$T/notify.log")" "auth key: deduped on second run"
assert_eq "$(cat "$T/known.before")" "$(cat "$STATE/known-keys.txt")" "auth key: known-keys.txt never modified"
# removed then re-added -> alerts again
cp "$T/k1.pub" "$T/curl/auth.keys"; run public
assert_eq "" "$(cat "$STATE/reconcile-seen-keys.txt")" "re-add: seen-keys pruned after both fetches succeeded"
{ cat "$T/k1.pub"; cat "$T/k2.pub"; } > "$T/curl/auth.keys"; run public
assert_eq 2 "$(nlines "$T/notify.log")" "re-add: alerts again"
# partial fetch (signing fails): no pruning
cp "$T/k1.pub" "$T/curl/auth.keys"; echo 500 > "$T/curl/signing.json.status"; run public
assert_eq "$(blob "$T/k2")" "$(cat "$STATE/reconcile-seen-keys.txt")" "partial fetch: seen-keys not pruned"
rm -f "$T/curl/signing.json.status"
# notify failure: key not marked seen, alerts when notify works
rm -f "$T/notify.log" "$STATE/reconcile-seen-keys.txt"
{ cat "$T/k1.pub"; cat "$T/k2.pub"; } > "$T/curl/auth.keys"
touch "$T/notify.fail"; run public
assert_eq "" "$(cat "$STATE/reconcile-seen-keys.txt")" "key notify fail: not marked seen"
rm -f "$T/notify.fail"; run public
assert_eq 1 "$(nlines "$T/notify.log")" "key notify fail: alerts next run"
# unknown signing key
rm -f "$T/notify.log" "$STATE/reconcile-seen-keys.txt"
cp "$T/k1.pub" "$T/curl/auth.keys"
jq -n --arg k "$(blob "$T/k2") sigcomment" '[{id:1,key:$k,title:"x"}]' > "$T/curl/signing.json"
run public
assert_eq 1 "$(nlines "$T/notify.log")" "signing key: one notification"
assert_contains "$(cat "$T/notify.log")" "New key on your GitHub account" "signing key: message"
rm -f "$T/notify.log" "$STATE/reconcile-seen-keys.txt"
jq -n --arg k "$(blob "$T/k1")" '[{id:1,key:$k}]' > "$T/curl/signing.json"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "signing key: known one is fine"
# junk lines and an unparseable blob never alert
rm -f "$T/notify.log"
printf 'garbage line\nssh-ed25519 AAAAnotakey\n<html>\n' > "$T/curl/auth.keys"; echo '[]' > "$T/curl/signing.json"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "unparseable key blob: no alert"
assert_contains "$(cat "$STATE/log/gitzilla.log")" "unparseable key blob" "unparseable key blob: logged"

# --- 9. key fetch failure / non-200 / junk -> no alert, no update
reset_state; : > "$STATE/repos.txt"; blob "$T/k1" > "$STATE/known-keys.txt"
cp "$T/k2.pub" "$T/curl/auth.keys.bak"           # auth.keys missing: curl exits 7
echo '[]' > "$T/curl/signing.json"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "fetch fail: no alert"
assert_eq 0 "$(cat "$T/rc")" "fetch fail: exit 0"
cp "$T/curl/auth.keys.bak" "$T/curl/auth.keys"; echo 503 > "$T/curl/auth.keys.status"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "non-200: no alert"
rm -f "$T/curl/auth.keys.status"; echo 'not json' > "$T/curl/signing.json"; blob "$T/k1" > "$T/curl/auth.keys"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "unparseable signing JSON: no alert"
echo '{"message":"rate limited"}' > "$T/curl/signing.json"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "non-array signing JSON: no alert"

# --- 10. missing known-keys.txt -> log, skip key check
reset_state; : > "$STATE/repos.txt"
cp "$T/k2.pub" "$T/curl/auth.keys"; echo '[]' > "$T/curl/signing.json"
run public
assert_eq 0 "$(nlines "$T/notify.log")" "no known-keys: no alert"
assert_contains "$(cat "$STATE/log/gitzilla.log")" "known-keys.txt" "no known-keys: logged"

# --- 10b. seen files that are not JSON objects are treated as empty
reset_state
echo "alice/app public" > "$STATE/repos.txt"; sethead alice/app refs/heads/main $S1; setremote alice/app $S2 refs/heads/main
echo '["junk"]' > "$STATE/reconcile-seen.json"
runat $T0 public
assert_eq "$T0" "$(seen_first 'alice/app|refs/heads/main')" "seen not an object: treated as empty"
assert_contains "$(cat "$STATE/log/gitzilla.log")" "not a JSON object" "seen not an object: logged"

# --- 11. reconcile all: probe, private repos over one ssh session, 24 h gate
reset_state
printf 'alice/pub public\nalice/priv private\nalice/priv2 private\n' > "$STATE/repos.txt"
for r in pub priv priv2; do sethead alice/$r refs/heads/main $S1; setremote alice/$r $S1 refs/heads/main; done
blob "$T/k1" > "$STATE/known-keys.txt"; cp "$T/k1.pub" "$T/curl/auth.keys"; echo '[]' > "$T/curl/signing.json"
runat $T0 public
assert_eq 1 "$(nlines "$T/lsr.log")" "all: public mode touches only public repos"
assert_eq 0 "$(nlines "$T/probe.log")" "all: public mode never probes ssh"
assert_eq "no" "$([ -e "$STATE/reconcile-all-at" ] && echo yes || echo no)" "all: public never writes reconcile-all-at"
rm -f "$T/lsr.log"
runat $T0 all
assert_eq 3 "$(nlines "$T/lsr.log")" "all: three repos checked"
assert_eq 1 "$(nlines "$T/probe.log")" "all: one ssh probe per run"
assert_contains "$(cat "$T/lsr.log")" "git@github.com:alice/priv.git|ssh" "all: private over ssh session env"
assert_eq "$T0" "$(cat "$STATE/reconcile-all-at")" "all: stamped after a clean pass"
rm -f "$T/lsr.log"
runat $((T0 + 20)) all
assert_eq 0 "$(nlines "$T/lsr.log")" "all: skipped when last run < 24h"
assert_eq "$T0" "$(cat "$STATE/reconcile-all-at")" "all: stamp unchanged when skipped"
runat $((T0 + 90000)) all
assert_eq 3 "$(nlines "$T/lsr.log")" "all: runs again after 24h"
# N3: a private mismatch on its first strike shortens the gate to ~1 h
setremote alice/priv2 $S2 refs/heads/main
runat $((T0 + 180000)) all
assert_eq "$((T0 + 180000 - 86400 + 3300))" "$(cat "$STATE/reconcile-all-at")" "N3: short stamp while a private strike is pending"
assert_eq "$((T0 + 180000))" "$(seen_first 'alice/priv2|refs/heads/main')" "N3: private mismatch recorded (first strike)"
runat $((T0 + 180010)) public
assert_eq "$((T0 + 180000))" "$(seen_first 'alice/priv2|refs/heads/main')" "all: private seen entry survives a public run"
rm -f "$T/lsr.log"
runat $((T0 + 180100)) all
assert_eq 0 "$(nlines "$T/lsr.log")" "N3: not yet due 100 s later"
runat $((T0 + 183700)) all
assert_eq 3 "$(nlines "$T/lsr.log")" "N3: runs again after the short gate"
assert_eq 1 "$(nincs)" "N3: second strike on the private repo alerts"
assert_eq "$((T0 + 183700))" "$(cat "$STATE/reconcile-all-at")" "N3: full stamp once nothing is pending"
# N2: default probe goes through the session's GIT_SSH_COMMAND
mkdir -p "$T/fakebin"
printf '#!/bin/sh\necho "$@" >> "%s/ssh.log"\necho "Hi alice! You have successfully authenticated"\nexit 1\n' "$T" > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
rm -f "$STATE/reconcile-all-at" "$T/ssh.log"
env -u GITZILLA_SSH_PROBE PATH="$T/fakebin:$PATH" GITZILLA_NOW=$T0 bash "$RECONCILE" all >/dev/null 2>&1
assert_contains "$(cat "$T/ssh.log")" "ControlMaster=auto" "N2: default probe uses ControlMaster=auto"
assert_contains "$(cat "$T/ssh.log")" "ControlPath=$HOME/.ssh/wd-%C" "N2: default probe shares the ControlPath (in ~/.ssh)"
assert_contains "$(cat "$T/ssh.log")" "IdentityAgent=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh" "M5: probe names the Secretive agent"
assert_eq 700 "$(stat -f %Lp "$HOME/.ssh")" "M4: ~/.ssh created with mode 700"
assert_contains "$(cat "$T/ssh.log")" "-T git@github.com" "N2: default probe is ssh -T git@github.com"
# probe failure: no private ls-remote, no stamp, public still checked
reset_state
printf 'alice/pub public\nalice/priv private\n' > "$STATE/repos.txt"
for r in pub priv; do sethead alice/$r refs/heads/main $S1; setremote alice/$r $S1 refs/heads/main; done
touch "$T/probe.fail"
runat $T0 all
assert_eq 1 "$(nlines "$T/lsr.log")" "probe fail: only the public repo is checked"
assert_eq "no" "$([ -e "$STATE/reconcile-all-at" ] && echo yes || echo no)" "probe fail: no stamp"
assert_contains "$(cat "$STATE/log/gitzilla.log")" "ssh auth probe failed" "probe fail: logged"
rm -f "$T/probe.fail"
# first private repo missing: logged, later one still checked and alerts, stamp written
reset_state
printf 'alice/gone private\nalice/priv2 private\n' > "$STATE/repos.txt"
sethead alice/gone refs/heads/main $S1; sethead alice/priv2 refs/heads/main $S1
setremote alice/priv2 $S2 refs/heads/main            # alice/gone has no remote fixture: ls-remote fails
runat $T0 all; runat $((T0 + 90000)) all
assert_eq 1 "$(nincs)" "private fail: later repo alerts"
assert_eq "alice/priv2" "$(jq -r '.[0].repo' "$(lastinc)")" "private fail: it is the later repo"
assert_contains "$(cat "$STATE/log/gitzilla.log")" "ls-remote failed for alice/gone" "private fail: logged"
assert_eq "$((T0 + 90000))" "$(cat "$STATE/reconcile-all-at")" "private fail: stamp written"

# --- 11b. N3 loop: the short stamp is only for a genuine, freshly checked first strike
hours() { # count probes while running `all` hourly for 6 simulated hours from $1
  local t="$1" i; rm -f "$T/probe.log"
  for i in 0 1 2 3 4 5 6; do runat $((t + i * 3600)) all; done
  nlines "$T/probe.log"
}
mkpriv() {
  reset_state
  printf 'alice/priv2 private\n' > "$STATE/repos.txt"
  sethead alice/priv2 refs/heads/main $S1; setremote alice/priv2 $S2 refs/heads/main
  blob "$T/k1" > "$STATE/known-keys.txt"; cp "$T/k1.pub" "$T/curl/auth.keys"; echo '[]' > "$T/curl/signing.json"
}
# (c) genuine first strike: confirmed by a run ~3300 s later, not before
mkpriv
runat $T0 all
assert_eq "$((T0 - 86400 + 3300))" "$(cat "$STATE/reconcile-all-at")" "loop(c): short stamp for a fresh first strike"
rm -f "$T/lsr.log"; runat $((T0 + 3299)) all
assert_eq 0 "$(nlines "$T/lsr.log")" "loop(c): gated at 3299 s"
runat $((T0 + 3300)) all
assert_eq 1 "$(nlines "$T/lsr.log")" "loop(c): runs at 3300 s"
assert_eq 1 "$(nincs)" "loop(c): confirmed and alerted"
# (a) the repo's ls-remote fails on every later run: one extra prompt, then 24 h cadence
mkpriv
runat $T0 all
rm -f "$T/remote/alice__priv2"
assert_eq 1 "$(hours $((T0 + 3300)))" "loop(a): one extra probe over 6 h after the first strike"
# (b) notify keeps failing: first strike, one confirming run, then 24 h cadence
mkpriv
runat $T0 all
touch "$T/notify.fail"
assert_eq 1 "$(hours $((T0 + 3300)))" "loop(b): one extra probe over 6 h while notify fails"
rm -f "$T/notify.fail"

# --- 11c. Minor A: a HOME path with a space reaches ssh as ONE ControlPath (and IdentityAgent) argument, same for probe and ls-remote
SP="$T/sp ace/state"; mkdir -p "$SP/incidents" "$T/sp ace/home"
printf '#!/bin/sh\nfor a in "$@"; do echo "$a"; done >> "%s/ssh.argv"\necho "Hi alice! You have successfully authenticated"\nexit 1\n' "$T" > "$T/fakebin/ssh"
printf '#!/bin/sh\necho "---lsr" >> "%s/ssh.argv"\nsh -c "$GIT_SSH_COMMAND git@github.com true" >/dev/null 2>&1\nexit 0\n' "$T" > "$T/lsr-ssh.sh"
chmod +x "$T/fakebin/ssh" "$T/lsr-ssh.sh"
echo "alice/priv private" > "$SP/repos.txt"; echo "alice/priv" > "$SP/seeded.txt"
rm -f "$T/ssh.argv"
env -u GITZILLA_SSH_PROBE PATH="$T/fakebin:$PATH" HOME="$T/sp ace/home" GITZILLA_STATE_DIR="$SP" GITZILLA_GIT_LS_REMOTE="$T/lsr-ssh.sh" GITZILLA_NOW=$T0 bash "$RECONCILE" all >/dev/null 2>&1
cp_lines="$(grep -c '^ControlPath=' "$T/ssh.argv")"
assert_eq 2 "$cp_lines" "space: probe and ls-remote each pass one ControlPath element"
assert_eq 1 "$(grep '^ControlPath=' "$T/ssh.argv" | sort -u | wc -l | tr -d ' ')" "space: identical ControlPath for probe and ls-remote"
assert_eq "ControlPath=$T/sp ace/home/.ssh/wd-%C" "$(grep '^ControlPath=' "$T/ssh.argv" | head -n1)" "space: ControlPath intact with the space"
assert_eq 2 "$(grep -c '^IdentityAgent=' "$T/ssh.argv")" "space: one IdentityAgent element each"
assert_eq "IdentityAgent=$T/sp ace/home/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh" "$(grep '^IdentityAgent=' "$T/ssh.argv" | head -n1)" "space: IdentityAgent intact with the space"

# --- 11d. I5: reconcile alerts also go, signed, to the Worker's /alert (phone + Slack); M3: revoke line locally
make_test_key
export STUB_ALERT_STATUS_FILE="$T/alert.status"; rm -f "$T/alert.status"
start_stub
cp "$GITZILLA_CONFIG_DIR/config" "$T/config.rec"
printf 'GITZILLA_URL=%s\nOWNER=Alice\n' "$STUB_URL" > "$GITZILLA_CONFIG_DIR/config"
alerts() { grep '"/alert"' "$STUB_LOG" | jq -r .body | grep .; }
alert_payload() { alerts | sed -n "${1}p" | jq -r .payload | base64 -d; }
# new authentication key
reset_state; : > "$STUB_LOG"
: > "$STATE/repos.txt"; blob "$T/k1" > "$STATE/known-keys.txt"
{ cat "$T/k1.pub"; cat "$T/k2.pub"; } > "$T/curl/auth.keys"; echo '[]' > "$T/curl/signing.json"
run public
assert_eq 1 "$(alerts | wc -l | tr -d ' ')" "I5 key: one /alert"
p1="$(alert_payload 1)"
assert_eq new-key "$(echo "$p1" | jq -r .kind)" "I5 key: kind"
assert_eq ssh-ed25519 "$(echo "$p1" | jq -r .key_type)" "I5 key: key_type"
assert_eq "$(ssh-keygen -lf "$T/k2.pub" | awk '{print $2}')" "$(echo "$p1" | jq -r .fingerprint)" "I5 key: fingerprint"
assert_eq auth "$(echo "$p1" | jq -r .source)" "I5 key: source auth"
assert_eq "kind,ts,nonce,key_type,fingerprint,source" "$(echo "$p1" | jq -r 'keys_unsorted|join(",")')" "I5 key: only the fixed fields"
printf '%s' "$p1" > "$T/al.msg"; alerts | sed -n 1p | jq -r .sig > "$T/al.sig"
ssh-keygen -Y check-novalidate -n gitzilla-alert -s "$T/al.sig" < "$T/al.msg" >/dev/null 2>&1
assert_eq 0 "$?" "I5 key: signed in namespace gitzilla-alert"
assert_contains "$(cat "$T/notify.log")" "Review keys: https://github.com/settings/keys" "M3 key: desktop alert points to the keys page"
case "$(cat "$T/notify.log")" in *"revoke tokens at https://github.com/settings/applications") _ok ;; *) _bad "M3 key: desktop alert ends with the revoke line" ;; esac
assert_eq "$(blob "$T/k2")" "$(cat "$STATE/reconcile-seen-keys.txt")" "I5 key: marked alerted"
# new signing key -> source signing
reset_state; : > "$STUB_LOG"
: > "$STATE/repos.txt"; blob "$T/k1" > "$STATE/known-keys.txt"; cp "$T/k1.pub" "$T/curl/auth.keys"
jq -n --arg k "$(blob "$T/k2")" '[{id:1,key:$k,title:"x"}]' > "$T/curl/signing.json"
run public
assert_eq signing "$(alert_payload 1 | jq -r .source)" "I5 key: source signing"
# desktop notify fails but the Worker took it -> alerted
reset_state; : > "$STUB_LOG"; touch "$T/notify.fail"
: > "$STATE/repos.txt"; blob "$T/k1" > "$STATE/known-keys.txt"; { cat "$T/k1.pub"; cat "$T/k2.pub"; } > "$T/curl/auth.keys"; echo '[]' > "$T/curl/signing.json"
run public
assert_eq "$(blob "$T/k2")" "$(cat "$STATE/reconcile-seen-keys.txt")" "I5 key: alerted when only the Worker succeeded"
# both fail -> not alerted, retried next run
reset_state; : > "$STUB_LOG"; touch "$T/notify.fail"; echo 500 > "$T/alert.status"
: > "$STATE/repos.txt"; blob "$T/k1" > "$STATE/known-keys.txt"; { cat "$T/k1.pub"; cat "$T/k2.pub"; } > "$T/curl/auth.keys"; echo '[]' > "$T/curl/signing.json"
run public
assert_eq "" "$(cat "$STATE/reconcile-seen-keys.txt")" "I5 key: not alerted when both channels failed"
assert_contains "$(cat "$STATE/log/gitzilla.log")" "key alert not sent to the Worker: worker returned 500" "I5 key: Worker failure logged"
rm -f "$T/notify.fail" "$T/alert.status"
# missed webhook: two strikes, then one /alert with the counts
reset_state; : > "$STUB_LOG"
printf 'alice/app public\nalice/lib public\n' > "$STATE/repos.txt"
sethead alice/app refs/heads/main $S1; setremote alice/app $S2 refs/heads/main $S3 refs/heads/dev
sethead alice/lib refs/heads/main $S1; setremote alice/lib $S2 refs/heads/main
runat $T0 public; runat $((T0 + 700)) public
assert_eq 1 "$(alerts | wc -l | tr -d ' ')" "I5 refs: one /alert"
p2="$(alert_payload 1)"
assert_eq "missed-webhook 3 2" "$(echo "$p2" | jq -r '"\(.kind) \(.refs) \(.repos)"')" "I5 refs: kind and counts"
assert_eq "kind,ts,nonce,refs,repos" "$(echo "$p2" | jq -r 'keys_unsorted|join(",")')" "I5 refs: only the fixed fields"
case "$(cat "$T/notify.log")" in *"revoke tokens at https://github.com/settings/applications") _ok ;; *) _bad "M3 refs: desktop alert ends with the revoke line" ;; esac
assert_eq 1 "$(nincs)" "I5 refs: incident written"
# desktop fails, Worker succeeds -> alerted; both fail -> not alerted
reset_state; : > "$STUB_LOG"; touch "$T/notify.fail"
echo "alice/app public" > "$STATE/repos.txt"; sethead alice/app refs/heads/main $S1; setremote alice/app $S2 refs/heads/main
runat $T0 public; runat $((T0 + 700)) public
assert_eq "true" "$(seen_alerted 'alice/app|refs/heads/main')" "I5 refs: alerted when only the Worker succeeded"
reset_state; : > "$STUB_LOG"; touch "$T/notify.fail"; echo 500 > "$T/alert.status"
echo "alice/app public" > "$STATE/repos.txt"; sethead alice/app refs/heads/main $S1; setremote alice/app $S2 refs/heads/main
runat $T0 public; runat $((T0 + 700)) public
assert_eq "false" "$(seen_alerted 'alice/app|refs/heads/main')" "I5 refs: not alerted when both failed"
rm -f "$T/notify.fail" "$T/alert.status"
stop_stub
cp "$T/config.rec" "$GITZILLA_CONFIG_DIR/config"; unset GITZILLA_SIGN_KEY

# --- 12. usage
run bogus
assert_eq 2 "$(cat "$T/rc")" "usage: exit 2"

finish
