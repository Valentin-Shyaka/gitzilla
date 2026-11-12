#!/usr/bin/env bash
# Profiles (GITZILLA_PROFILE): path selection, validation, launchd rendering, and an install run in a profile that
# leaves the personal config, state and launchd jobs alone. Temp HOME; every external command is a stub.
. "$(dirname "$0")/helpers.sh"
LIB="$WD_ROOT/bin/lib.sh"
INSTALL="$WD_ROOT/install.sh"
S="$T/stubs"; mkdir -p "$S" "$T/secrets" "$T/Secretive.app"
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
# the profile decides the paths: drop the helpers' explicit overrides
unset GITZILLA_CONFIG_DIR GITZILLA_STATE_DIR GITZILLA_PROFILE
PC="$HOME/.config/gitzilla"; PS="$HOME/.local/state/gitzilla"

paths() { # -> "<config>|<state>|<mirror of a/b>"; the profile comes from the environment
  bash -c '. "$1"; printf "%s|%s|%s\n" "$GITZILLA_CONFIG_DIR" "$STATE" "$(mirror_path a/b)"' _ "$LIB" 2>&1
}

# --- 1. path selection
assert_eq "$PC|$PS|$PS/mirrors/a__b.git" "$(paths)" "personal: no profile = today's paths"
assert_eq "$PC|$PS|$PS/mirrors/a__b.git" "$(GITZILLA_PROFILE= paths)" "personal: empty profile = today's paths"
assert_eq "$PC/org-acme|$PS/org-acme|$PS/org-acme/mirrors/a__b.git" "$(GITZILLA_PROFILE=org-acme paths)" "profile: config, state and mirrors under <p>"
P40="a234567890123456789012345678901234567890"
assert_eq "$PC/$P40|$PS/$P40|$PS/$P40/mirrors/a__b.git" "$(GITZILLA_PROFILE=$P40 paths)" "profile: 40 chars accepted"
assert_eq "$PC/9|$PS/9|$PS/9/mirrors/a__b.git" "$(GITZILLA_PROFILE=9 paths)" "profile: one digit accepted"
# explicit directories (launchd jobs set them) still win
assert_eq "$T/c|$T/s|$T/s/mirrors/a__b.git" "$(GITZILLA_PROFILE=org-acme GITZILLA_CONFIG_DIR=$T/c GITZILLA_STATE_DIR=$T/s paths)" "profile: explicit dirs win"
# the log goes to the profile's state dir only
GITZILLA_PROFILE=org-acme bash -c '. "$1"; wd_log "hello profile"' _ "$LIB"
assert_contains "$(cat "$PS/org-acme/log/gitzilla.log" 2>/dev/null)" "hello profile" "profile: log in the profile state dir"
assert_eq no "$([ -e "$PS/log" ] && echo yes || echo no)" "profile: no personal log written"
bash -c '. "$1"; wd_log "hello personal"' _ "$LIB"
assert_contains "$(cat "$PS/log/gitzilla.log" 2>/dev/null)" "hello personal" "personal: log in the personal state dir"
case "$(cat "$PS/log/gitzilla.log")" in *"hello profile"*) _bad "personal log holds the profile line" ;; *) _ok ;; esac
# a profile's config is the one sourced
mkdir -p "$PC/org-acme"; echo 'OWNER=acme' > "$PC/org-acme/config"; echo 'OWNER=alice' > "$PC/config"
assert_eq acme "$(GITZILLA_PROFILE=org-acme bash -c '. "$1"; echo "$OWNER"' _ "$LIB")" "profile: sources its own config"
assert_eq alice "$(bash -c '. "$1"; echo "$OWNER"' _ "$LIB")" "personal: sources the personal config"
rm -rf "$HOME/.config" "$HOME/.local"

# --- 2. invalid profiles die (names that would land on a personal file or directory are refused too)
RESERVED="config jq-path log mirrors incidents install-step install-set-hookspath install-secrets-rotated queue-cursor
queue-fail-since queue-notified health-notified health-fail-since reconcile-all-at"
for bad in Org -x a_b a.b "a/b" .. "a b" "${P40}1" "org-acme
x" $RESERVED; do
  o="$(GITZILLA_PROFILE="$bad" bash -c '. "$1"; echo SURVIVED' _ "$LIB" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && _ok || _bad "invalid profile '$bad' must fail"
  case "$o" in *SURVIVED*) _bad "invalid profile '$bad': lib must stop" ;; *) _ok ;; esac
  assert_contains "$o" "GITZILLA_PROFILE" "invalid profile '$bad': says which setting"
