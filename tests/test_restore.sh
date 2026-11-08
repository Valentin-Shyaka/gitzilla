#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
make_test_key
export STUB_EVENTS="$T/events.json"
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
start_stub
cat > "$WATCHDOG_CONFIG_DIR/config" <<CFG
WATCHDOG_URL=$STUB_URL
OWNER=alice
TZ_LOCAL=UTC
CFG
Z=0000000000000000000000000000000000000000
# every test commit is signed by the test key (restore only rewinds to a verified signed commit)
printf '[gpg]\n\tformat = ssh\n[user]\n\tsigningkey = %s\n[commit]\n\tgpgsign = true\n' "$T/key" >> "$GIT_CONFIG_GLOBAL"
cp "$GIT_CONFIG_GLOBAL" "$T/gitconfig.base"
export ALLOWED_SIGNERS_FILE="$T/allowed_signers"
export WATCHDOG_REMOTE_URL_TEMPLATE="$T/remotes/%s.git"
export WATCHDOG_NOTIFY_CMD="$T/notify.sh" WATCHDOG_DIALOG_CMD="$T/dialog.sh"
printf '#!/bin/sh\necho "$1|$2" >> "%s/notify.log"\n' "$T" > "$T/notify.sh"
# dialog stub: prints the next answer from $T/dialog.answers (default Restore), logs the prompt text
cat > "$T/dialog.sh" <<STUB
#!/bin/sh
echo "\$1|\$2" >> "$T/dialog.log"
a="\$(head -n1 "$T/dialog.answers" 2>/dev/null)"
sed -i.bak 1d "$T/dialog.answers" 2>/dev/null
echo "\${a:-Restore}"
STUB
chmod +x "$T/notify.sh" "$T/dialog.sh"

RESTORE="$WD_ROOT/bin/restore"
ORIGIN="$T/remotes/alice/app.git"
WORK="$T/work"
INC="$T/incident.json"
ts_event() { # seq repo ref before after kind ts level
  jq -cn --argjson seq "$1" --arg repo "$2" --arg ref "$3" --arg b "$4" --arg a "$5" --arg k "${6:-push}" --argjson ts "${7:-1760000000}" --arg lvl "${8:-critical}" \
    '{seq:$seq,delivery:("d"+($seq|tostring)),ts:$ts,kind:$k,repo:$repo,ref:$ref,before:$b,after:$a,forced:true,level:$lvl,flags:["unsigned"]}'
}
write_inc() { jq -s . > "$INC"; }
head_of() { git --git-dir="$ORIGIN" rev-parse -q --verify "$1" 2>/dev/null || echo none; }
mhead() { git --git-dir="$(. "$WD_ROOT/bin/lib.sh"; mirror_path alice/app)" rev-parse -q --verify "$1" 2>/dev/null || echo none; }
nlines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
notes() { grep -c '"/note"\|/note' "$STUB_LOG" | tr -d ' '; }
commit() { # file msg -> sha (in $WORK)
  echo "$2" >> "$WORK/$1"; git -C "$WORK" add "$1"; git -C "$WORK" commit -q -m "$2"; git -C "$WORK" rev-parse HEAD
}
setup() {
  rm -rf "$T/remotes" "$WORK" "$WATCHDOG_STATE_DIR" "$T/notify.log" "$T/dialog.log" "$T/dialog.answers" "$INC" "$INC.result.json"
  mkdir -p "$WATCHDOG_STATE_DIR" "$T/remotes/alice"
  : > "$STUB_LOG"
  git init -q --bare "$ORIGIN"
  git init -q -b main "$WORK"
  git -C "$WORK" remote add origin "$ORIGIN"
  C1="$(commit f one)"
  git -C "$WORK" push -q origin main
  . "$WD_ROOT/bin/lib.sh"
  MIRROR="$(mirror_path alice/app)"
  mkdir -p "$(dirname "$MIRROR")"
  git clone -q --mirror "$ORIGIN" "$MIRROR"
}
# attacker force-pushes main to a new commit; mirror then fetches it (as the agent would)
attack_main() {
  git -C "$WORK" checkout -q -B atk "$C1" ; C2="$(commit f evil)"
  git -C "$WORK" push -q -f origin atk:main
  git -C "$MIRROR" fetch -q --prune
}
run() { bash "$RESTORE" "$@" >"$T/out" 2>&1; echo $? > "$T/rc"; }
result() { jq -r "$1" "$INC.result.json"; }

# --- 1. forced push -> branch restored, one note, result lists it, mirror updated, notification
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
run --yes "$INC"
assert_eq 0 "$(cat "$T/rc")" "forced: exit 0"
assert_eq "$C1" "$(head_of refs/heads/main)" "forced: origin main back at before"
assert_eq "$C1" "$(mhead refs/heads/main)" "forced: mirror ref updated"
assert_eq 1 "$(result '.restored|length')" "forced: one restored"
assert_eq refs/heads/main "$(result '.restored[0].ref')" "forced: restored ref"
assert_eq 0 "$(result '.skipped|length')" "forced: none skipped"
assert_eq 1 "$(notes)" "forced: one note sent"
n="$(grep -h '/note' "$STUB_LOG" | head -1 | jq -r .body | jq -r .payload | base64 -d)"
assert_eq "$C2" "$(echo "$n" | jq -r .old_sha)" "forced: note old = attacker sha"
assert_eq "$C1" "$(echo "$n" | jq -r .new_sha)" "forced: note new = restored sha"
assert_contains "$(cat "$T/notify.log")" "revoke tokens at https://github.com/settings/applications" "forced: summary has revoke line"
case "$(cat "$T/notify.log")" in *revoke\ tokens\ at\ https://github.com/settings/applications) _ok ;; *) _bad "forced: summary ends with revoke line" ;; esac
assert_eq 0 "$(nlines "$T/dialog.log")" "forced: --yes shows no dialog"

