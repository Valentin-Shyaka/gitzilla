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

# --- 2. invalid profiles die (names that would land inside a personal directory are refused too)
for bad in Org -x a_b a.b "a/b" .. "a b" "${P40}1" "org-acme
x" log mirrors incidents; do
  o="$(GITZILLA_PROFILE="$bad" bash -c '. "$1"; echo SURVIVED' _ "$LIB" 2>&1)"; rc=$?
  [ "$rc" -ne 0 ] && _ok || _bad "invalid profile '$bad' must fail"
  case "$o" in *SURVIVED*) _bad "invalid profile '$bad': lib must stop" ;; *) _ok ;; esac
  assert_contains "$o" "GITZILLA_PROFILE" "invalid profile '$bad': says which setting"
done
assert_eq no "$([ -e "$HOME/.config/gitzilla" ] || [ -e "$HOME/.local/state/gitzilla" ] && echo yes || echo no)" "invalid profile: nothing created"
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
  "repo list") echo '[{"nameWithOwner":"alice/app","visibility":"PRIVATE"}]' ;;
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
GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=launchd bash "$INSTALL" --from-step launchd >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "profile launchd ok"
for j in agent reconcile rotate; do
  label="io.github.gitzilla.org-acme.$j"; p="$LA/$label.plist"
  plutil -lint "$p" >/dev/null 2>&1 && _ok || _bad "profile $j: plutil -lint"
  assert_eq "$label" "$(plutil -extract Label raw "$p")" "profile $j: label"
  assert_eq org-acme "$(plutil -extract EnvironmentVariables.GITZILLA_PROFILE raw "$p")" "profile $j: GITZILLA_PROFILE"
  assert_eq "$PS/org-acme" "$(plutil -extract EnvironmentVariables.GITZILLA_STATE_DIR raw "$p")" "profile $j: state dir"
  assert_eq "$PC/org-acme" "$(plutil -extract EnvironmentVariables.GITZILLA_CONFIG_DIR raw "$p")" "profile $j: config dir"
  assert_eq "$PS/org-acme/log/$j.out" "$(plutil -extract StandardOutPath raw "$p")" "profile $j: log path"
done
assert_eq 0 "$(grep -c 'io\.github\.gitzilla\.\(agent\|reconcile\|rotate\)' "$T/launchctl.log")" "profile: personal labels never booted out or bootstrapped"
assert_eq 6 "$(grep -E '^(bootout|bootstrap) ' "$T/launchctl.log" | grep -c 'io\.github\.gitzilla\.org-acme\.')" "profile: bootout + bootstrap for each profile job"
diff -r "$T/la.personal" "$LA" 2>/dev/null | grep -v "^Only in $LA: io.github.gitzilla.org-acme" | grep -q . && _bad "profile: personal plists changed" || _ok

# --- 4. a profile install leaves the personal config and state untouched
rm -rf "$HOME/.config" "$HOME/.local" "$HOME/Library" "$T/secrets"; mkdir -p "$T/secrets"
mkdir -p "$PC" "$PS/mirrors/alice__x.git" "$PS/log"
printf 'OWNER=Alice\nGITZILLA_URL=https://gitzilla.alice.workers.dev\n' > "$PC/config"; echo personal-pub > "$PC/push-note.pub"
echo "alice/x private" > "$PS/repos.txt"; echo self-test > "$PS/install-step"; echo 42 > "$PS/queue-cursor"; echo old > "$PS/log/gitzilla.log"
snap() { (cd "$1" && find . -path "./org-acme" -prune -o -print | LC_ALL=C sort | while read -r f; do
  if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(shasum "$f" | cut -d' ' -f1)"; else printf '%s dir\n' "$f"; fi; done); }
snap "$PC" > "$T/pc.before"; snap "$PS" > "$T/ps.before"
printf '\n\n\n' | GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=worker bash "$INSTALL" --from-step note-key >"$T/out" 2>&1
assert_eq 0 "$?" "profile install: note-key + worker ok"
case "$(cat "$T/out")" in *KEEP*) _bad "profile install: the personal config must not make it ask keep/rotate" ;; *) _ok ;; esac
assert_eq "$(head -n1 "$T/notekey.pub")" "$(head -n1 "$PC/org-acme/push-note.pub")" "profile install: note key saved in the profile"
assert_eq "https://gitzilla.acme.workers.dev" "$( . "$PC/org-acme/config"; echo "$GITZILLA_URL")" "profile install: config in the profile"
assert_eq "$PC/org-acme/push-note.pub" "$( . "$PC/org-acme/config"; echo "$NOTE_PUBKEY_FILE")" "profile install: config points at the profile key"
assert_eq worker "$(cat "$PS/org-acme/install-step")" "profile install: progress in the profile state"
GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=repos bash "$INSTALL" --from-step repos >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "profile install: repos ok"
assert_eq "alice/app private" "$(cat "$PS/org-acme/repos.txt" 2>/dev/null)" "profile install: repos.txt in the profile"
GITZILLA_PROFILE=org-acme GITZILLA_INSTALL_STOP_AFTER=launchd bash "$INSTALL" --from-step launchd >"$T/out" 2>&1 </dev/null
assert_eq 0 "$?" "profile install: launchd ok"
# the hook step refuses in a profile and changes nothing
GITZILLA_PROFILE=org-acme bash "$INSTALL" --from-step hook >"$T/out" 2>&1 </dev/null
assert_eq 1 "$?" "profile install: hook step refuses"
assert_contains "$(cat "$T/out")" "the hook is installed by the personal profile" "profile install: says why"
assert_eq "" "$(git config --global --get core.hooksPath)" "profile install: core.hooksPath untouched"
assert_eq no "$([ -e "$HOME/.config/git" ] || [ -e "$T/node-path" ] || [ -e "$PC/org-acme/jq-path" ] && echo yes || echo no)" "profile install: no hook files written"
assert_eq launchd "$(cat "$PS/org-acme/install-step")" "profile install: refused hook step not recorded"
snap "$PC" > "$T/pc.after"; snap "$PS" > "$T/ps.after"
assert_eq "$(cat "$T/pc.before")" "$(cat "$T/pc.after")" "profile install: personal config untouched"
assert_eq "$(cat "$T/ps.before")" "$(cat "$T/ps.after")" "profile install: personal state untouched"
assert_eq no "$([ -e "$LA/io.github.gitzilla.agent.plist" ] && echo yes || echo no)" "profile install: no personal launchd job written"
finish