done
assert_contains "$(GITZILLA_PROFILE=install-step bash -c '. "$1"' _ "$LIB" 2>&1)" "not a name gitzilla uses for its own files (config jq-path log" "invalid profile: the error lists the reserved names"
assert_eq no "$([ -e "$HOME/.config/gitzilla" ] || [ -e "$HOME/.local/state/gitzilla" ] && echo yes || echo no)" "invalid profile: nothing created"
# every dot-free name bin/* or install.sh writes directly under the config or state dir is reserved (a profile name
# has no dot, so names with one cannot collide)
lib_list="$(bash -c '. "$1"; echo $WD_RESERVED_NAMES' _ "$LIB")"
assert_eq "$(echo $RESERVED)" "$lib_list" "reserved names: the test list is the lib list"
for n in $(grep -ohE '\$\{?(STATE|GITZILLA_CONFIG_DIR)\}?/[A-Za-z0-9._-]+' "$WD_ROOT"/bin/* "$WD_ROOT/install.sh" \
           | sed -E 's|^[^/]*/||' | grep -v '\.' | LC_ALL=C sort -u); do
  case " $lib_list " in *" $n "*) _ok ;; *) _bad "reserved names: '$n' is written under the config/state dir but not reserved" ;; esac
done
o="$(GITZILLA_PROFILE=Bad bash "$INSTALL" --from-step launchd 2>&1 </dev/null)"; rc=$?
[ "$rc" -ne 0 ] && _ok || _bad "install.sh: invalid profile fails"
assert_eq no "$([ -e "$HOME/Library/LaunchAgents" ] && echo yes || echo no)" "install.sh: invalid profile renders nothing"

# --- stubs for install.sh (nothing real is called)
export GITZILLA_GH_CMD="$S/gh" GITZILLA_NPM_CMD="$S/npm" GITZILLA_NPX_CMD="$S/npx" GITZILLA_OPEN_CMD="$S/open"
export GITZILLA_PBPASTE_CMD="$S/pbpaste" GITZILLA_CURL="$S/curl" GITZILLA_LAUNCHCTL_CMD="$S/launchctl"
export GITZILLA_RECONCILE_CMD="$S/reconcile" GITZILLA_ROTATE_CMD="$S/rotate" GITZILLA_SECRETIVE_APP="$T/Secretive.app"
export GITZILLA_RM_CMD="$S/rm" GITZILLA_LAUNCHD_POLL=0 GITZILLA_LAUNCHD_RETRY=0 GITZILLA_NOTIFY_TEST_CMD="$S/notify-test"
export GITZILLA_POLL_INTERVAL=0 GITZILLA_POLL_TIMEOUT=0 GITZILLA_NODE_PATH_FILE="$T/node-path"
ln -s /var/db/timezone/zoneinfo/Europe/Paris "$T/localtime"; export GITZILLA_LOCALTIME="$T/localtime"
cat > "$S/gh" <<STUB
#!/bin/sh
echo "\$*" >> "$T/gh.log"
case "\$1 \$2" in
  "api user") echo Alice ;;
  "repo list") echo '[{"nameWithOwner":"alice/app","visibility":"PRIVATE"},{"nameWithOwner":"Acme/App","visibility":"PRIVATE"}]' ;;
esac
exit 0
STUB
cat > "$S/npx" <<STUB
#!/bin/sh
echo "npx \$*" >> "$T/npx.log"
case "\$2" in
  deploy) echo "  https://gitzilla.acme.workers.dev" ;;
  secret) cat > "$T/secrets/\$4" ;;