# --- 2. ref moved past `after` -> skipped, origin untouched
setup; attack_main
git -C "$WORK" checkout -q atk; C3="$(commit f later)"; git -C "$WORK" push -q origin atk:main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
run --yes "$INC"
assert_eq "$C3" "$(head_of refs/heads/main)" "moved: origin unchanged"
assert_eq 0 "$(result '.restored|length')" "moved: nothing restored"
assert_eq "ref moved since the incident" "$(result '.skipped[0].reason')" "moved: reason"
assert_eq refs/heads/main "$(result '.skipped[0].ref')" "moved: skipped ref"

# --- 3. attacker-created branch -> deleted
setup
git -C "$WORK" checkout -q -b evil; C2="$(commit f evil)"; git -C "$WORK" push -q origin evil
git -C "$MIRROR" fetch -q --prune
ts_event 1 alice/app refs/heads/evil "$Z" "$C2" | write_inc
run --yes "$INC"
assert_eq none "$(head_of refs/heads/evil)" "created: branch deleted on origin"
assert_eq none "$(mhead refs/heads/evil)" "created: gone from mirror"
assert_eq 1 "$(result '.restored|length')" "created: restored"
assert_eq "$C1" "$(head_of refs/heads/main)" "created: main untouched"

# --- 3b. attacker-deleted branch -> recreated (and not clobbering a recreated one)
setup
git -C "$WORK" push -q origin main:refs/heads/keep
git -C "$MIRROR" fetch -q --prune
git -C "$WORK" push -q origin :refs/heads/keep
git -C "$MIRROR" fetch -q --prune
ts_event 1 alice/app refs/heads/keep "$C1" "$Z" | write_inc
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/keep)" "deleted: branch recreated"
assert_eq "$C1" "$(mhead refs/heads/keep)" "deleted: mirror ref recreated"
setup
git -C "$WORK" push -q origin main:refs/heads/keep
git -C "$MIRROR" fetch -q --prune
git -C "$WORK" push -q origin :refs/heads/keep
git -C "$WORK" checkout -q -B atk "$C1"; commit f evil >/dev/null
git -C "$WORK" push -q -f origin atk:refs/heads/keep
ts_event 1 alice/app refs/heads/keep "$C1" "$Z" | write_inc
run --yes "$INC"
assert_eq "ref moved since the incident" "$(result '.skipped[0].reason')" "deleted-then-recreated: skipped"

# --- 4. moved tag restored
setup
git -C "$WORK" tag v1 "$C1"; git -C "$WORK" push -q origin refs/tags/v1
git -C "$MIRROR" fetch -q --prune --tags
C2="$(commit f evil)"; git -C "$WORK" tag -f v1 "$C2" >/dev/null; git -C "$WORK" push -q -f origin refs/tags/v1
git -C "$MIRROR" fetch -q --prune --tags -f
ts_event 1 alice/app refs/tags/v1 "$C1" "$C2" | write_inc
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/tags/v1)" "tag: restored"
assert_eq 1 "$(result '.restored|length')" "tag: result"

# --- 5. two events on one ref -> earliest before, latest after
setup; attack_main
git -C "$WORK" checkout -q atk; C3="$(commit f worse)"; git -C "$WORK" push -q -f origin atk:main
git -C "$MIRROR" fetch -q --prune
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2"; ts_event 2 alice/app refs/heads/main "$C2" "$C3"; } | write_inc
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "two events: back at earliest before"
assert_eq 1 "$(result '.restored|length')" "two events: one ref restored"
assert_eq 1 "$(notes)" "two events: one note"

# --- 6. dialog Ignore -> no pushes, no notes
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
echo Ignore > "$T/dialog.answers"
run --prompt "$INC"
assert_eq "$C2" "$(head_of refs/heads/main)" "ignore: origin unchanged"
assert_eq 0 "$(notes)" "ignore: no notes"
assert_contains "$(cat "$T/dialog.log")" "Restore 1 refs in 1 repos to their state at 08:53?" "ignore: dialog text"
assert_contains "$(cat "$T/dialog.log")" "Restore,Details,Ignore" "ignore: buttons"
# --- 6b. dialog Restore -> pushes; Details then Restore -> shows details first
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
printf 'Details\nRestore\n' > "$T/dialog.answers"
run --prompt "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "details->restore: restored"
assert_eq 2 "$(grep -c '^Restore 1 refs' "$T/dialog.log" | tr -d ' ')" "details->restore: two dialogs"
assert_contains "$(cat "$T/dialog.log")" "alice/app refs/heads/main" "details: lists repo and ref"

# --- 7. before object missing from mirror
setup; attack_main
M="$(printf '%040d' 7)"
ts_event 1 alice/app refs/heads/main "$M" "$C2" | write_inc
run --yes "$INC"
assert_eq "old commit not available locally" "$(result '.skipped[0].reason')" "missing: reason"
assert_eq "$C2" "$(head_of refs/heads/main)" "missing: origin unchanged"
assert_eq 0 "$(notes)" "missing: no note"