esac
exit 0
STUB
cat > "$S/launchctl" <<STUB
#!/bin/sh
echo "\$*" >> "$T/launchctl.log"
case "\$1" in bootout) exit 3 ;; print) exit 113 ;; esac
exit 0
STUB
printf '#!/bin/sh\ncat "%s/clip"\n' "$T" > "$S/pbpaste"
for c in npm open curl reconcile rotate rm notify-test; do printf '#!/bin/sh\necho "%s $*" >> "%s/other.log"\n' "$c" "$T" > "$S/$c"; done
chmod +x "$S"/*
ssh-keygen -q -t ecdsa -N '' -C notekey -f "$T/notekey" >/dev/null; cp "$T/notekey.pub" "$T/clip"

LA="$HOME/Library/LaunchAgents"
# --- 3. launchd render: personal (byte-identical to the templates before profiles) and profile
GITZILLA_INSTALL_STOP_AFTER=launchd bash "$INSTALL" --from-step launchd >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "personal launchd ok"
for j in agent reconcile rotate; do
  p="$LA/io.github.gitzilla.$j.plist"
  plutil -lint "$p" >/dev/null 2>&1 && _ok || _bad "personal $j: plutil -lint"
  plutil -extract EnvironmentVariables.GITZILLA_PROFILE raw "$p" >/dev/null 2>&1 && _bad "personal $j: no GITZILLA_PROFILE key" || _ok
  case "$(cat "$p")" in *@*) _bad "personal $j: unrendered token" ;; *GITZILLA_PROFILE*) _bad "personal $j: profile key present" ;; *) _ok ;; esac
  # the template as it was before profiles, rendered the same way, must give the same bytes
  sed -e '/@PROFILE@/d' "$WD_ROOT/launchd/$j.plist.tmpl" | sed -e "s|@LABEL@|io.github.gitzilla.$j|g" -e "s|@GITZILLA_HOME@|$WD_ROOT|g" \
    -e "s|@STATE@|$PS|g" -e "s|@CONFIG@|$PC|g" > "$T/expect.plist"
  cmp -s "$T/expect.plist" "$p" && _ok || _bad "personal $j: same bytes as before profiles"
  assert_eq "$PS" "$(plutil -extract EnvironmentVariables.GITZILLA_STATE_DIR raw "$p")" "personal $j: state dir"
done
assert_eq 3 "$(grep -c "^bootstrap gui/$(id -u) $LA/io.github.gitzilla\.[a-z]*\.plist" "$T/launchctl.log")" "personal: three personal labels bootstrapped"
cp -R "$LA" "$T/la.personal"
: > "$T/launchctl.log"
# a rotate job an earlier profile install loaded is booted out and removed
echo stale > "$LA/io.github.gitzilla.org-acme.rotate.plist"
GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=launchd bash "$INSTALL" --from-step launchd >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "profile launchd ok"
for j in agent reconcile; do
  label="io.github.gitzilla.org-acme.$j"; p="$LA/$label.plist"
  plutil -lint "$p" >/dev/null 2>&1 && _ok || _bad "profile $j: plutil -lint"
  assert_eq "$label" "$(plutil -extract Label raw "$p")" "profile $j: label"
  assert_eq org-acme "$(plutil -extract EnvironmentVariables.GITZILLA_PROFILE raw "$p")" "profile $j: GITZILLA_PROFILE"
  assert_eq "$PS/org-acme" "$(plutil -extract EnvironmentVariables.GITZILLA_STATE_DIR raw "$p")" "profile $j: state dir"
  assert_eq "$PC/org-acme" "$(plutil -extract EnvironmentVariables.GITZILLA_CONFIG_DIR raw "$p")" "profile $j: config dir"
  assert_eq "$PS/org-acme/log/$j.out" "$(plutil -extract StandardOutPath raw "$p")" "profile $j: log path"
done
assert_eq no "$([ -e "$LA/io.github.gitzilla.org-acme.rotate.plist" ] && echo yes || echo no)" "profile: no rotate job (stale one removed)"
assert_eq 1 "$(grep -c "^bootout gui/$(id -u)/io.github.gitzilla.org-acme.rotate$" "$T/launchctl.log")" "profile: stale rotate job booted out"
assert_eq 0 "$(grep -c '^bootstrap .*rotate' "$T/launchctl.log")" "profile: rotate job never bootstrapped"
assert_contains "$(cat "$T/out")" "no rotate job in a profile" "profile launchd: says there is no rotate job"
assert_eq 0 "$(grep -c 'io\.github\.gitzilla\.\(agent\|reconcile\|rotate\)' "$T/launchctl.log")" "profile: personal labels never booted out or bootstrapped"
assert_eq 4 "$(grep -E '^(bootout|bootstrap) ' "$T/launchctl.log" | grep -E 'io\.github\.gitzilla\.org-acme\.(agent|reconcile)' | grep -c .)" "profile: bootout + bootstrap for each profile job"
diff -r "$T/la.personal" "$LA" 2>/dev/null | grep -v "^Only in $LA: io.github.gitzilla.org-acme" | grep -q . && _bad "profile: personal plists changed" || _ok

# --- 4. a profile install leaves the personal config and state untouched
rm -rf "$HOME/.config" "$HOME/.local" "$HOME/Library" "$T/secrets"; mkdir -p "$T/secrets"
mkdir -p "$PC" "$PS/mirrors/alice__x.git" "$PS/log"
printf 'OWNER=Alice\nGITZILLA_URL=https://gitzilla.alice.workers.dev\n' > "$PC/config"; echo personal-pub > "$PC/push-note.pub"
echo "alice/x private" > "$PS/repos.txt"; echo self-test > "$PS/install-step"; echo 42 > "$PS/queue-cursor"; echo old > "$PS/log/gitzilla.log"
snap() { (cd "$1" && find . -path "./org-acme" -prune -o -print | LC_ALL=C sort | while read -r f; do
  if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(shasum "$f" | cut -d' ' -f1)"; else printf '%s dir\n' "$f"; fi; done); }
snap "$PC" > "$T/pc.before"; snap "$PS" > "$T/ps.before"
# the note key goes to the profile, then the install stops at the worker step: before any wrangler call or prompt
: > "$T/npx.log"; rm -f "$T/gh.log"
printf '\n' | GITZILLA_PROFILE=org-acme bash "$INSTALL" --from-step note-key >"$T/out" 2>&1
assert_eq 1 "$?" "profile install: stops at the worker step"
assert_contains "$(cat "$T/out")" "the worker step is not available in a profile yet" "profile install: worker step refuses"
assert_contains "$(cat "$T/out")" "would deploy over the personal Worker 'gitzilla'" "profile install: says why"
assert_contains "$(cat "$T/out")" "./install.sh --org" "profile install: says where profile Workers come from"
assert_contains "$(cat "$T/out")" "--from-step github-app" "profile install: says how to continue with an existing config"
assert_eq "" "$(cat "$T/npx.log")" "profile install: worker refusal makes no npx/wrangler call"
assert_eq no "$([ -e "$T/gh.log" ] && echo yes || echo no)" "profile install: worker refusal makes no gh call"
case "$(cat "$T/out")" in *KEEP*|*WEBHOOK_SECRET*|*Slack*|*"input hidden"*) _bad "profile install: worker refusal must come before any prompt" ;; *) _ok ;; esac
assert_eq "$(head -n1 "$T/notekey.pub")" "$(head -n1 "$PC/org-acme/push-note.pub")" "profile install: note key saved in the profile"
assert_eq note-key "$(cat "$PS/org-acme/install-step")" "profile install: refused worker step not recorded"
assert_eq no "$([ -e "$PC/org-acme/config" ] && echo yes || echo no)" "profile install: no profile config written"
# a plain rerun resumes at the worker step and stops there again, with the same message
GITZILLA_PROFILE=org-acme bash "$INSTALL" >"$T/out" 2>&1 </dev/null
assert_eq 1 "$?" "profile install: plain rerun stops at the worker step"
assert_contains "$(cat "$T/out")" "== step: worker" "profile install: plain rerun resumes at worker"
assert_contains "$(cat "$T/out")" "./install.sh --org" "profile install: plain rerun says what to do"
assert_eq "" "$(cat "$T/npx.log")" "profile install: plain rerun makes no npx call"
# the profile's own config (what --org will write), seeded here instead of running the worker step
printf 'OWNER=Acme\nGITZILLA_URL=https://gitzilla-acme.acme.workers.dev\nNOTE_PUBKEY_FILE=%s\n' "$PC/org-acme/push-note.pub" > "$PC/org-acme/config"
GITZILLA_PROFILE=org-acme bash "$INSTALL" --from-step worker >"$T/out" 2>&1 </dev/null
assert_eq 1 "$?" "profile install: worker step refuses with a config too"
assert_eq "" "$(cat "$T/npx.log")" "profile install: still no npx call"
case "$(cat "$T/out")" in *KEEP*) _bad "profile install: no keep/rotate prompt" ;; *) _ok ;; esac
# the hook step is skipped (and recorded) in a profile, so the install goes on to repos
GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=repos bash "$INSTALL" --from-step hook >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "profile install: hook skipped, repos ok"
assert_contains "$(cat "$T/out")" "hook step skipped in profile org-acme: the hook is installed by the personal profile" "profile install: says the hook is skipped and why"
assert_contains "$(cat "$T/out")" "== step: repos" "profile install: goes on after the hook step"
assert_eq "" "$(git config --global --get core.hooksPath)" "profile install: core.hooksPath untouched"
assert_eq no "$([ -e "$HOME/.config/git" ] || [ -e "$T/node-path" ] || [ -e "$PC/org-acme/jq-path" ] && echo yes || echo no)" "profile install: no hook files written"
assert_eq "acme/app private" "$(cat "$PS/org-acme/repos.txt" 2>/dev/null)" "profile install: repos.txt in the profile"
assert_eq repos "$(cat "$PS/org-acme/install-step")" "profile install: progress in the profile state"
GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=launchd bash "$INSTALL" --from-step launchd >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "profile install: launchd ok"
# first-rotation is skipped in a profile (rotation belongs to the personal profile)
: > "$T/other.log"
GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=first-rotation bash "$INSTALL" --from-step first-rotation >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "profile install: first-rotation skipped"
assert_contains "$(cat "$T/out")" "first-rotation skipped in profile org-acme" "profile install: says first-rotation is skipped"
assert_eq 0 "$(grep -c '^rotate ' "$T/other.log")" "profile install: rotate never run"
snap "$PC" > "$T/pc.after"; snap "$PS" > "$T/ps.after"
assert_eq "$(cat "$T/pc.before")" "$(cat "$T/pc.after")" "profile install: personal config untouched"
assert_eq "$(cat "$T/ps.before")" "$(cat "$T/ps.after")" "profile install: personal state untouched"
assert_eq no "$([ -e "$LA/io.github.gitzilla.agent.plist" ] && echo yes || echo no)" "profile install: no personal launchd job written"
assert_eq no "$([ -e "$LA/io.github.gitzilla.org-acme.rotate.plist" ] && echo yes || echo no)" "profile install: no profile rotate job"

# --- 5. the runtime scripts in a profile, with the launchd jobs' environment, never touch the personal files: the
# personal entries are unreadable for the runs (chmod 000; the personal dirs themselves 111, so only the profile
# directories inside them can be reached), and the personal snapshots are compared afterwards.
make_test_key
export STUB_EVENTS="$T/events.json"
start_stub
rm -rf "$HOME/.config" "$HOME/.local" "$HOME/Library"
mkdir -p "$PC" "$PS/mirrors/alice__x.git" "$PS/log" "$PS/incidents"
printf 'OWNER=Alice\nGITZILLA_URL=http://127.0.0.1:1\nNOTE_PUBKEY_FILE=%s\n' "$PC/push-note.pub" > "$PC/config"
echo personal-pub > "$PC/push-note.pub"
for f in repos.txt seeded.txt heads.json queue-cursor known-keys.txt rotation.json reconcile-seen.json; do echo "personal $f" > "$PS/$f"; done
echo old > "$PS/log/gitzilla.log"
PPC="$PC/org-acme"; PPS="$PS/org-acme"
mkdir -p "$PPC" "$PPS/incidents"
printf 'OWNER=Acme\nGITZILLA_URL=%s\nNOTE_PUBKEY_FILE=%s\nTZ_LOCAL=UTC\n' "$STUB_URL" "$T/key.pub" > "$PPC/config"
echo "acme/app public" > "$PPS/repos.txt"
# the org's repository on "GitHub" (a local bare repo)
git init -q --bare "$T/remotes/acme/app.git"
git init -q -b main "$T/work"; echo one > "$T/work/f"; git -C "$T/work" add f; git -C "$T/work" commit -q -m one
git -C "$T/work" push -q "$T/remotes/acme/app.git" main
C1="$(git -C "$T/work" rev-parse HEAD)"
S9=9999999999999999999999999999999999999999
# stubs the runtime scripts call
printf '#!/bin/sh\necho "$1|$2" >> "%s/rt-notify.log"\n' "$T" > "$S/rt-notify"
printf '#!/bin/sh\necho "$1" >> "%s/rt-lsr.log"\nprintf "%s\\trefs/heads/main\\n"\n' "$T" "$S9" > "$S/rt-lsr"
printf '#!/bin/sh\necho probe >> "%s/rt-probe.log"\necho "Hi acme! You'"'"'ve successfully authenticated"\nexit 1\n' "$T" > "$S/rt-probe"
printf '#!/bin/sh\nprintf 404\n' > "$S/rt-curl"
printf '#!/bin/sh\necho "$1|$2" >> "%s/rt-terminal.log"\n' "$T" > "$S/rt-terminal"
printf '#!/bin/sh\necho "Rotate now"\n' > "$S/rt-dialog"
printf '#!/bin/sh\necho "$@" >> "%s/rt-restore.log"\n' "$T" > "$S/rt-restore"
printf '#!/bin/sh\nexit 0\n' > "$S/rt-scan"
chmod +x "$S"/rt-*
snap "$PC" > "$T/pc.before"; snap "$PS" > "$T/ps.before"
lock_personal() {
  find "$PC" "$PS" -mindepth 1 -maxdepth 1 ! -name org-acme -exec chmod 000 {} +
  chmod 111 "$PC" "$PS"
}
unlock_personal() {
  chmod 755 "$PC" "$PS"
  find "$PC" "$PS" -mindepth 1 -maxdepth 1 ! -name org-acme -exec chmod u+rwx {} +
}
# lrun <cmd...>: what a profile launchd job gets (PATH, both directories and GITZILLA_PROFILE), plus the test stubs
lrun() {
  env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
    GITZILLA_PROFILE=org-acme GITZILLA_STATE_DIR="$PPS" GITZILLA_CONFIG_DIR="$PPC" \
    GITZILLA_SIGN_KEY="$T/key" ALLOWED_SIGNERS_FILE="$T/allowed_signers" GITZILLA_REMOTE_URL_TEMPLATE="$T/remotes/%s.git" \
    GITZILLA_NOTIFY_CMD="$S/rt-notify" GITZILLA_GIT_LS_REMOTE="$S/rt-lsr" GITZILLA_SSH_PROBE="$S/rt-probe" \
    GITZILLA_CURL="$S/rt-curl" GITZILLA_TERMINAL_CMD="$S/rt-terminal" GITZILLA_DIALOG_CMD="$S/rt-dialog" \
    GITZILLA_RESTORE_CMD="$S/rt-restore" GITZILLA_SCAN_CMD="$S/rt-scan" \
    "$@" >"$T/out" 2>&1 </dev/null
}
trap 'unlock_personal 2>/dev/null; stop_stub; rm -rf "$T"' EXIT # a failed run must not leave undeletable dirs
lock_personal
# install's mirrors step with the real reconcile seed (the profile's mirror, seeded.txt and heads.json)
env -i HOME="$HOME" PATH="$PATH" TMPDIR="$TMPDIR" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
  GITZILLA_PROFILE=org-acme GITZILLA_REMOTE_URL_TEMPLATE="$T/remotes/%s.git" GITZILLA_INSTALL_STOP_AFTER=mirrors \
  bash "$INSTALL" --from-step mirrors >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "runtime: mirrors step in the profile ok ($(tail -n1 "$T/out"))"
assert_eq "$C1" "$(git --git-dir="$PPS/mirrors/acme__app.git" rev-parse -q --verify refs/heads/main 2>/dev/null)" "runtime: mirror in the profile"
assert_eq acme/app "$(cat "$PPS/seeded.txt" 2>/dev/null)" "runtime: seeded.txt in the profile"
assert_eq "$C1" "$(jq -r '."acme/app"["refs/heads/main"]' "$PPS/heads.json" 2>/dev/null)" "runtime: seeded heads.json in the profile"
# agent poll + health (the agent job): a silent push moves the profile's heads.json and queue cursor
jq -cn --arg b "$C1" --arg a "$S9" '[{seq:1,delivery:"d1",ts:1760000000,kind:"push",repo:"acme/app",ref:"refs/heads/main",before:$b,after:$a,forced:false,level:"silent",flags:[]}]' > "$STUB_EVENTS"
: > "$STUB_LOG"
lrun bash -c '"$1/bin/agent" poll; "$1/bin/agent" health' _ "$WD_ROOT"
assert_eq 0 "$?" "runtime: agent poll + health in the profile ok ($(tail -n1 "$T/out"))"
assert_eq 1 "$(cat "$PPS/queue-cursor" 2>/dev/null)" "runtime: agent cursor in the profile"
assert_eq "$S9" "$(jq -r '."acme/app"["refs/heads/main"]' "$PPS/heads.json" 2>/dev/null)" "runtime: agent heads.json in the profile"
assert_contains "$(jq -r .path "$STUB_LOG" | sort -u | tr '\n' ' ')" "/queue?after=0" "runtime: agent polled the profile's Worker"
# reconcile public + all (the reconcile job): a moved ref is a first strike in the profile's reconcile-seen.json
git --git-dir="$PPS/mirrors/acme__app.git" update-ref refs/heads/main "$C1"
jq --arg c "$C1" '."acme/app"["refs/heads/main"] = $c' "$PPS/heads.json" > "$T/h" && mv "$T/h" "$PPS/heads.json"
lrun bash -c '"$1/bin/reconcile" public && "$1/bin/reconcile" all' _ "$WD_ROOT"
assert_eq 0 "$?" "runtime: reconcile public + all in the profile ok ($(tail -n1 "$T/out"))"
assert_contains "$(cat "$T/rt-lsr.log" 2>/dev/null)" "acme/app" "runtime: reconcile checked the profile's repo"
assert_eq "$S9" "$(jq -r '."acme/app|refs/heads/main".sha' "$PPS/reconcile-seen.json" 2>/dev/null)" "runtime: reconcile-seen.json in the profile"
[ -s "$PPS/reconcile-all-at" ] && _ok || _bad "runtime: reconcile-all-at in the profile"
# restore (the agent hands it critical pushes): the result goes next to the profile's incident, the report to its Worker
jq -cn --arg b "$C1" --arg a "$S9" '[{seq:2,delivery:"d2",ts:1760000000,kind:"push",repo:"acme/app",ref:"refs/heads/main",before:$b,after:$a,forced:true,level:"critical",flags:["unsigned"]}]' > "$PPS/incidents/2.json"
: > "$STUB_LOG"
lrun bash "$WD_ROOT/bin/restore" --yes "$PPS/incidents/2.json"
assert_eq 0 "$?" "runtime: restore in the profile ok ($(tail -n1 "$T/out"))"
assert_eq "acme/app" "$(jq -r '(.restored + .skipped)[0].repo' "$PPS/incidents/2.json.result.json" 2>/dev/null)" "runtime: restore result in the profile"
assert_contains "$(jq -r .path "$STUB_LOG" | tr '\n' ' ')" "/report" "runtime: restore reported to the profile's Worker"
# rotate (the job is not installed in a profile; run directly it refuses before reading anything)
for m in check gh ssh; do
  lrun bash "$WD_ROOT/bin/rotate" "$m"
  assert_eq 1 "$?" "runtime: rotate $m refuses in a profile"
  assert_contains "$(cat "$T/out")" "rotation belongs to the personal profile" "runtime: rotate $m says why"
done
assert_eq no "$([ -e "$PPS/rotation.json" ] || [ -e "$PPS/rotate.lock" ] || [ -e "$T/rt-terminal.log" ] && echo yes || echo no)" "runtime: rotate wrote nothing, opened no Terminal"
unlock_personal
assert_eq "" "$(find "$PPS" "$PPC" ! -perm -u+r 2>/dev/null)" "runtime: profile files all readable (nothing tried to reach a personal one)"
snap "$PC" > "$T/pc.after"; snap "$PS" > "$T/ps.after"
assert_eq "$(cat "$T/pc.before")" "$(cat "$T/pc.after")" "runtime: personal config untouched"
assert_eq "$(cat "$T/ps.before")" "$(cat "$T/ps.after")" "runtime: personal state untouched"
finish