# --- 8. invalid slug / ref / sha -> skipped invalid event; non-push ignored
setup; attack_main
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2"
  ts_event 2 "../etc" refs/heads/main "$C1" "$C2"
  ts_event 3 "alice/.." refs/heads/main "$C1" "$C2"
  ts_event 4 "alice/app;x" refs/heads/main "$C1" "$C2"
  ts_event 5 alice/app "refs/heads/a b" "$C1" "$C2"
  ts_event 6 alice/app "heads/main" "$C1" "$C2"
  ts_event 7 alice/app "refs/heads/a..b" "$C1" "$C2"
  ts_event 8 alice/app refs/heads/main "zz" "$C2"
  ts_event 9 alice/app refs/heads/other "$C1" "$C2" disarm
  ts_event 10 alice/app refs/heads/other2 "$C1" "$C2" pull_request; } | write_inc
run --yes "$INC"
assert_eq 1 "$(result '.restored|length')" "invalid: only the valid event restored"
assert_eq 7 "$(result '[.skipped[]|select(.reason=="invalid event")]|length')" "invalid: seven invalid events skipped"
assert_eq 7 "$(result '.skipped|length')" "invalid: non-push events not listed"
assert_eq "$C1" "$(head_of refs/heads/main)" "invalid: valid one restored"
assert_eq 1 "$(notes)" "invalid: one note only"

# --- 9. double invocation: second run is harmless, restored carried over, no dialog
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
run --prompt "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "double: first restore"
: > "$T/dialog.log"; : > "$STUB_LOG"; : > "$T/notify.log"
run --prompt "$INC"
assert_eq 0 "$(cat "$T/rc")" "double: second exit 0"
assert_eq 0 "$(nlines "$T/dialog.log")" "double: no second dialog"
assert_eq 0 "$(notes)" "double: no second note"
assert_eq "$C1" "$(head_of refs/heads/main)" "double: origin unchanged"
assert_eq 1 "$(result '.restored|length')" "double: result still lists restored"
assert_eq 0 "$(result '.skipped|length')" "double: nothing skipped"

# --- 10. push failure other than lease (origin unreachable) -> skipped push failed
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
mv "$ORIGIN" "$ORIGIN.gone"
run --yes "$INC"
assert_eq "push failed" "$(result '.skipped[0].reason')" "unreachable: reason"
mv "$ORIGIN.gone" "$ORIGIN"
assert_eq "$C2" "$(head_of refs/heads/main)" "unreachable: origin unchanged"

# helper: second repo alice/other (origin + mirror), main at O1, attacked to O2
setup_other() {
  OORIGIN="$T/remotes/alice/other.git"; OWORK="$T/owork"; rm -rf "$OORIGIN" "$OWORK"
  git init -q --bare "$OORIGIN"; git init -q -b main "$OWORK"; git -C "$OWORK" remote add origin "$OORIGIN"
  echo o >> "$OWORK/g"; git -C "$OWORK" add g; git -C "$OWORK" commit -q -m o1; O1="$(git -C "$OWORK" rev-parse HEAD)"
  git -C "$OWORK" push -q origin main
  OM="$(. "$WD_ROOT/bin/lib.sh"; mirror_path alice/other)"; rm -rf "$OM"; git clone -q --mirror "$OORIGIN" "$OM"
  echo p >> "$OWORK/g"; git -C "$OWORK" commit -q -am o2; O2="$(git -C "$OWORK" rev-parse HEAD)"
  git -C "$OWORK" push -q -f origin main
  git -C "$OM" fetch -q --prune
}

# --- 12. note failure => no push; skipped could not send note
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
echo 500 > "$STUB_STATUS_FILE"
run --yes "$INC"
rm -f "$STUB_STATUS_FILE"
assert_eq "$C2" "$(head_of refs/heads/main)" "note fails: origin unchanged"
assert_contains "$(result '.skipped[0].reason')" "could not send note" "note fails: reason"
assert_contains "$(result '.skipped[0].reason')" "worker returned 500" "note fails: reason has detail"
assert_eq 0 "$(result '.restored|length')" "note fails: nothing restored"

# --- 13. note is sent BEFORE the push (origin pre-receive hook counts notes seen so far)
setup; attack_main
cat > "$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
grep -c '/note' "$STUB_LOG" > "$T/notes_at_push"
HOOK
chmod +x "$ORIGIN/hooks/pre-receive"
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
run --yes "$INC"
assert_eq 1 "$(cat "$T/notes_at_push" 2>/dev/null | tr -d ' ')" "order: note already sent when the push arrives"
assert_eq "$C1" "$(head_of refs/heads/main)" "order: restored"

# --- 14. only critical refs: critical in A restored, warning-only ref in B skipped untouched
setup; attack_main; setup_other
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2" push 1760000000 critical
  ts_event 2 alice/other refs/heads/main "$O1" "$O2" push 1760000000 warning; } | write_inc
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "critical-only: A restored"
assert_eq "$O2" "$(git --git-dir="$OORIGIN" rev-parse refs/heads/main)" "critical-only: B origin unchanged"
assert_eq "not flagged critical — review manually" "$(result '.skipped[]|select(.repo=="alice/other")|.reason')" "critical-only: B reason"
assert_eq 1 "$(notes)" "critical-only: one note only"
# dialog counts only restorable refs; none restorable => no dialog, result written, notified
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" push 1760000000 warning | write_inc
run --prompt "$INC"
assert_eq 0 "$(nlines "$T/dialog.log")" "none critical: no dialog"
assert_eq 1 "$(result '.skipped|length')" "none critical: result written"
assert_eq 1 "$(nlines "$T/notify.log")" "none critical: notified"
# one critical event among several for the same ref makes the ref restorable
setup; attack_main
git -C "$WORK" checkout -q atk; C3="$(commit f worse)"; git -C "$WORK" push -q -f origin atk:main; git -C "$MIRROR" fetch -q --prune
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2" push 1760000000 warning; ts_event 2 alice/app refs/heads/main "$C2" "$C3" push 1760000000 critical; } | write_inc
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "mixed levels: restored to earliest before"

# --- 15. dialog timeout: exit 3, no pushes, no result, no note
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
echo TIMEOUT > "$T/dialog.answers"
run --prompt "$INC"
assert_eq 3 "$(cat "$T/rc")" "timeout: exit 3"
assert_eq "$C2" "$(head_of refs/heads/main)" "timeout: origin unchanged"
assert_eq "no" "$([ -e "$INC.result.json" ] && echo yes || echo no)" "timeout: no result"
assert_eq 0 "$(notes)" "timeout: no note"

# --- 16. push.followTags=true in the global config must not push extra tags
setup
git -C "$WORK" checkout -q -b keepme; K="$(commit f keepme)"
git -C "$MIRROR" fetch -q "$WORK" "$K:refs/heads/keep"
git -C "$MIRROR" tag -a extra "$K" -m extra
printf '[push]\n\tfollowTags = true\n' >> "$GIT_CONFIG_GLOBAL"
ts_event 1 alice/app refs/heads/keep "$K" "$Z" | write_inc
run --yes "$INC"
assert_eq "$K" "$(head_of refs/heads/keep)" "followTags: branch restored"
assert_eq none "$(head_of refs/tags/extra)" "followTags: extra tag not pushed"
cp "$T/gitconfig.base" "$GIT_CONFIG_GLOBAL"

# --- 17. broken chain (owner pushed in between) => skipped interleaved
setup; attack_main
X="$(printf '%040d' 9)"
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2"; ts_event 2 alice/app refs/heads/main "$X" "$C2"; } | write_inc
run --yes "$INC"
assert_eq "interleaved with your own pushes" "$(result '.skipped[0].reason')" "chain: reason"
assert_eq "$C2" "$(head_of refs/heads/main)" "chain: origin unchanged"

# --- 18. result written after each ref: killed mid-run, rerun keeps the earlier restore
setup; attack_main
git -C "$WORK" push -q origin "$C1:refs/heads/zb"; git -C "$MIRROR" fetch -q --prune
git -C "$WORK" checkout -q atk; git -C "$WORK" push -q -f origin "$C2:refs/heads/zb"; git -C "$MIRROR" fetch -q --prune
cat > "$ORIGIN/hooks/pre-receive" <<HOOK
#!/bin/sh
while read old new ref; do
  if [ "\$ref" = refs/heads/zb ]; then kill -9 \$(cat "$T/restore.pid"); sleep 2; exit 1; fi
done
HOOK
chmod +x "$ORIGIN/hooks/pre-receive"
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2"; ts_event 2 alice/app refs/heads/zb "$C1" "$C2"; } | write_inc
bash "$RESTORE" --yes "$INC" >"$T/out" 2>&1 &
echo $! > "$T/restore.pid"; wait $! 2>/dev/null
assert_eq "$C1" "$(head_of refs/heads/main)" "killed: first ref restored before the kill"
assert_eq refs/heads/main "$(result '.restored[0].ref')" "killed: result already lists it"
rm -f "$ORIGIN/hooks/pre-receive"
run --yes "$INC"
assert_eq 2 "$(result '.restored|length')" "killed rerun: both restored"
assert_eq 0 "$(result '.skipped|length')" "killed rerun: first ref not reported moved"
assert_eq "$C1" "$(head_of refs/heads/zb)" "killed rerun: second ref restored"

# --- 18b. multi-incident: inc1 (C1->C2) + inc2 (C2->C3), both critical => back at C1, not C2
setup; attack_main
git -C "$WORK" checkout -q atk; C3="$(commit f worse)"; git -C "$WORK" push -q -f origin atk:main; git -C "$MIRROR" fetch -q --prune
INC1="$T/inc1.json"; INC2="$T/inc2.json"; rm -f "$INC1"* "$INC2"*
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | jq -s . > "$INC1"
ts_event 2 alice/app refs/heads/main "$C2" "$C3" | jq -s . > "$INC2"
bash "$RESTORE" --yes "$INC1" "$INC2" >"$T/out" 2>&1
assert_eq "$C1" "$(head_of refs/heads/main)" "multi: restored to the true pre-attack commit"
assert_eq 1 "$(jq '.restored|length' "$INC2.result.json")" "multi: result in newest file"
assert_eq "no" "$([ -e "$INC1.result.json" ] && echo yes || echo no)" "multi: none in older file"
assert_eq 1 "$(notes)" "multi: one note"
# carry-over reads every file's result
bash "$RESTORE" --yes "$INC1" "$INC2" >"$T/out" 2>&1
assert_eq 1 "$(jq '.restored|length' "$INC2.result.json")" "multi: rerun keeps restored"
# a restored ref recorded only in the OLDER file's result is carried over too
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | jq -s . > "$INC1"
ts_event 2 alice/app refs/heads/main "$C2" "$C2" | jq -s . > "$INC2"
jq -n --arg b "$C1" --arg a "$C2" '{restored:[{repo:"alice/app",ref:"refs/heads/main",before:$b,after:$a,through_seq:2}],skipped:[]}' > "$INC1.result.json"; rm -f "$INC2.result.json"
bash "$RESTORE" --yes "$INC1" "$INC2" >"$T/out" 2>&1
assert_eq "$C2" "$(head_of refs/heads/main)" "multi: older-file restored ref not pushed again"

# --- 18d. state-keyed carry-over: restored, markers not cleared, attacker strikes again (C1->C4)
setup; attack_main
git -C "$WORK" checkout -q atk; C3="$(commit f worse)"; git -C "$WORK" push -q -f origin atk:main; git -C "$MIRROR" fetch -q --prune
rm -f "$INC1"* "$INC2"* "$T/inc3.json"*; INC3="$T/inc3.json"
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | jq -s . > "$INC1"
ts_event 2 alice/app refs/heads/main "$C2" "$C3" | jq -s . > "$INC2"
bash "$RESTORE" --yes "$INC1" "$INC2" >"$T/out" 2>&1
assert_eq "$C1" "$(head_of refs/heads/main)" "rekey: first restore"
assert_eq 2 "$(jq '.restored[0].through_seq' "$INC2.result.json")" "rekey: through_seq recorded"
assert_eq "$C3" "$(jq -r '.restored[0].after' "$INC2.result.json")" "rekey: after recorded"
assert_eq "$C1" "$(jq -r '.restored[0].before' "$INC2.result.json")" "rekey: before recorded"
git -C "$WORK" checkout -q -B atk2 "$C1"; C4="$(commit f again)"; git -C "$WORK" push -q -f origin atk2:main; git -C "$MIRROR" fetch -q --prune
ts_event 3 alice/app refs/heads/main "$C1" "$C4" | jq -s . > "$INC3"
: > "$STUB_LOG"
bash "$RESTORE" --yes "$INC1" "$INC2" "$INC3" >"$T/out" 2>&1
assert_eq "$C1" "$(head_of refs/heads/main)" "rekey: re-attack restored to C1"
assert_eq 1 "$(jq '.restored|length' "$INC3.result.json")" "rekey: one restored entry"
assert_eq 3 "$(jq '.restored[0].through_seq' "$INC3.result.json")" "rekey: through_seq of inc3"
assert_eq 0 "$(jq '.skipped|length' "$INC3.result.json")" "rekey: nothing skipped"
assert_eq 1 "$(notes)" "rekey: one note for the new push"
# unchanged state is still carried over (no push, no note)
: > "$STUB_LOG"
bash "$RESTORE" --yes "$INC1" "$INC2" "$INC3" >"$T/out" 2>&1
assert_eq 0 "$(notes)" "rekey: rerun is a no-op"
# inc3 alone when origin is already at C1: lease rejects, origin unchanged
rm -f "$INC3.result.json"
bash "$RESTORE" --yes "$INC3" >"$T/out" 2>&1
assert_eq "$C1" "$(head_of refs/heads/main)" "rekey: inc3 alone leaves origin at C1"
# a new push whose before is NOT the restored commit => interleaved
setup; attack_main
rm -f "$INC1"* "$INC2"*
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | jq -s . > "$INC1"
bash "$RESTORE" --yes "$INC1" >"$T/out" 2>&1
X="$(printf '%040d' 5)"
ts_event 2 alice/app refs/heads/main "$X" "$C2" | jq -s . > "$INC2"
bash "$RESTORE" --yes "$INC1" "$INC2" >"$T/out" 2>&1
assert_eq "interleaved with your own pushes" "$(jq -r '.skipped[0].reason' "$INC2.result.json")" "rekey: chain must start at recorded before"

# --- 18e. warning-level first file + critical second => restored to C1 (chain spans)
setup; attack_main
git -C "$WORK" checkout -q atk; C3="$(commit f worse)"; git -C "$WORK" push -q -f origin atk:main; git -C "$MIRROR" fetch -q --prune
rm -f "$INC1"* "$INC2"*
ts_event 1 alice/app refs/heads/main "$C1" "$C2" push 1760000000 warning | jq -s . > "$INC1"
ts_event 2 alice/app refs/heads/main "$C2" "$C3" | jq -s . > "$INC2"
bash "$RESTORE" --yes "$INC1" "$INC2" >"$T/out" 2>&1
assert_eq "$C1" "$(head_of refs/heads/main)" "warning+critical: back at C1"

# --- 18f. an unusable incident file is skipped, not fatal; all unusable => exit 2
setup; attack_main
rm -f "$INC1"*; ts_event 1 alice/app refs/heads/main "$C1" "$C2" | jq -s . > "$INC1"
echo '{garbage' > "$T/bad.json"
bash "$RESTORE" --yes "$T/bad.json" "$T/missing.json" "$INC1" >"$T/out" 2>&1; echo $? > "$T/rc"
assert_eq 0 "$(cat "$T/rc")" "bad file: exit 0"
assert_eq "$C1" "$(head_of refs/heads/main)" "bad file: usable file restored"
assert_eq 1 "$(jq '.restored|length' "$INC1.result.json")" "bad file: result in newest usable file"
bash "$RESTORE" --yes "$T/bad.json" "$T/missing.json" >"$T/out" 2>&1; echo $? > "$T/rc"
assert_eq 2 "$(cat "$T/rc")" "all unusable: exit 2"

# --- 18c. osascript failure is logged and treated like a timeout (exit 3)
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
mkdir -p "$T/fakebin"; printf '#!/bin/sh\nexit 7\n' > "$T/fakebin/osascript"; chmod +x "$T/fakebin/osascript"
PATH="$T/fakebin:$PATH" WATCHDOG_DIALOG_CMD= bash "$RESTORE" --prompt "$INC" >"$T/out" 2>&1; echo $? > "$T/rc"
assert_eq 3 "$(cat "$T/rc")" "osascript fail: exit 3"
assert_contains "$(cat "$WATCHDOG_STATE_DIR/log/watchdog.log")" "dialog failed (rc 7)" "osascript fail: logged"
assert_eq "$C2" "$(head_of refs/heads/main)" "osascript fail: no push"

# --- 19. Details, Details, Restore: loops until Restore
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
printf 'Details\nDetails\nRestore\n' > "$T/dialog.answers"
run --prompt "$INC"
assert_eq 3 "$(grep -c '^Restore 1 refs' "$T/dialog.log" | tr -d ' ')" "details loop: three dialogs"
assert_eq "$C1" "$(head_of refs/heads/main)" "details loop: restored"
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
printf 'Details\nTIMEOUT\n' > "$T/dialog.answers"
run --prompt "$INC"
assert_eq 3 "$(cat "$T/rc")" "details then timeout: exit 3"

# --- 20. invalid seq (non-numeric, negative, empty) => invalid event
setup; attack_main
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2" | jq -c '.seq="abc"'
  ts_event 2 alice/app refs/heads/main "$C1" "$C2" | jq -c '.seq=-3'
  ts_event 3 alice/app refs/heads/main "$C1" "$C2" | jq -c '.seq=""'; } | write_inc
run --yes "$INC"
assert_eq 3 "$(result '[.skipped[]|select(.reason=="invalid event")]|length')" "seq: three invalid"
assert_eq "$C2" "$(head_of refs/heads/main)" "seq: nothing pushed"

# --- 21. out-of-order seq in the file: earliest by seq wins
setup; attack_main
git -C "$WORK" checkout -q atk; C3="$(commit f worse)"; git -C "$WORK" push -q -f origin atk:main; git -C "$MIRROR" fetch -q --prune
{ ts_event 2 alice/app refs/heads/main "$C2" "$C3"; ts_event 1 alice/app refs/heads/main "$C1" "$C2"; } | write_inc
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "out of order: earliest-seq before"

# --- 22. attacker-created ref that moved after the incident: delete lease rejects
setup
git -C "$WORK" checkout -q -b evil; C2="$(commit f evil)"; git -C "$WORK" push -q origin evil
git -C "$MIRROR" fetch -q --prune
C3="$(commit f ownerwork)"; git -C "$WORK" push -q origin evil
ts_event 1 alice/app refs/heads/evil "$Z" "$C2" | write_inc
run --yes "$INC"
assert_eq "$C3" "$(head_of refs/heads/evil)" "created-moved: ref kept"
assert_eq "ref moved since the incident" "$(result '.skipped[0].reason')" "created-moved: reason"

# --- 23. partial carry-over: restored kept, skipped retried
setup; attack_main
git -C "$WORK" push -q origin "$C1:refs/heads/zb"; git -C "$MIRROR" fetch -q --prune
git -C "$WORK" checkout -q atk; git -C "$WORK" push -q -f origin "$C2:refs/heads/zb"; git -C "$MIRROR" fetch -q --prune
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2"; ts_event 2 alice/app refs/heads/zb "$C1" "$C2"; } | write_inc
jq -n --arg b "$C1" --arg a "$C2" '{restored:[{repo:"alice/app",ref:"refs/heads/main",before:$b,after:$a,through_seq:1}],skipped:[{repo:"alice/app",ref:"refs/heads/zb",reason:"push failed"}]}' > "$INC.result.json"
run --yes "$INC"
assert_eq "$C2" "$(head_of refs/heads/main)" "carry-over: restored ref not touched again"
assert_eq "$C1" "$(head_of refs/heads/zb)" "carry-over: skipped ref retried"
assert_eq 2 "$(result '.restored|length')" "carry-over: both listed restored"
assert_eq 0 "$(result '.skipped|length')" "carry-over: skipped cleared"
# corrupt result.json is ignored
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
echo '{not json' > "$INC.result.json"
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "corrupt result: restore proceeds"
assert_eq 1 "$(result '.restored|length')" "corrupt result: rewritten"

# --- 23b. M1: a prior entry without a numeric through_seq is ignored (no legacy carry-over)
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
echo '{"restored":[{"repo":"alice/app","ref":"refs/heads/main"}],"skipped":[]}' > "$INC.result.json"
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "M1: legacy entry does not block the restore"
assert_eq 1 "$(result '.restored|length')" "M1: one restored entry"
assert_eq 1 "$(result '.restored[0].through_seq')" "M1: the new entry carries through_seq"
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
jq -n --arg b "$C1" --arg a "$C2" '{restored:[{repo:"alice/app",ref:"refs/heads/main",before:$b,after:$a,through_seq:"1"}],skipped:[]}' > "$INC.result.json"
run --yes "$INC"
assert_eq "$C1" "$(head_of refs/heads/main)" "M1: a string through_seq is ignored too"

# --- 23c. I1(b): the restore target must be a verified signed commit
# The attacker's first push (A1) never reached a restore chain; only A1 -> A2 is in the incident. The group's
# earliest `before` is A1, the attacker's own (unsigned) commit: skip it, never "restore" to it.
setup
git -C "$WORK" checkout -q -B atk "$C1"
echo payload >> "$WORK/f"; git -C "$WORK" add f; git -C "$WORK" -c commit.gpgsign=false commit -q -m attacker-a1; A1="$(git -C "$WORK" rev-parse HEAD)"
echo more >> "$WORK/f"; git -C "$WORK" add f; git -C "$WORK" -c commit.gpgsign=false commit -q -m attacker-a2; A2="$(git -C "$WORK" rev-parse HEAD)"
git -C "$WORK" push -q -f origin atk:main; git -C "$MIRROR" fetch -q --prune
ts_event 2 alice/app refs/heads/main "$A1" "$A2" | write_inc
: > "$STUB_LOG"
run --yes "$INC"
assert_eq "$A2" "$(head_of refs/heads/main)" "I1b: origin untouched (not rewound to the attacker's A1)"
assert_eq 0 "$(result '.restored|length')" "I1b: nothing restored"
assert_eq "restore target not verified — review manually" "$(result '.skipped[0].reason')" "I1b: fixed reason"
assert_eq 0 "$(notes)" "I1b: no note (no push)"
assert_contains "$(cat "$T/notify.log")" "Restored 0 ref(s); 1 skipped" "I1b: summary does not claim a restore"
rp="$(grep -h '"/report"' "$STUB_LOG" | head -1 | jq -r .body | jq -r .payload | base64 -d)"
assert_eq "restore target not verified — review manually" "$(echo "$rp" | jq -r '.skipped[0].reason')" "I1b: reason reaches the report"
# a signed target by a key NOT in allowed_signers is not verified either
setup
ssh-keygen -q -t ed25519 -N '' -C other -f "$T/otherkey" >/dev/null
git -C "$WORK" checkout -q -B atk "$C1"
echo x >> "$WORK/f"; git -C "$WORK" add f; git -C "$WORK" -c user.signingkey="$T/otherkey" commit -q -m other-signed; O1="$(git -C "$WORK" rev-parse HEAD)"
C2="$(commit f evil)"; git -C "$WORK" push -q -f origin atk:main; git -C "$MIRROR" fetch -q --prune
ts_event 1 alice/app refs/heads/main "$O1" "$C2" | write_inc
run --yes "$INC"
assert_eq "$C2" "$(head_of refs/heads/main)" "I1b: target signed by an unknown key is not restored"
assert_eq "restore target not verified — review manually" "$(result '.skipped[0].reason')" "I1b: unknown-key reason"
rm -f "$T/otherkey" "$T/otherkey.pub"

# --- 24. ref component starting with -- is just a ref name
setup
git -C "$WORK" checkout -q -b dd; D="$(commit f dd)"
git -C "$WORK" push -q origin dd:refs/heads/--x; git -C "$MIRROR" fetch -q --prune
git -C "$WORK" checkout -q -B atk "$C1"; D2="$(commit f dd2)"; git -C "$WORK" push -q -f origin atk:refs/heads/--x; git -C "$MIRROR" fetch -q --prune
ts_event 1 alice/app refs/heads/--x "$D" "$D2" | write_inc
run --yes "$INC"
assert_eq "$D" "$(head_of refs/heads/--x)" "dashes: restored"

# --- 25. restore report (signed, to /report): one per run, matches result.json, never changes exit code
reports() { grep -c '"path":"/report"' "$STUB_LOG" | tr -d ' '; }
report_body() { grep -h '"path":"/report"' "$STUB_LOG" | sed -n "${1:-1}p" | jq -r .body; }
setup; attack_main
git -C "$WORK" push -q origin "$C1:refs/heads/zb"; git -C "$MIRROR" fetch -q --prune
git -C "$WORK" checkout -q atk; git -C "$WORK" push -q -f origin "$C2:refs/heads/zb"; git -C "$MIRROR" fetch -q --prune
X="$(printf '%040d' 9)"
{ ts_event 1 alice/app refs/heads/main "$C1" "$C2"; ts_event 2 alice/app refs/heads/zb "$C1" "$C2" push 1760000000 warning; } | write_inc
run --yes "$INC"
assert_eq 0 "$(cat "$T/rc")" "report: exit 0"
assert_eq 1 "$(reports)" "report: exactly one"
rb="$(report_body 1)"
printf '%s' "$rb" | jq -r .payload | base64 -d > "$T/rep.payload"
printf '%s\n' "$rb" | jq -r .sig > "$T/rep.sig"
if ssh-keygen -Y verify -f "$T/allowed_signers" -I test-owner -n account-watchdog-report -s "$T/rep.sig" < "$T/rep.payload" >/dev/null 2>&1; then _ok; else _bad "report: signature verifies in namespace account-watchdog-report"; fi
if ssh-keygen -Y verify -f "$T/allowed_signers" -I test-owner -n account-watchdog-note -s "$T/rep.sig" < "$T/rep.payload" >/dev/null 2>&1; then _bad "report: must not verify as a note"; else _ok; fi
assert_eq "$(result '[.restored[]|{repo,ref}]')" "$(jq -c '.restored' "$T/rep.payload" | jq .)" "report: restored matches result.json"
assert_eq "$(result '.skipped')" "$(jq '.skipped' "$T/rep.payload")" "report: skipped matches result.json"
assert_eq 1 "$(jq .restored_total "$T/rep.payload")" "report: restored_total"
assert_eq 1 "$(jq .skipped_total "$T/rep.payload")" "report: skipped_total"
assert_eq 32 "$(jq -r .nonce "$T/rep.payload" | tr -d '\n' | wc -c | tr -d ' ')" "report: nonce is 32 hex"
case "$(jq -r .ts "$T/rep.payload")" in ''|*[!0-9]*) _bad "report: integer ts" ;; *) _ok ;; esac
assert_eq 1 "$(nlines "$T/notify.log")" "report: local summary still shown"
# worker answering 500: still exit 0, logged, not retried
echo 500 > "$T/report.status"; stop_stub; STUB_REPORT_STATUS_FILE="$T/report.status" start_stub
sed -i.bak "s#^WATCHDOG_URL=.*#WATCHDOG_URL=$STUB_URL#" "$WATCHDOG_CONFIG_DIR/config"
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
run --yes "$INC"
assert_eq 0 "$(cat "$T/rc")" "report 500: exit 0"
assert_eq 1 "$(reports)" "report 500: not retried"
assert_contains "$(cat "$WATCHDOG_STATE_DIR/log/watchdog.log")" "restore report not sent: worker returned 500" "report 500: logged"
assert_eq "$C1" "$(head_of refs/heads/main)" "report 500: still restored"
stop_stub; unset STUB_REPORT_STATUS_FILE; start_stub
sed -i.bak "s#^WATCHDOG_URL=.*#WATCHDOG_URL=$STUB_URL#" "$WATCHDOG_CONFIG_DIR/config"
# nothing attempted and nothing skipped (no events): no report
setup
echo '[]' > "$INC"
run --yes "$INC"
assert_eq 0 "$(reports)" "report: none when nothing to report"
# dialog timeout: no report
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
echo TIMEOUT > "$T/dialog.answers"
run --prompt "$INC"
assert_eq 0 "$(reports)" "report: none on timeout"
# already-restored rerun (carry-over only): no second report
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
run --yes "$INC"; run --yes "$INC"
assert_eq 1 "$(reports)" "report: rerun with nothing new sends no second report"
# wd_send_report directly: totals, byte budget, lower-casing, reason detail sanitising
send_report() { ( . "$WD_ROOT/bin/lib.sh"; WATCHDOG_URL="$STUB_URL" wd_send_report "$1" ); }
: > "$STUB_LOG"
jq -n '{restored:[range(80) | {repo:"Alice/App",ref:("refs/heads/" + ("r" * 180) + (.|tostring)),before:"x",after:"y",through_seq:1}],
        skipped:[range(3) | {repo:"alice/app",ref:"refs/heads/s",reason:"could not send note (worker: http://x.test/?a=1&b=*\n)"}]}' > "$T/big.result.json"
send_report "$T/big.result.json"; assert_eq 0 "$?" "budget: sent"
bb="$(grep -h '"path":"/report"' "$STUB_LOG" | head -1 | jq -r .body)"
bl="$(printf '%s' "$bb" | wc -c | tr -d ' ')"
if [ "$bl" -le 7600 ] && [ "$bl" -gt 4000 ]; then _ok; else _bad "budget: body size $bl within (4000, 7600]"; fi
printf '%s' "$bb" | jq -r .payload | base64 -d > "$T/big.payload"
assert_eq 80 "$(jq .restored_total "$T/big.payload")" "budget: restored_total is the full count"
assert_eq 3 "$(jq .skipped_total "$T/big.payload")" "budget: skipped_total"
if [ "$(jq '.restored|length' "$T/big.payload")" -lt 50 ]; then _ok; else _bad "budget: restored list trimmed"; fi
assert_eq 3 "$(jq '.skipped|length' "$T/big.payload")" "budget: skipped list trimmed last (restored loses first)"
assert_eq 0 "$(jq -r '[.restored[].repo | select(. != "alice/app")] | length' "$T/big.payload")" "budget: repo lower-cased"
rsn="$(jq -r '.skipped[0].reason' "$T/big.payload")"
case "$rsn" in "could not send note ("*")") _ok ;; *) _bad "reason keeps fixed prefix: $rsn" ;; esac
if printf '%s' "$rsn" | grep -Eq '^could not send note \([A-Za-z0-9 ._:/-]{0,100}\)$'; then _ok; else _bad "reason detail sanitised: $rsn"; fi

# worker down entirely: exit 0
setup; attack_main
ts_event 1 alice/app refs/heads/main "$C1" "$C2" | write_inc
stop_stub
sed -i.bak "s#^WATCHDOG_URL=.*#WATCHDOG_URL=http://127.0.0.1:9#" "$WATCHDOG_CONFIG_DIR/config"
run --yes "$INC"
assert_eq 0 "$(cat "$T/rc")" "worker down: exit 0"
assert_contains "$(result '.skipped[0].reason')" "could not send note" "worker down: note failed so ref skipped"
assert_contains "$(cat "$WATCHDOG_STATE_DIR/log/watchdog.log")" "restore report not sent: worker unreachable" "worker down: report failure logged"

# --- 11. usage
run
assert_eq 2 "$(cat "$T/rc")" "usage: exit 2"

finish
