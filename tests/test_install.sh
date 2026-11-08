#!/usr/bin/env bash
# install.sh tests. Temp HOME/STATE/CONFIG; every external command (gh, npm, npx/wrangler, open, launchctl, curl,
# pbpaste, reconcile, rotate) is a stub. plutil is real (read-only lint). Nothing here touches the real HOME.
. "$(dirname "$0")/helpers.sh"
STATE="$GITZILLA_STATE_DIR"
INSTALL="$WD_ROOT/install.sh"
S="$T/stubs"; mkdir -p "$S" "$T/secrets"
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
mkdir -p "$T/Secretive.app"

export GITZILLA_GH_CMD="$S/gh" GITZILLA_NPM_CMD="$S/npm" GITZILLA_NPX_CMD="$S/npx" GITZILLA_OPEN_CMD="$S/open"
export GITZILLA_PBPASTE_CMD="$S/pbpaste" GITZILLA_CURL="$S/curl" GITZILLA_LAUNCHCTL_CMD="$S/launchctl"
export GITZILLA_RECONCILE_CMD="$S/reconcile" GITZILLA_ROTATE_CMD="$S/rotate" GITZILLA_SECRETIVE_APP="$T/Secretive.app"
export GITZILLA_RM_CMD="$S/rm" GITZILLA_LAUNCHD_POLL=0 GITZILLA_LAUNCHD_RETRY=0
export GITZILLA_REMOTE_URL_TEMPLATE="$T/remote/%s.git" GITZILLA_POLL_INTERVAL=0 GITZILLA_POLL_TIMEOUT=0
ln -s /var/db/timezone/zoneinfo/Europe/Paris "$T/localtime"
export GITZILLA_LOCALTIME="$T/localtime"
export GITZILLA_NODE_PATH_FILE="$T/node-path" # never write scanner/node-path into the real clone
[ -n "$NODE_BIN" ] && export PATH="$(dirname "$NODE_BIN"):$PATH"

cat > "$S/gh" <<STUB
#!/bin/sh
echo "\$*" >> "$T/gh.log"
case "\$1 \$2" in
  "auth status") [ -f "$T/gh.noauth" ] && exit 1; exit 0 ;;
  "api user") if [ -f "$T/gh.login" ]; then cat "$T/gh.login"; else echo Alice; fi ;;
  "repo list") cat "$T/gh.repos" ;;
  "repo view") [ -f "$T/gh.norepo" ] && exit 1; exit 0 ;;
  "repo create") [ -f "$T/gh.createfail" ] && exit 1; rm -f "$T/gh.norepo"; exit 0 ;;
esac
STUB
cat > "$S/npm" <<STUB
#!/bin/sh
echo "npm \$* (cwd \$(pwd))" >> "$T/npm.log"
STUB
cat > "$S/npx" <<STUB
#!/bin/sh
echo "npx \$*" >> "$T/npx.log"
case "\$2" in
  login) ;;
  deploy) echo "Uploaded gitzilla"; echo "Deployed gitzilla triggers"; [ -f "$T/deploy.nourl" ] || echo "  https://gitzilla.alice.workers.dev" ;;
  secret) cat > "$T/secrets/\$4" ;;
  logout) [ -f "$T/tokens.stay" ] || rm -f "\$HOME/.wrangler/config/default.toml"; [ -f "$T/logout.fail" ] && exit 1 ;;
esac
exit 0
STUB
cat > "$S/open" <<STUB
#!/bin/sh
echo "\$*" >> "$T/open.log"
STUB
cat > "$S/pbpaste" <<STUB
#!/bin/sh
cat "$T/clip"
STUB
cat > "$S/launchctl" <<STUB
#!/bin/sh
echo "\$*" >> "$T/launchctl.log"
case "\$1" in
  bootout) echo "Boot-out failed: 3: No such process" >&2; exit 3 ;;
  print) n=\$(cat "$T/lc.print.left" 2>/dev/null || echo 0); [ "\$n" -gt 0 ] || exit 113; echo \$((n - 1)) > "$T/lc.print.left"; exit 0 ;;
  bootstrap) if [ -f "$T/lc.bootstrap.fail" ]; then rm -f "$T/lc.bootstrap.fail"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; fi ;;
esac
exit 0
STUB
cat > "$S/reconcile" <<STUB
#!/bin/sh
echo "\$* | mirrors: \$(ls "$STATE/mirrors" 2>/dev/null | tr '\n' ' ')" >> "$T/reconcile.log"
[ -f "$T/reconcile.fail" ] && exit 1
exit 0
STUB
cat > "$S/rotate" <<STUB
#!/bin/sh
echo "\$*" >> "$T/rotate.log"
STUB
cat > "$S/curl" <<STUB
#!/bin/sh
out=""; url=""; auth=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; -H) auth="\$2"; shift ;; --max-time|-w) shift ;; -*) ;; *) url="\$1" ;; esac; shift; done
echo "\$url" >> "$T/curl.log"
case "\$url" in
  https://github.com/alice.keys) f="$T/curl/auth.keys" ;;
  "https://api.github.com/users/alice/ssh_signing_keys?per_page=100") f="$T/curl/signing.json" ;;
  https://gitzilla.alice.workers.dev/queue*)
    echo "\$auth" >> "$T/queue.auth"; echo "\$url" >> "$T/queue.urls"
    [ -f "$T/curl/queue.json" ] || { printf 404; exit 0; }
    n=\$(( \$(wc -l < "$T/queue.urls") )); a="\${url##*after=}"
    ev="\$(cat "$T/curl/queue.json")"
    if [ -f "$T/curl/late.json" ] && [ "\$n" -gt "\$(cat "$T/curl/late.after")" ]; then ev="\$(jq -sc '.[0] + .[1]' "$T/curl/queue.json" "$T/curl/late.json")"; fi
    printf '%s' "\$ev" | jq -c --argjson a "\$a" --argjson p "\$(cat "$T/curl/qpage" 2>/dev/null || echo 100)" \
      '{events:([.[]|select(.seq>\$a)]|.[:\$p])} | .next=(if (.events|length)>0 then .events[-1].seq else \$a end)' > "\$out"
    printf 200; exit 0 ;;
  *) printf 404; exit 0 ;;
esac
[ -f "\$f" ] || { printf 404; exit 0; }
cp "\$f" "\$out"; printf 200
STUB
cat > "$S/rm" <<STUB
#!/bin/sh
echo "\$*" >> "$T/rm.log"
[ -f "$T/rm.noop" ] && exit 0
exec /bin/rm "\$@"
STUB
chmod +x "$S"/*
mkdir -p "$T/curl" "$T/remote"

run() { bash "$INSTALL" "$@" >"$T/out" 2>&1 </dev/null; echo $? > "$T/rc"; }
runin() { local in="$1"; shift; printf "$in" | bash "$INSTALL" "$@" >"$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
out() { cat "$T/out"; }
step_file() { cat "$STATE/install-step" 2>/dev/null; }
nmatch() { [ -f "$2" ] && { grep -c -- "$1" "$2" || true; } || echo 0; }
reset() {
  rm -f "$T/key" "$T/key.pub"; rm -rf "$STATE" "$GITZILLA_CONFIG_DIR" "$HOME" "$T/remote" "$T/secrets" "$T/curl" "$T/work"
  rm -f "$T"/queue.urls "$T"/lc.* "$T"/rm.noop "$T"/logout.fail "$T"/*.log "$T"/*.flag "$T"/*.nourl "$T"/*.stay "$T"/*.noauth "$T"/*.fail "$T"/queue.auth "$T"/clip "$T"/gh.repos "$T"/gh.login "$T"/gh.norepo "$T"/gh.createfail
  git config --global --unset core.hooksPath 2>/dev/null || true
  git config --global --unset gpg.ssh.allowedSignersFile 2>/dev/null || true
  git config --global --unset-all include.path 2>/dev/null || true
  rm -f "$T/node-path"
  mkdir -p "$STATE" "$GITZILLA_CONFIG_DIR" "$HOME" "$T/remote" "$T/secrets" "$T/curl"
}
# a pre-push hook in the shape of the real polin-guard one
make_hook() {
  mkdir -p "$HOME/.config/git/hooks"
  cat > "$HOME/.config/git/hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
. "$HOME/.config/git/hooks/_lib.sh"
block_if_quarantined push
input="$(cat)"
while read -r lref lsha rref rsha; do
  bash "$SCAN" range "$base" "$lsha" || { echo "polin-guard: push of $lref BLOCKED." >&2; exit 1; }
done <<< "$input"
own="$GIT_DIR_ABS/hooks/pre-push"
[ -x "$own" ] && { printf '%s\n' "$input" | "$own" "$@"; exit $?; }
exit 0
HOOK
  chmod 755 "$HOME/.config/git/hooks/pre-push"
  git config --global core.hooksPath '~/.config/git/hooks'
}
mk_ghauth() { mkkey ghauth; mkdir -p "$HOME/.ssh"; cp "$T/keys/ghauth.pub" "$HOME/.ssh/github-auth.pub"; }
write_config() {
  cat > "$GITZILLA_CONFIG_DIR/config" <<CFG
OWNER=Alice
GITZILLA_URL=https://gitzilla.alice.workers.dev
NOTE_PUBKEY_FILE=$GITZILLA_CONFIG_DIR/push-note.pub
CFG
}
mkbare() { # slug -> local bare repo with one commit
  local slug="$1" d="$T/remote/$1.git" w="$T/work/${1//\//__}"
  mkdir -p "$(dirname "$d")" "$T/work"
  git init -q --bare -b main "$d"
  git init -q -b main "$w"
  git -C "$w" commit -q --allow-empty -m init
  git -C "$w" push -q "$d" main
}
mk_sign_key() { rm -f "$T/key" "$T/key.pub"; make_test_key; }
mkkey() { # name type -> $T/keys/name(.pub)
  mkdir -p "$T/keys"; rm -f "$T/keys/$1" "$T/keys/$1.pub"; ssh-keygen -q -t "${2:-ed25519}" -N '' -C "$1" -f "$T/keys/$1" >/dev/null
}

# --- 1. argument handling
reset
run --from-step bogus
assert_eq 2 "$(rc)" "unknown step: exit 2"
assert_contains "$(out)" "prereqs note-key worker github-app hook repos mirrors known-keys launchd first-rotation self-test" "unknown step lists valid names"
assert_eq "" "$(step_file)" "unknown step: no state written"
run --from-step
assert_eq 2 "$(rc)" "--from-step without a name: exit 2"

# --- 2. prereqs
reset
GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
assert_eq 1 "$(rc)" "prereqs: missing ~/.ssh/github-auth.pub fails"
assert_contains "$(out)" "~/.ssh/github-auth.pub" "prereqs: names the missing key file"
assert_contains "$(out)" "Secretive" "prereqs: says to create the key in Secretive"
assert_contains "$(out)" "Authentication key" "prereqs: says to add it on GitHub as an Authentication key"
assert_contains "$(out)" "IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh" "prereqs: shows the ssh config IdentityAgent line"
assert_contains "$(out)" "IdentityFile ~/.ssh/github-auth.pub" "prereqs: shows the ssh config IdentityFile line"
assert_eq "" "$(step_file)" "prereqs: not recorded without the key"
mkdir -p "$HOME/.ssh"; echo "not a key" > "$HOME/.ssh/github-auth.pub"
GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
assert_eq 1 "$(rc)" "prereqs: a github-auth.pub that is not a public key fails"
mk_ghauth
GITZILLA_INSTALL_STOP_AFTER=prereqs run
assert_eq 0 "$(rc)" "prereqs ok"
assert_contains "$(out)" "WARNING: no allowed-signers file at $HOME/.config/git/allowed_signers" "prereqs: warns when allowed_signers is missing (not fatal)"
assert_contains "$(out)" "red alert" "prereqs: warning says un-noted pushes turn red"
assert_contains "$(out)" "README" "prereqs: warning points at the README"
mkdir -p "$HOME/.config/git"; echo "x" > "$HOME/.config/git/allowed_signers"
GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
assert_eq 0 "$(rc)" "prereqs ok with the default allowed_signers"
case "$(out)" in *"allowed-signers"*) _bad "prereqs: no warning when the default file exists" ;; *) _ok ;; esac
git config --global gpg.ssh.allowedSignersFile '~/elsewhere/signers'
GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
assert_contains "$(out)" "WARNING: no allowed-signers file at $HOME/elsewhere/signers" "prereqs: follows gpg.ssh.allowedSignersFile (~ expanded)"
mkdir -p "$HOME/elsewhere"; echo x > "$HOME/elsewhere/signers"
GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
case "$(out)" in *"allowed-signers"*) _bad "prereqs: no warning when the configured file exists" ;; *) _ok ;; esac
git config --global --unset gpg.ssh.allowedSignersFile
GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
assert_eq prereqs "$(step_file)" "prereqs recorded"
touch "$T/gh.noauth"
GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
assert_eq 1 "$(rc)" "prereqs: gh not logged in fails"
rm -f "$T/gh.noauth"
GITZILLA_SECRETIVE_APP="$T/nope.app" GITZILLA_INSTALL_STOP_AFTER=prereqs run --from-step prereqs
assert_eq 1 "$(rc)" "prereqs: Secretive missing fails"

# --- 3. note-key
reset
mk_ghauth
mkkey notekey ecdsa
cp "$T/keys/notekey.pub" "$T/clip"
GITZILLA_INSTALL_STOP_AFTER=note-key runin '\n'
assert_eq 0 "$(rc)" "note-key ok"
assert_eq "$(head -n1 "$T/keys/notekey.pub")" "$(head -n1 "$GITZILLA_CONFIG_DIR/push-note.pub")" "note-key: public key saved"
assert_contains "$(out)" "Not Required" "note-key: guide says no authentication"
reset
echo "not a key" > "$T/clip"
GITZILLA_INSTALL_STOP_AFTER=note-key runin '\n' --from-step note-key
assert_eq 1 "$(rc)" "note-key: garbage clipboard rejected"
assert_eq "" "$(step_file)" "note-key: not recorded on failure"

# --- 4. worker: deploy, secrets never on disk, config, wrangler logout check
reset
mkkey notekey ecdsa
cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
SLACK="https://hooks.slack.com/services/T000/B000/SLACKSECRETVALUE"
mkdir -p "$HOME/.wrangler/config"; echo 'oauth_token = "x"' > "$HOME/.wrangler/config/default.toml"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 0 "$(rc)" "worker ok"
assert_eq worker "$(step_file)" "worker recorded"
WSEC="$(cat "$T/secrets/WEBHOOK_SECRET")"; NTFY="$(cat "$T/secrets/NTFY_TOPIC")"
assert_eq 64 "${#WSEC}" "worker: WEBHOOK_SECRET is 32 random bytes hex, piped via stdin"
case "$NTFY" in wd-????????????????????????????????) _ok ;; *) _bad "worker: NTFY_TOPIC format ($NTFY)" ;; esac
assert_eq "$SLACK" "$(cat "$T/secrets/SLACK_WEBHOOK_URL")" "worker: Slack URL piped to secret put"
assert_contains "$(out)" "$WSEC" "worker: webhook secret printed once"
assert_contains "$(out)" "$NTFY" "worker: ntfy topic printed once"
case "$(out)" in *SLACKSECRETVALUE*) _bad "worker: Slack URL must not be echoed" ;; *) _ok ;; esac
assert_contains "$(cat "$T/npx.log")" "deploy --var NOTE_PUBKEY:$(head -n1 "$GITZILLA_CONFIG_DIR/push-note.pub")" "worker: deploy passes NOTE_PUBKEY"
assert_contains "$(cat "$T/npm.log")" "npm ci (cwd $WD_ROOT/worker)" "worker: npm ci in worker/"
assert_eq 1 "$(nmatch 'login' "$T/npx.log")" "worker: wrangler login ran"
assert_eq 1 "$(nmatch 'logout' "$T/npx.log")" "worker: wrangler logout ran"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "GITZILLA_URL=https://gitzilla.alice.workers.dev" "worker: config URL parsed from deploy output"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "OWNER=Alice" "worker: config OWNER"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "NOTE_PUBKEY_FILE=$GITZILLA_CONFIG_DIR/push-note.pub" "worker: config NOTE_PUBKEY_FILE"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "GITZILLA_HOME=$WD_ROOT" "worker: config GITZILLA_HOME"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "APP_NAME=gitzilla-alice" "worker: config APP_NAME from the lower-cased login"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "DRILL_REPO=gitzilla-drill" "worker: config DRILL_REPO default"
assert_contains "$(cat "$T/npx.log")" "deploy --var NOTE_PUBKEY:$(head -n1 "$GITZILLA_CONFIG_DIR/push-note.pub") --var ALERT_TZ:Europe/Paris" "worker: deploy passes ALERT_TZ from /etc/localtime"
assert_contains "$(cat "$GITZILLA_CONFIG_DIR/config")" "ALERT_TZ=Europe/Paris" "worker: config ALERT_TZ"
assert_eq 600 "$(stat -f %Lp "$GITZILLA_CONFIG_DIR/config")" "worker: config mode 600"
hit="$(grep -rlE "$WSEC|$NTFY|SLACKSECRETVALUE" "$HOME" "$STATE" "$GITZILLA_CONFIG_DIR" 2>/dev/null)"
assert_eq "" "$hit" "worker: no secret value in any file under HOME/STATE/CONFIG"
case "$(cat "$GITZILLA_CONFIG_DIR/config")" in *secret*|*SECRET*|*"$WSEC"*) _bad "worker: config holds a secret" ;; *) _ok ;; esac

# worker fails while a wrangler credential remains (either location)
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
mkdir -p "$HOME/.wrangler/config"; echo 'oauth_token = "x"' > "$HOME/.wrangler/config/default.toml"; touch "$T/tokens.stay"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 1 "$(rc)" "worker: fails when ~/.wrangler still has oauth_token"
assert_contains "$(out)" "$HOME/.wrangler/config/default.toml" "worker: names the offending file"
assert_eq "" "$(step_file)" "worker: not recorded on failure"
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
mkdir -p "$HOME/Library/Preferences/.wrangler/config"; echo 'refresh_token = "x"' > "$HOME/Library/Preferences/.wrangler/config/default.toml"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 1 "$(rc)" "worker: fails on a leftover refresh_token in Library/Preferences"
# no workers.dev URL
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"; touch "$T/deploy.nourl"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 1 "$(rc)" "worker: dies without a workers.dev URL"
assert_eq 0 "$([ -f "$GITZILLA_CONFIG_DIR/config" ] && echo 1 || echo 0)" "worker: no config written"
# die paths also check for leftover credentials
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"; touch "$T/deploy.nourl" "$T/tokens.stay"
mkdir -p "$HOME/.wrangler/config"; echo 'oauth_token = "x"' > "$HOME/.wrangler/config/default.toml"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_contains "$(out)" "credentials remain in: $HOME/.wrangler/config/default.toml" "worker: die path reports leftover credentials"
rm -f "$T/deploy.nourl"
# XDG location checked
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"; touch "$T/tokens.stay"
mkdir -p "$T/xdg/.wrangler/config"; echo 'api_token = "x"' > "$T/xdg/.wrangler/config/default.toml"
XDG_CONFIG_HOME="$T/xdg" GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 1 "$(rc)" "worker: fails on a leftover api_token under XDG_CONFIG_HOME"
assert_contains "$(out)" "$T/xdg/.wrangler/config/default.toml" "worker: names the XDG file"
rm -f "$T/tokens.stay"
# non-zero wrangler logout is a failure
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"; touch "$T/logout.fail"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 1 "$(rc)" "worker: failing wrangler logout fails the step"
assert_contains "$(out)" "logout failed" "worker: says logout failed"
rm -f "$T/logout.fail"
# rerun: keep (default) vs rotate; a fresh install asks nothing
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
case "$(out)" in *"KEEP"*) _bad "worker: a fresh install must not ask keep/rotate" ;; *) _ok ;; esac
assert_eq 3 "$(nmatch 'secret put' "$T/npx.log")" "worker: fresh install puts three secrets"
W1="$(cat "$T/secrets/WEBHOOK_SECRET")"; : > "$T/npx.log"; rm -rf "$T/secrets"; mkdir -p "$T/secrets"
GITZILLA_INSTALL_STOP_AFTER=worker runin '\n' --from-step worker
assert_eq 0 "$(rc)" "worker rerun (keep) ok"
assert_contains "$(out)" "KEEP" "worker rerun asks"
assert_eq 0 "$(nmatch 'secret' "$T/npx.log")" "worker keep: no secret put"
assert_contains "$(cat "$T/npx.log")" "deploy --var NOTE_PUBKEY:" "worker keep: still redeploys with NOTE_PUBKEY"
assert_eq 0 "$([ -e "$STATE/install-secrets-rotated" ] && echo 1 || echo 0)" "worker keep: no rotated marker"
: > "$T/npx.log"
GITZILLA_INSTALL_STOP_AFTER=worker runin 'r\n' --from-step worker
assert_eq 0 "$(nmatch 'secret' "$T/npx.log")" "worker: typing just 'r' keeps"
printf 'rotate\n%s\n' "$SLACK" > "$T/in.rotate"
: > "$T/npx.log"
echo github-app > "$STATE/install-step"
GITZILLA_INSTALL_STOP_AFTER=worker bash "$INSTALL" --from-step worker < "$T/in.rotate" >"$T/out" 2>&1; echo $? > "$T/rc"
assert_eq 0 "$(rc)" "worker rotate ok"
assert_eq 3 "$(nmatch 'secret put' "$T/npx.log")" "worker rotate: three secrets put"
assert_eq 1 "$([ -e "$STATE/install-secrets-rotated" ] && echo 1 || echo 0)" "worker rotate: marker recorded"
[ "$(cat "$T/secrets/WEBHOOK_SECRET")" != "$W1" ] && _ok || _bad "worker rotate: new webhook secret"
case "$(out)" in *"lost it? rerun"*) _bad "no stale rerun hint" ;; *) _ok ;; esac
# resume past worker (install-step) also asks
echo github-app > "$STATE/install-step"; rm -f "$GITZILLA_CONFIG_DIR/config" "$STATE/install-secrets-rotated"; : > "$T/npx.log"
GITZILLA_INSTALL_STOP_AFTER=worker runin '\n' --from-step worker
assert_contains "$(out)" "KEEP" "worker: asks when install-step is past worker"
assert_eq 0 "$(nmatch 'secret' "$T/npx.log")" "worker: default keeps"
# config values are quoted (path with a space round-trips)
reset
WCD="$T/conf dir"; mkdir -p "$WCD"; mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$WCD/push-note.pub"
GITZILLA_CONFIG_DIR="$WCD" GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 0 "$(rc)" "worker with a space in the config dir ok"
assert_eq "$WCD/push-note.pub" "$( . "$WCD/config"; echo "$NOTE_PUBKEY_FILE")" "config: path with a space round-trips when sourced"
assert_eq "Alice" "$( . "$WCD/config"; echo "$OWNER")" "config: OWNER round-trips"
rm -f "$T/tokens.stay" "$T/deploy.nourl"

# Slack is optional: an empty URL skips its secret; a non-empty one must be https://
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_INSTALL_STOP_AFTER=worker runin '\n' --from-step worker
assert_eq 0 "$(rc)" "worker: empty Slack URL is accepted"
assert_eq 2 "$(nmatch 'secret put' "$T/npx.log")" "worker: empty Slack URL -> only two secrets put"
assert_eq 0 "$(nmatch 'SLACK_WEBHOOK_URL' "$T/npx.log")" "worker: empty Slack URL -> no SLACK_WEBHOOK_URL secret put"
assert_eq 0 "$([ -e "$T/secrets/SLACK_WEBHOOK_URL" ] && echo 1 || echo 0)" "worker: no Slack secret written"
assert_contains "$(out)" "Slack skipped" "worker: says Slack was skipped"
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_INSTALL_STOP_AFTER=worker runin 'http://hooks.slack.com/services/x\n' --from-step worker
assert_eq 1 "$(rc)" "worker: a non-https Slack URL fails"
assert_contains "$(out)" "must start with https://" "worker: says why"
assert_eq 0 "$(nmatch 'secret put' "$T/npx.log")" "worker: no secret put when the Slack URL is rejected"
# alert time zone: GITZILLA_ALERT_TZ wins, the config value is kept on a rerun, no usable zone -> UTC
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_ALERT_TZ=America/New_York GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_contains "$(grep deploy "$T/npx.log")" "--var ALERT_TZ:America/New_York" "worker: GITZILLA_ALERT_TZ passed to deploy"
assert_eq America/New_York "$( . "$GITZILLA_CONFIG_DIR/config"; echo "$ALERT_TZ")" "worker: GITZILLA_ALERT_TZ saved"
: > "$T/npx.log"
GITZILLA_INSTALL_STOP_AFTER=worker runin '\n' --from-step worker
assert_contains "$(grep deploy "$T/npx.log")" "--var ALERT_TZ:America/New_York" "worker rerun: ALERT_TZ kept from the config"
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_LOCALTIME="$T/no-such-localtime" GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_contains "$(grep deploy "$T/npx.log")" "--var ALERT_TZ:UTC" "worker: no /etc/localtime link -> UTC"
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_ALERT_TZ='Bad Zone;x' GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 0 "$(rc)" "worker: a malformed zone is not fatal"
assert_contains "$(grep deploy "$T/npx.log")" "--var ALERT_TZ:UTC" "worker: malformed zone -> UTC"
# drill repo: env override at install time, saved in the config; bad names refused
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_DRILL_REPO=my-drill GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 0 "$(rc)" "worker: GITZILLA_DRILL_REPO ok"
assert_eq my-drill "$( . "$GITZILLA_CONFIG_DIR/config"; echo "$DRILL_REPO")" "worker: DRILL_REPO from GITZILLA_DRILL_REPO"
GITZILLA_INSTALL_STOP_AFTER=worker runin '\n' --from-step worker
assert_eq my-drill "$( . "$GITZILLA_CONFIG_DIR/config"; echo "$DRILL_REPO")" "worker rerun: DRILL_REPO kept from the config"
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
GITZILLA_DRILL_REPO='bad/name' GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq 1 "$(rc)" "worker: a drill repo name with a slash is refused"
assert_eq 0 "$(nmatch 'deploy' "$T/npx.log")" "worker: refused before deploying"
# app name: gitzilla-<lower login>, at most 34 chars, no trailing hyphen after the cut
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
echo "Abcdefghijklmnopqrstuvwxyz-0123456789" > "$T/gh.login"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
AN="$( . "$GITZILLA_CONFIG_DIR/config"; echo "$APP_NAME")"
assert_eq gitzilla-abcdefghijklmnopqrstuvwxy "$AN" "worker: long login truncated to GitHub's 34-char app-name limit"
assert_eq 34 "${#AN}" "worker: app name is 34 chars"
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"
echo "Abcdefghijklmnopqrstuvwx-yz" > "$T/gh.login"
GITZILLA_INSTALL_STOP_AFTER=worker runin "$SLACK\n" --from-step worker
assert_eq gitzilla-abcdefghijklmnopqrstuvwx "$( . "$GITZILLA_CONFIG_DIR/config"; echo "$APP_NAME")" "worker: no trailing hyphen after truncation"

# --- 5. github-app
DL="$HOME/Downloads"
gh_app_setup() { reset; write_config; mk_sign_key; mkdir -p "$DL"; }
STALE='[{"seq":5,"repo":"alice/gitzilla-drill","ref":"refs/heads/old"}]'
# new push after the baseline -> pass; other apps' pems survive; "(1)" names deleted; cursor written
gh_app_setup
echo "$STALE" > "$T/curl/queue.json"
echo '[{"seq":6,"repo":"alice/gitzilla-drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 2 > "$T/curl/late.after"
echo PRIVATE > "$DL/gitzilla-alice.2026-11-03.private-key.pem"
echo PRIVATE > "$DL/gitzilla-alice.2026-11-03.private-key (1).pem"
echo OTHER > "$DL/other-app.2026.private-key.pem"
echo OLDNAME > "$DL/gitzilla-bob.2026.private-key.pem"
echo LONGER > "$DL/gitzilla-alice2.2026-11-03.private-key.pem"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\ny\n' --from-step github-app
assert_eq 0 "$(rc)" "github-app ok"
assert_contains "$(out)" "https://gitzilla.alice.workers.dev/webhook" "github-app: prints webhook URL"
assert_contains "$(out)" "Contents: Read-only" "github-app: prints permissions"
assert_contains "$(out)" "Subscribe to events: Push (installation events are sent to every app" "M9 github-app: prints events"
assert_contains "$(out)" "Only on this account" "github-app: prints install scope"
assert_contains "$(cat "$T/open.log")" "https://github.com/settings/apps/new" "github-app: opens the new-app page"
assert_contains "$(out)" "GitHub App name   : gitzilla-alice" "github-app: per-user app name"
assert_contains "$(out)" "https://github.com/settings/apps/gitzilla-alice/advanced" "github-app: existing-app URL uses the app name"
assert_eq "gitzilla-alice2.2026-11-03.private-key.pem
gitzilla-bob.2026.private-key.pem
other-app.2026.private-key.pem" "$(ls "$DL")" "github-app: only this app's pems deleted (incl. '(1)'); other apps' pems (incl. gitzilla-alice2) survive"
assert_contains "$(out)" "gitzilla-alice.2026-11-03.private-key (1).pem" "github-app: shows the paths before deleting"
assert_contains "$(out)" "gitzilla-alice private key" "github-app: prompt names the app"
assert_eq "after=0" "$(sed -n 1p "$T/queue.urls" | sed 's/.*?//')" "github-app: baseline read starts at 0"
assert_eq "after=5" "$(sed -n 3p "$T/queue.urls" | sed 's/.*?//')" "github-app: new-push check starts at the baseline (max seq 5)"
assert_eq 6 "$(cat "$STATE/queue-cursor")" "github-app: queue-cursor written (current max seq, plain integer)"
# stale event alone never passes
gh_app_setup
echo "$STALE" > "$T/curl/queue.json"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 1 "$(rc)" "github-app: a stale gitzilla-drill event alone does not pass"
assert_eq "" "$(step_file)" "github-app: not recorded"
assert_eq 0 "$([ -e "$STATE/queue-cursor" ] && echo 1 || echo 0)" "github-app: no cursor on failure"
# new event on page 2
gh_app_setup
echo '[{"seq":1,"repo":"alice/other","ref":"refs/heads/x"}]' > "$T/curl/queue.json"; echo 1 > "$T/curl/qpage"
echo '[{"seq":2,"repo":"alice/other","ref":"refs/heads/y"},{"seq":3,"repo":"alice/gitzilla-drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 2 > "$T/curl/late.after"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 0 "$(rc)" "github-app: new drill event found on page 2"
assert_eq 3 "$(cat "$STATE/queue-cursor")" "github-app: cursor = max seq across pages"
# queue unreadable
gh_app_setup
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 1 "$(rc)" "github-app: unreadable queue fails"
assert_contains "$(out)" "cannot read the Worker queue" "github-app: clear message"
# user declines deletion
gh_app_setup
echo '[]' > "$T/curl/queue.json"
echo PRIVATE > "$DL/gitzilla-alice.a.private-key.pem"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\nn\n' --from-step github-app
assert_eq 1 "$(rc)" "github-app: declining deletion fails"
assert_eq 1 "$(ls "$DL"/*.pem | wc -l | tr -d ' ')" "github-app: declined key left in place"
# deletion does nothing -> still present is an error
gh_app_setup
echo '[]' > "$T/curl/queue.json"; touch "$T/rm.noop"
echo PRIVATE > "$DL/gitzilla-alice.a.private-key.pem"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\ny\n' --from-step github-app
assert_eq 1 "$(rc)" "github-app: pem still present after delete -> rc 1"
assert_contains "$(out)" "still in ~/Downloads" "github-app: says the key is still there"
assert_contains "$(cat "$T/rm.log")" "gitzilla-alice.a.private-key.pem" "github-app: delete attempted with plain rm"
# push never arrives
gh_app_setup
echo '[]' > "$T/curl/queue.json"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 1 "$(rc)" "github-app: fails when no drill push reaches /queue"
# after a secrets rotation: update the existing app, never the create flow; marker cleared on success
gh_app_setup
echo "$STALE" > "$T/curl/queue.json"
echo '[{"seq":6,"repo":"alice/gitzilla-drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 2 > "$T/curl/late.after"
: > "$STATE/install-secrets-rotated"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 0 "$(rc)" "github-app after rotate ok"
assert_contains "$(out)" "https://github.com/settings/apps/gitzilla-alice/advanced" "github-app after rotate: edit the EXISTING app"
assert_contains "$(out)" "Re-subscribe the phone" "github-app after rotate: ntfy wording"
case "$(out)" in *"Create the GitHub App"*|*"lost it? rerun"*) _bad "github-app after rotate must not show the create flow" ;; *) _ok ;; esac
assert_eq 0 "$([ -e "$STATE/install-secrets-rotated" ] && echo 1 || echo 0)" "github-app: marker cleared on success"
assert_eq 0 "$(grep -c 'apps/new' "$T/open.log")" "github-app after rotate: new-app page not opened"
# marker survives a failed check
gh_app_setup
echo "$STALE" > "$T/curl/queue.json"; : > "$STATE/install-secrets-rotated"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 1 "$(rc)" "github-app after rotate: stale only fails"
assert_eq 1 "$([ -e "$STATE/install-secrets-rotated" ] && echo 1 || echo 0)" "github-app: marker kept when the check fails"

# N1: rotating before the app exists keeps the create flow; after it exists -> marker
reset
mkkey notekey ecdsa; cp "$T/keys/notekey.pub" "$GITZILLA_CONFIG_DIR/push-note.pub"; echo worker > "$STATE/install-step"
printf 'rotate\n%s\n' "$SLACK" > "$T/in.rotate"
GITZILLA_INSTALL_STOP_AFTER=worker bash "$INSTALL" --from-step worker < "$T/in.rotate" >"$T/out" 2>&1; echo $? > "$T/rc"
assert_eq 0 "$(rc)" "N1: rotate before github-app ok"
assert_eq 0 "$([ -e "$STATE/install-secrets-rotated" ] && echo 1 || echo 0)" "N1: no marker when the app was never created (install-step=worker)"
mk_sign_key
echo '[]' > "$T/curl/queue.json"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_contains "$(out)" "Create the GitHub App" "N1: github-app shows the create flow"
assert_contains "$(out)" "if the app already exists, edit its webhook secret at https://github.com/settings/apps/gitzilla-alice/advanced instead" "T11 M4: create flow mentions an existing app"
assert_contains "$(out)" "This push raises an orange (🟠) alert on your phone" "M11: drill push warns about the expected phone alert"
echo github-app > "$STATE/install-step"; rm -f "$T/npx.log"
GITZILLA_INSTALL_STOP_AFTER=worker bash "$INSTALL" --from-step worker < "$T/in.rotate" >"$T/out" 2>&1
assert_eq 1 "$([ -e "$STATE/install-secrets-rotated" ] && echo 1 || echo 0)" "N1: marker when install-step is github-app"
rm -f "$STATE/install-secrets-rotated" "$STATE/install-step"; echo 3 > "$STATE/queue-cursor"
GITZILLA_INSTALL_STOP_AFTER=worker bash "$INSTALL" --from-step worker < "$T/in.rotate" >"$T/out" 2>&1
assert_eq 1 "$([ -e "$STATE/install-secrets-rotated" ] && echo 1 || echo 0)" "N1: marker when a queue-cursor exists"

# N3: an existing cursor is never touched (higher and lower than the baseline)
for cur in 99 1; do
  gh_app_setup
  echo "$STALE" > "$T/curl/queue.json"
  echo '[{"seq":6,"repo":"alice/gitzilla-drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 2 > "$T/curl/late.after"
  echo "$cur" > "$STATE/queue-cursor"
  GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
  assert_eq 0 "$(rc)" "N3: ok with cursor $cur"
  assert_eq "$cur" "$(cat "$STATE/queue-cursor")" "N3: existing cursor $cur unchanged"
done

# N4: a similarly named repo does not count
gh_app_setup
echo '[]' > "$T/curl/queue.json"
echo '[{"seq":1,"repo":"alice/gitzilla-drill-old","ref":"refs/heads/main"},{"seq":2,"repo":"alice/xgitzilla-drill-","ref":"r"}]' > "$T/curl/late.json"; echo 1 > "$T/curl/late.after"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 1 "$(rc)" "N4: gitzilla-drill-old does not count"
gh_app_setup
echo '[]' > "$T/curl/queue.json"
echo '[{"seq":1,"repo":"Alice/Gitzilla-Drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 1 > "$T/curl/late.after"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 0 "$(rc)" "N4: match is case-insensitive on the repo name"
assert_contains "$(out)" "Alice/gitzilla-drill" "github-app: names the drill repo"
assert_contains "$(out)" "gh repo clone Alice/gitzilla-drill" "github-app: prints a clone hint"
assert_eq 0 "$(nmatch 'repo create' "$T/gh.log")" "github-app: an existing drill repo is not created"
assert_contains "$(cat "$T/gh.log")" "repo view Alice/gitzilla-drill" "github-app: checks the drill repo exists"
# a custom DRILL_REPO from the config is the one that counts
gh_app_setup
echo 'DRILL_REPO=my-drill' >> "$GITZILLA_CONFIG_DIR/config"
echo '[]' > "$T/curl/queue.json"
echo '[{"seq":1,"repo":"alice/gitzilla-drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 1 > "$T/curl/late.after"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 1 "$(rc)" "drill: the default name does not count when DRILL_REPO=my-drill"
assert_contains "$(out)" "my-drill" "drill: failure names the configured repo"
gh_app_setup
echo 'DRILL_REPO=My-Drill' >> "$GITZILLA_CONFIG_DIR/config"
echo '[]' > "$T/curl/queue.json"
echo '[{"seq":1,"repo":"alice/my-drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 1 > "$T/curl/late.after"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\n' --from-step github-app
assert_eq 0 "$(rc)" "drill: a push to the configured repo passes (case-insensitive)"
# missing drill repo: created after yes, with the exact gh args; refused when declined
gh_app_setup
touch "$T/gh.norepo"
echo '[]' > "$T/curl/queue.json"
echo '[{"seq":1,"repo":"alice/gitzilla-drill","ref":"refs/heads/main"}]' > "$T/curl/late.json"; echo 1 > "$T/curl/late.after"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\ny\n' --from-step github-app
assert_eq 0 "$(rc)" "drill: missing repo created after yes"
assert_contains "$(out)" "does not exist" "drill: says the repo is missing"
assert_contains "$(cat "$T/gh.log")" "repo create Alice/gitzilla-drill --private --add-readme --description throwaway repo for gitzilla drills" "drill: gh repo create args"
gh_app_setup
touch "$T/gh.norepo"
echo '[]' > "$T/curl/queue.json"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\nn\n' --from-step github-app
assert_eq 1 "$(rc)" "drill: declining the creation stops the step"
assert_eq 0 "$(nmatch 'repo create' "$T/gh.log")" "drill: nothing created when declined"
assert_eq 0 "$(nmatch '/queue' "$T/curl.log")" "drill: no verification wait when declined"
gh_app_setup
touch "$T/gh.norepo" "$T/gh.createfail"
echo '[]' > "$T/curl/queue.json"
GITZILLA_INSTALL_STOP_AFTER=github-app runin '\ny\n' --from-step github-app
assert_eq 1 "$(rc)" "drill: a failed gh repo create stops the step"

# --- 6. hook: idempotent, anchored, backup, mode
reset
make_hook
HOOKF="$HOME/.config/git/hooks/pre-push"
cp "$HOOKF" "$T/hook.orig"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "hook ok"
assert_eq 1 "$(nmatch 'gitzilla: push note' "$HOOKF")" "hook: marker present once"
assert_eq 1 "$(nmatch "$WD_ROOT/bin/note\" \"\$@\" || true" "$HOOKF")" "hook: note line present once with the absolute path"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "hook rerun ok"
assert_eq 1 "$(nmatch 'gitzilla: push note' "$HOOKF")" "hook rerun is a no-op (still exactly once)"
assert_eq 1 "$(nmatch '/bin/note' "$HOOKF")" "hook rerun: note line still once"
cmp -s "$T/hook.orig" "$HOOKF.bak-gitzilla" && _ok || _bad "hook: backup is the original"
assert_eq 755 "$(stat -f %Lp "$HOOKF")" "hook: mode preserved"
bash -n "$HOOKF" && _ok || _bad "hook: still valid bash"
a="$(grep -n 'done <<< "\$input"' "$HOOKF" | cut -d: -f1)"; n="$(grep -n 'gitzilla: push note' "$HOOKF" | cut -d: -f1)"; o="$(grep -n '^own=' "$HOOKF" | cut -d: -f1)"
[ "$n" -eq $((a + 1)) ] && [ "$o" -eq $((a + 3)) ] && _ok || _bad "hook: note inserted right after the scan loop, before the repo-hook chain ($a/$n/$o)"
# only the two inserted lines differ
assert_eq 2 "$(diff "$T/hook.orig" "$HOOKF" | grep -c '^>')" "hook: exactly two lines added"
# marker present but the note path differs -> replaced, once, with a backup
reset
make_hook
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
sed "s|$WD_ROOT/bin/note|/old/place/bin/note|" "$HOOKF" > "$T/h3"; cat "$T/h3" > "$HOOKF"
assert_eq 1 "$(nmatch '/old/place/bin/note' "$HOOKF")" "hook: stale path in place"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "hook: path refresh ok"
assert_eq 0 "$(nmatch '/old/place' "$HOOKF")" "hook: stale path replaced"
assert_eq 1 "$(nmatch "$WD_ROOT/bin/note\" \"\$@\" || true" "$HOOKF")" "hook: current path present once"
assert_eq 1 "$(nmatch 'gitzilla: push note' "$HOOKF")" "hook: marker still once"
bash -n "$HOOKF" && _ok || _bad "hook: valid bash after path refresh"
assert_eq 755 "$(stat -f %Lp "$HOOKF")" "hook: mode kept after refresh"
[ -f "$HOOKF.bak-gitzilla" ] && _ok || _bad "hook: backup exists"
# N2: marker kept but the note line removed by hand -> fresh note line inserted, following line untouched
reset
make_hook
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
grep -v '/bin/note' "$HOOKF" > "$T/h4"; cat "$T/h4" > "$HOOKF"
assert_eq 0 "$(nmatch '/bin/note' "$HOOKF")" "N2: note line removed"
mk=$(grep -n 'gitzilla: push note' "$HOOKF" | cut -d: -f1)
assert_eq 'own="$GIT_DIR_ABS/hooks/pre-push"' "$(sed -n "$((mk+1))p" "$HOOKF")" "N2: own= directly follows the marker"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "N2: refresh ok"
assert_eq 1 "$(nmatch "$WD_ROOT/bin/note\" \"\$@\" || true" "$HOOKF")" "N2: fresh note line inserted"
assert_eq 1 "$(nmatch '^own="\$GIT_DIR_ABS/hooks/pre-push"$' "$HOOKF")" "N2: own= line still present, once"
assert_eq 'own="$GIT_DIR_ABS/hooks/pre-push"' "$(sed -n "$((mk+2))p" "$HOOKF")" "N2: own= line follows the note line, unchanged"
bash -n "$HOOKF" && _ok || _bad "N2: valid bash"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 1 "$(nmatch '/bin/note' "$HOOKF")" "N2: rerun is a no-op"
# --- 6b. hook for people without polin-guard: standalone hook, chaining, bundled scanner
Z40=0000000000000000000000000000000000000000
PATH_NODE="$(dirname "$NODE_BIN")"
HD="$HOME/.config/git/hooks"
STAND="# gitzilla standalone pre-push hook"
# no hook, no core.hooksPath: declining leaves everything untouched
reset
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 1 "$(rc)" "hook: no hook + no hooksPath, declined -> fails"
assert_contains "$(out)" "ignore each repo's own .git/hooks" "hook: explains what a global hooks path does"
assert_eq 0 "$([ -e "$HD" ] && echo 1 || echo 0)" "hook: declined -> no hooks dir created"
assert_eq "" "$(git config --global core.hooksPath)" "hook: declined -> core.hooksPath still unset"
assert_eq "" "$(step_file)" "hook: declined -> not recorded"
# yes: standalone hook created, hooksPath set
reset
GITZILLA_INSTALL_STOP_AFTER=hook runin 'y\n' --from-step hook
assert_eq 0 "$(rc)" "hook: standalone install ok"
HOOKF="$HD/pre-push"
[ -x "$HOOKF" ] && _ok || _bad "hook: standalone hook is executable"
assert_eq "$HD" "$(git config --global core.hooksPath)" "hook: core.hooksPath set to ~/.config/git/hooks"
assert_eq "$HD" "$(cat "$STATE/install-set-hookspath" 2>/dev/null)" "M7 hook: recorded that the installer set core.hooksPath"
assert_eq "$(node -p process.execPath)" "$(cat "$T/node-path" 2>/dev/null)" "I1 hook: node path recorded (node -p process.execPath)"
assert_eq 1 "$(nmatch "^$STAND" "$HOOKF")" "hook: standalone header present"
assert_eq 1 "$(nmatch 'gitzilla: push note' "$HOOKF")" "hook: standalone carries the marker once"
assert_eq 1 "$(nmatch "^printf '%s\\\\n' \"\$input\" | \"$WD_ROOT/bin/note\" \"\$@\" || true$" "$HOOKF")" "hook: standalone note line (absolute GITZILLA_HOME)"
mk=$(grep -n 'gitzilla: push note' "$HOOKF" | cut -d: -f1)
assert_contains "$(sed -n "$((mk+1))p" "$HOOKF")" "$WD_ROOT/bin/note" "hook: note line directly follows the marker"
assert_eq 1 "$(nmatch "^GITZILLA_HOME=\"$WD_ROOT\"$" "$HOOKF")" "hook: standalone GITZILLA_HOME is the absolute install dir"
assert_eq 1 "$(nmatch 'bash "$GITZILLA_HOME/scanner/scan.sh" range' "$HOOKF")" "hook: standalone runs the bundled scanner"
assert_eq 0 "$(nmatch '@GITZILLA_HOME@' "$HOOKF")" "hook: template fully rendered"
bash -n "$HOOKF" && _ok || _bad "hook: standalone is valid bash"
cp "$HOOKF" "$T/stand.1"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "hook: standalone rerun ok (hooksPath set, no question)"
cmp -s "$T/stand.1" "$HOOKF" && _ok || _bad "hook: standalone rerun leaves the hook unchanged"
assert_eq 0 "$([ -e "$HD/pre-push.gitzilla-prev" ] && echo 1 || echo 0)" "hook: standalone rerun does not chain to itself"
# a moved GITZILLA_HOME is re-rendered (scanner and note paths both)
sed "s|$WD_ROOT|/old/place|g" "$HOOKF" > "$T/h5"; cat "$T/h5" > "$HOOKF"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "hook: standalone refresh ok"
assert_eq 0 "$(nmatch '/old/place' "$HOOKF")" "hook: standalone refresh replaces every stale path"
cmp -s "$T/stand.1" "$HOOKF" && _ok || _bad "hook: standalone refresh equals a fresh render"

# the standalone hook in real pushes: scanner blocks before the note, repo-local hook chained with stdin/args/status
hk_setup() {
  rm -rf "$T/hk"; mkdir -p "$T/hk"
  git init -q --bare -b main "$T/hk/remote.git"
  git init -q -b main "$T/hk/w"
  echo clean > "$T/hk/w/README.md"; git -C "$T/hk/w" add README.md; git -C "$T/hk/w" commit -q -m init
  git -C "$T/hk/w" remote add origin "$T/hk/remote.git"
  git -C "$T/hk/w" -c core.hooksPath=/dev/null push -q origin main
}
hk_push() { ( cd "$T/hk/w" && PATH="$PATH_NODE:$PATH" git push origin "$@" ) >"$T/hk.out" 2>&1; echo $? > "$T/hk.rc"; }
hk_run() { # stdin-line url -> runs the installed hook directly, as git would
  ( cd "$T/hk/w" && printf '%s\n' "$1" | PATH="$PATH_NODE:$PATH" "$HOOKF" origin "$2" ) >"$T/hk.out" 2>&1; echo $? > "$T/hk.rc"
}
remote_has() { git -C "$T/hk/remote.git" rev-parse -q --verify "refs/heads/$1" >/dev/null && echo 1 || echo 0; }
hk_setup
git -C "$T/hk/w" checkout -q -b feat
echo 'export const x = 1;' > "$T/hk/w/clean.js"; git -C "$T/hk/w" add clean.js; git -C "$T/hk/w" commit -q -m clean
hk_push feat
assert_eq 0 "$(cat "$T/hk.rc")" "hook push: clean new branch passes the scanner"
assert_eq 1 "$(remote_has feat)" "hook push: clean branch reached the remote"
git -C "$T/hk/w" checkout -q -b bad
base64 --decode < "$WD_ROOT/tests/fixtures/stager.js.b64" > "$T/hk/w/vite.config.js"
git -C "$T/hk/w" add vite.config.js; git -C "$T/hk/w" commit -q -m payload
hk_push bad
assert_eq 1 "$(cat "$T/hk.rc")" "hook push: scanner finding blocks the push"
assert_contains "$(cat "$T/hk.out")" "BLOCKED" "hook push: says the push is blocked"
assert_eq 0 "$(remote_has bad)" "hook push: blocked branch not on the remote"
# blocking happens before the note: an owned-repo URL with no config prints the note warning only when the note runs
hk_run "refs/heads/bad $(git -C "$T/hk/w" rev-parse bad) refs/heads/bad $Z40" git@github.com:alice/drill.git
assert_eq 1 "$(cat "$T/hk.rc")" "hook: payload -> exit 1"
case "$(cat "$T/hk.out")" in *"note not sent"*) _bad "hook: no note when the scanner blocks" ;; *) _ok ;; esac
hk_run "refs/heads/feat $(git -C "$T/hk/w" rev-parse feat) refs/heads/feat $Z40" git@github.com:alice/drill.git
assert_eq 0 "$(cat "$T/hk.rc")" "hook: clean -> exit 0"
assert_contains "$(cat "$T/hk.out")" "note not sent (not configured)" "hook: the note runs for a clean push"
# an existing branch: only base..tip is scanned (payload already on the remote is not rescanned)
git -C "$T/hk/w" -c core.hooksPath=/dev/null push -q origin bad
echo 'export const y = 2;' > "$T/hk/w/more.js"; git -C "$T/hk/w" add more.js; git -C "$T/hk/w" commit -q -m more
hk_push bad
assert_eq 0 "$(cat "$T/hk.rc")" "hook push: update of an existing branch scans only the new range"
# repo-local hook chained: same stdin and args, its exit status decides
git -C "$T/hk/w" checkout -q main
cat > "$T/hk/w/.git/hooks/pre-push" <<'LOCAL'
#!/bin/sh
cat > "$LOCAL_LOG.in"; echo "$*" > "$LOCAL_LOG.args"; exit "${LOCAL_RC:-0}"
LOCAL
chmod 755 "$T/hk/w/.git/hooks/pre-push"
export LOCAL_LOG="$T/local"
echo two >> "$T/hk/w/README.md"; git -C "$T/hk/w" commit -q -am two
LOCAL_RC=3 hk_push main
assert_eq 1 "$(cat "$T/hk.rc")" "hook push: a failing repo-local hook blocks the push"
assert_eq "$(git -C "$T/hk/remote.git" rev-parse main)" "$(git -C "$T/hk/w" rev-parse main~1)" "hook push: remote main unchanged"
assert_contains "$(cat "$LOCAL_LOG.in")" "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main" "hook: repo-local hook got the pushed refs on stdin"
assert_eq "origin $T/hk/remote.git" "$(cat "$LOCAL_LOG.args")" "hook: repo-local hook got the remote name and URL"
hk_run "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main $(git -C "$T/hk/remote.git" rev-parse main)" "$T/hk/remote.git"
assert_eq 0 "$(cat "$T/hk.rc")" "hook: LOCAL_RC unset -> repo-local hook exits 0"
LOCAL_RC=5 hk_run "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main $Z40" "$T/hk/remote.git"
assert_eq 5 "$(cat "$T/hk.rc")" "hook: repo-local exit status propagated"
hk_push main
assert_eq 0 "$(cat "$T/hk.rc")" "hook push: passing repo-local hook lets the push through"
unset LOCAL_LOG

# an existing foreign global hook (no anchor, no marker) in a custom hooksPath: moved aside and chained
reset
CH="$T/custom hooks"; rm -rf "$CH"; mkdir -p "$CH"
cat > "$CH/pre-push" <<'FOREIGN'
#!/bin/sh
cat > "$FOREIGN_LOG.in"; echo "$*" > "$FOREIGN_LOG.args"; basename "$0" > "$FOREIGN_LOG.name"; exit "${FOREIGN_RC:-0}"
FOREIGN
chmod 755 "$CH/pre-push"; cp "$CH/pre-push" "$T/foreign.orig"
git config --global core.hooksPath "$CH"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 1 "$(rc)" "M4 hook: chaining a foreign hook needs a yes"
cmp -s "$T/foreign.orig" "$CH/pre-push" && _ok || _bad "M4 hook: declined -> foreign hook untouched"
assert_eq 0 "$([ -e "$CH/pre-push.gitzilla-prev" ] && echo 1 || echo 0)" "M4 hook: declined -> nothing moved"
GITZILLA_INSTALL_STOP_AFTER=hook runin 'y\n' --from-step hook
assert_eq 0 "$(rc)" "hook: foreign hook chained"
assert_eq "../pre-push.gitzilla-prev" "$(readlink "$CH/gitzilla-prev/pre-push")" "M6 hook: moved hook reachable as gitzilla-prev/pre-push"
HOOKF="$CH/pre-push"
cmp -s "$T/foreign.orig" "$CH/pre-push.gitzilla-prev" && _ok || _bad "hook: foreign hook moved to pre-push.gitzilla-prev"
cmp -s "$T/foreign.orig" "$CH/pre-push.bak-gitzilla" && _ok || _bad "hook: foreign hook backed up"
assert_eq 1 "$(nmatch "^$STAND" "$HOOKF")" "hook: standalone hook installed in its place"
assert_eq "$CH" "$(git config --global core.hooksPath)" "hook: custom hooksPath kept"
assert_eq 0 "$([ -e "$HD/pre-push" ] && echo 1 || echo 0)" "hook: nothing written to ~/.config/git/hooks"
export FOREIGN_LOG="$T/foreign"
hk_setup
FOREIGN_RC=7 hk_run "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main $Z40" git@github.com:alice/drill.git
assert_eq 7 "$(cat "$T/hk.rc")" "hook: foreign hook's exit status propagated"
assert_contains "$(cat "$FOREIGN_LOG.in")" "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main $Z40" "hook: foreign hook got the same stdin"
assert_eq "origin git@github.com:alice/drill.git" "$(cat "$FOREIGN_LOG.args")" "hook: foreign hook got the same args"
assert_eq pre-push "$(cat "$FOREIGN_LOG.name")" "M6 hook: the chained hook still runs under the name pre-push"
FOREIGN_RC=0 hk_run "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main $Z40" git@github.com:alice/drill.git
assert_eq 0 "$(cat "$T/hk.rc")" "hook: foreign hook passing -> exit 0"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "hook: rerun after chaining ok"
cmp -s "$T/foreign.orig" "$CH/pre-push.gitzilla-prev" && _ok || _bad "hook: rerun leaves the chained hook alone"
# R5: a missing gitzilla-prev link is recreated on a rerun (and the chained hook runs again)
rm -rf "$CH/gitzilla-prev"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "R5 hook: rerun with a missing link ok"
assert_eq "../pre-push.gitzilla-prev" "$(readlink "$CH/gitzilla-prev/pre-push")" "R5 hook: link recreated"
assert_contains "$(out)" "relinked the chained hook" "R5 hook: says so"
FOREIGN_RC=6 hk_run "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main $Z40" git@github.com:alice/drill.git
assert_eq 6 "$(cat "$T/hk.rc")" "R5 hook: relinked hook runs again"
rm -f "$CH/gitzilla-prev/pre-push"; echo junk > "$CH/gitzilla-prev/pre-push"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq "../pre-push.gitzilla-prev" "$(readlink "$CH/gitzilla-prev/pre-push")" "R5 hook: a file in place of the link is replaced"
# R1: the chained hook sees the caller's PATH order (Homebrew dirs only appended)
cat > "$CH/pre-push.gitzilla-prev" <<'PATHHOOK'
#!/bin/sh
cat > /dev/null; printf '%s\n' "$PATH" > "$FOREIGN_LOG.path"; exit 0
PATHHOOK
chmod 755 "$CH/pre-push.gitzilla-prev"
mkdir -p "$T/pfirst"
( cd "$T/hk/w" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse main)" "$Z40" | PATH="$T/pfirst:$PATH_NODE:/usr/bin:/bin" "$HOOKF" origin git@github.com:alice/drill.git ) >"$T/hk.out" 2>&1
case "$(cat "$FOREIGN_LOG.path")" in "$T/pfirst:$PATH_NODE:/usr/bin:/bin"*) _ok ;; *) _bad "R1 hook: chained hook PATH starts with the caller's PATH ($(cat "$FOREIGN_LOG.path"))" ;; esac
case "$(cat "$FOREIGN_LOG.path")" in /opt/homebrew/bin*|/usr/local/bin*) _bad "R1 hook: Homebrew dirs must not be prepended" ;; *) _ok ;; esac
cp "$T/foreign.orig" "$CH/pre-push.gitzilla-prev"
# a second foreign hook while a previous one is already chained: refuse, change nothing
cp "$T/foreign.orig" "$CH/pre-push"; echo '# changed' >> "$CH/pre-push"; cp "$CH/pre-push" "$T/foreign.2"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 1 "$(rc)" "hook: refuses when pre-push.gitzilla-prev already exists"
cmp -s "$T/foreign.2" "$CH/pre-push" && _ok || _bad "hook: refused -> hook untouched"
cmp -s "$T/foreign.orig" "$CH/pre-push.gitzilla-prev" && _ok || _bad "hook: refused -> chained hook untouched"
# M3: a non-executable foreign hook (git ignored it) is moved aside but stays non-executable and is not run
reset
rm -rf "$CH"; mkdir -p "$CH"; cp "$T/foreign.orig" "$CH/pre-push"; chmod 644 "$CH/pre-push"
git config --global core.hooksPath "$CH"
GITZILLA_INSTALL_STOP_AFTER=hook runin 'y\n' --from-step hook
assert_eq 0 "$(rc)" "M3 hook: non-executable foreign hook handled"
assert_eq 644 "$(stat -f %Lp "$CH/pre-push.gitzilla-prev")" "M3 hook: mode not changed (no +x added)"
assert_contains "$(out)" "NOT chained" "M3 hook: says the ignored hook is not chained"
rm -f "$FOREIGN_LOG".*
hk_setup
FOREIGN_RC=9 hk_run "refs/heads/main $(git -C "$T/hk/w" rev-parse main) refs/heads/main $Z40" git@github.com:alice/drill.git
assert_eq 0 "$(cat "$T/hk.rc")" "M3 hook: ignored hook not run"
assert_eq 0 "$([ -e "$FOREIGN_LOG.in" ] && echo 1 || echo 0)" "M3 hook: ignored hook left silent"
unset FOREIGN_LOG
rm -rf "$CH"

# M1: a relative global core.hooksPath is refused
reset
git config --global core.hooksPath .githooks
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 1 "$(rc)" "M1 hook: relative core.hooksPath refused"
assert_contains "$(out)" "relative path" "M1 hook: says why"
assert_eq 0 "$([ -e "$WD_ROOT/.githooks" ] || [ -e "$(pwd)/.githooks" ] && echo 1 || echo 0)" "M1 hook: nothing written relative to the cwd"
assert_eq .githooks "$(git config --global core.hooksPath)" "M1 hook: hooksPath unchanged"

# I2: core.hooksPath from an included config file is honoured; no new hooksPath is written
reset
IH="$T/inc hooks"; rm -rf "$IH"
printf '[core]\n\thooksPath = %s\n' "$IH" > "$T/inc.gitconfig"
git config --global include.path "$T/inc.gitconfig"
mkdir -p "$IH"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_eq 0 "$(rc)" "I2 hook: included hooksPath used without a question"
assert_eq 1 "$(nmatch "^$STAND" "$IH/pre-push")" "I2 hook: hook installed in the included hooks dir"
assert_eq "" "$(git config --global --get core.hooksPath)" "I2 hook: no core.hooksPath written to the global file"
assert_eq 0 "$([ -e "$STATE/install-set-hookspath" ] && echo 1 || echo 0)" "I2/M7 hook: nothing recorded when the installer did not set hooksPath"
assert_eq 0 "$([ -e "$HD/pre-push" ] && echo 1 || echo 0)" "I2 hook: ~/.config/git/hooks not used"
rm -rf "$IH"

# M2/M11: existing files in the default dir are listed; declining says how to continue
reset
mkdir -p "$HD"; touch "$HD/pre-commit"
GITZILLA_INSTALL_STOP_AFTER=hook run --from-step hook
assert_contains "$(out)" "already holds: pre-commit" "M2 hook: lists files that become active"
assert_contains "$(out)" "rerun ./install.sh --from-step hook" "M11 hook: decline says how to continue"
assert_contains "$(out)" "git config --global core.hooksPath <absolute dir>" "M11 hook: decline names the manual setting"

# I1: absolute node and jq recorded; GUI-client PATH; deleted clone fails open; scanner error blocks with a reason
reset
WC="$T/wd"; rm -rf "$WC" "$T/wd-gone"; mkdir -p "$WC"
cp -R "$WD_ROOT/bin" "$WD_ROOT/hooks" "$WD_ROOT/scanner" "$WD_ROOT/install.sh" "$WC/"
rm -f "$WC/scanner/node-path"
( unset GITZILLA_NODE_PATH_FILE; printf 'y\n' | GITZILLA_INSTALL_STOP_AFTER=hook bash "$WC/install.sh" --from-step hook ) >"$T/out" 2>&1; echo $? > "$T/rc"
assert_eq 0 "$(rc)" "I1 hook: install from a copy ok"
assert_eq "$(node -p process.execPath)" "$(cat "$WC/scanner/node-path" 2>/dev/null)" "I1 hook: absolute node recorded in scanner/node-path"
assert_eq "$(command -v jq)" "$(cat "$GITZILLA_CONFIG_DIR/jq-path" 2>/dev/null)" "I1 hook: absolute jq recorded in jq-path"
assert_eq "$HD" "$(cat "$STATE/install-set-hookspath" 2>/dev/null)" "M7 hook: install-set-hookspath records the dir the installer set"
HOOKF="$HD/pre-push"
MINPATH=/usr/bin:/bin:/usr/sbin:/sbin
hk_min() { ( cd "$T/hk/w" && printf '%s\n' "$1" | env PATH="$MINPATH" "$HOOKF" origin "$2" ) >"$T/hk.out" 2>&1; echo $? > "$T/hk.rc"; }
hk_setup
git -C "$T/hk/w" checkout -q -b feat
echo 'export const x = 1;' > "$T/hk/w/clean.js"; git -C "$T/hk/w" add clean.js; git -C "$T/hk/w" commit -q -m clean
hk_min "refs/heads/feat $(git -C "$T/hk/w" rev-parse feat) refs/heads/feat $Z40" git@github.com:alice/drill.git
assert_eq 0 "$(cat "$T/hk.rc")" "I1 hook: minimal (GUI) PATH, clean push passes"
assert_contains "$(cat "$T/hk.out")" "note not sent (not configured)" "I1 hook: minimal PATH, the note runs"
git -C "$T/hk/w" checkout -q -b bad
base64 --decode < "$WD_ROOT/tests/fixtures/stager.js.b64" > "$T/hk/w/vite.config.js"
git -C "$T/hk/w" add vite.config.js; git -C "$T/hk/w" commit -q -m payload
hk_min "refs/heads/bad $(git -C "$T/hk/w" rev-parse bad) refs/heads/bad $Z40" git@github.com:alice/drill.git
assert_eq 1 "$(cat "$T/hk.rc")" "I1 hook: minimal PATH still scans (node from node-path) and blocks the payload"
assert_contains "$(cat "$T/hk.out")" "BLOCKED by the scanner" "I1 hook: minimal PATH, finding message"
# scanner error (exit 2): blocked, with the reason and the bypass
cp "$WC/scanner/scan.sh" "$T/scan.real"
printf '#!/usr/bin/env bash\necho "gitzilla scanner: node not found — cannot scan" >&2\nexit 2\n' > "$WC/scanner/scan.sh"
hk_run "refs/heads/feat $(git -C "$T/hk/w" rev-parse feat) refs/heads/feat $Z40" git@github.com:alice/drill.git
assert_eq 1 "$(cat "$T/hk.rc")" "I1 hook: a scan that cannot run blocks"
assert_contains "$(cat "$T/hk.out")" "the scan could not run (gitzilla scanner: node not found — cannot scan)" "I1 hook: says the scan could not run and why"
assert_contains "$(cat "$T/hk.out")" "git push --no-verify" "I1 hook: names the bypass"
case "$(cat "$T/hk.out")" in *"note not sent"*) _bad "I1 hook: no note when the scan could not run" ;; *) _ok ;; esac
cp "$T/scan.real" "$WC/scanner/scan.sh"
# the clone is gone: fail open (no scan, no note), distinct message, the repo hook still chained
mv "$WC" "$T/wd-gone"
hk_run "refs/heads/bad $(git -C "$T/hk/w" rev-parse bad) refs/heads/bad $Z40" git@github.com:alice/drill.git
assert_eq 0 "$(cat "$T/hk.rc")" "I1 hook: missing clone -> push allowed"
assert_contains "$(cat "$T/hk.out")" "gitzilla: install dir $WC not found — rerun install.sh from the new location, or remove the hook" "I1 hook: missing clone message"
case "$(cat "$T/hk.out")" in *"note not sent"*|*BLOCKED*) _bad "I1 hook: missing clone -> no scan and no note" ;; *) _ok ;; esac
printf '#!/bin/sh\nexit 4\n' > "$T/hk/w/.git/hooks/pre-push"; chmod 755 "$T/hk/w/.git/hooks/pre-push"
hk_run "refs/heads/bad $(git -C "$T/hk/w" rev-parse bad) refs/heads/bad $Z40" git@github.com:alice/drill.git
assert_eq 4 "$(cat "$T/hk.rc")" "I1 hook: missing clone -> the repo-local hook still runs"
rm -rf "$T/wd-gone"

# I3: in a linked worktree the repo's own hook (common git dir) is still chained
reset
GITZILLA_INSTALL_STOP_AFTER=hook runin 'y\n' --from-step hook
HOOKF="$HD/pre-push"
hk_setup
printf '#!/bin/sh\necho ran > "%s/wt.ran"; exit "${LOCAL_RC:-0}"\n' "$T" > "$T/hk/w/.git/hooks/pre-push"; chmod 755 "$T/hk/w/.git/hooks/pre-push"
git -C "$T/hk/w" worktree add -q -b wtb "$T/hk/wt" main
echo wt > "$T/hk/wt/wt.txt"; git -C "$T/hk/wt" add wt.txt; git -C "$T/hk/wt" commit -q -m wt
rm -f "$T/wt.ran"
( cd "$T/hk/wt" && LOCAL_RC=3 PATH="$PATH_NODE:$PATH" git push origin wtb ) >"$T/hk.out" 2>&1; echo $? > "$T/hk.rc"
assert_eq 1 "$(cat "$T/hk.rc")" "I3 hook: in a worktree the failing repo hook blocks the push"
assert_eq ran "$(cat "$T/wt.ran" 2>/dev/null)" "I3 hook: repo hook ran from the worktree"
assert_eq 0 "$(remote_has wtb)" "I3 hook: blocked worktree branch not on the remote"
( cd "$T/hk/wt" && PATH="$PATH_NODE:$PATH" git push origin wtb ) >"$T/hk.out" 2>&1; echo $? > "$T/hk.rc"
assert_eq 0 "$(cat "$T/hk.rc")" "I3 hook: passing repo hook lets the worktree push through"

# --- 7. repos
reset
write_config
echo '[{"nameWithOwner":"Alice/Repo-One","visibility":"PUBLIC"},{"nameWithOwner":"alice/two","visibility":"PRIVATE"},{"nameWithOwner":"alice/three","visibility":"INTERNAL"},{"nameWithOwner":"other/x","visibility":"PUBLIC"}]' > "$T/gh.repos"
GITZILLA_INSTALL_STOP_AFTER=repos run --from-step repos
assert_eq 0 "$(rc)" "repos ok"
assert_eq "alice/repo-one public
alice/three private
alice/two private" "$(cat "$STATE/repos.txt")" "I2 repos: '<slug> public|private', lower-cased, owner's repos only (as rotate writes it)"
assert_contains "$(cat "$T/gh.log")" "repo list Alice --limit 1000 --json nameWithOwner,visibility" "repos: gh repo list args"
# I2: install's repos.txt drives the REAL reconcile: the public repo gets an ls-remote check
mkdir -p "$T/rc-cfg"; printf 'GITZILLA_URL=http://127.0.0.1:1\nOWNER=Alice\n' > "$T/rc-cfg/config"
printf '#!/bin/sh\necho "$1" >> "%s/lsr.log"\nprintf "%%s\\trefs/heads/main\\n" 2222222222222222222222222222222222222222\n' "$T" > "$S/lsr"; chmod +x "$S/lsr"
printf 'alice/repo-one\n' > "$STATE/seeded.txt"; echo '{"alice/repo-one":{"refs/heads/main":"1111111111111111111111111111111111111111"}}' > "$STATE/heads.json"
GITZILLA_CONFIG_DIR="$T/rc-cfg" GITZILLA_GIT_LS_REMOTE="$S/lsr" GITZILLA_CURL=false GITZILLA_NOTIFY_CMD=true GITZILLA_NOW=1760000000 \
  bash "$WD_ROOT/bin/reconcile" public >/dev/null 2>&1
assert_eq "https://github.com/alice/repo-one.git" "$(cat "$T/lsr.log" 2>/dev/null)" "I2: reconcile checks the repo from install's repos.txt"
case "$(cat "$STATE/log/gitzilla.log" 2>/dev/null)" in *"bad visibility"*) _bad "I2: reconcile reports bad visibility" ;; *) _ok ;; esac
assert_eq 1 "$(jq 'length' "$STATE/reconcile-seen.json")" "I2: the moved ref is a first strike"
rm -f "$T/lsr.log" "$STATE/seeded.txt" "$STATE/heads.json" "$STATE/reconcile-seen.json"
echo '[]' > "$T/gh.repos"; rm -f "$STATE/repos.txt"
GITZILLA_INSTALL_STOP_AFTER=repos run --from-step repos
assert_eq 1 "$(rc)" "repos: empty list refused"
assert_eq 0 "$([ -e "$STATE/repos.txt" ] && echo 1 || echo 0)" "repos: nothing written"
: > "$T/gh.repos"
GITZILLA_INSTALL_STOP_AFTER=repos run --from-step repos
assert_eq 1 "$(rc)" "repos: gh failure / no output refused"

# --- 8. mirrors: clone, fetch, seed after cloning, failures listed
reset
write_config
mkbare alice/r1; mkbare alice/r2
printf 'alice/r1 public\nalice/r2 private\n' > "$STATE/repos.txt"
GITZILLA_INSTALL_STOP_AFTER=mirrors run --from-step mirrors
assert_eq 0 "$(rc)" "mirrors ok"
[ -d "$STATE/mirrors/alice__r1.git" ] && [ -d "$STATE/mirrors/alice__r2.git" ] && _ok || _bad "I2 mirrors: both cloned from '<slug> <vis>' lines"
for r in r1 r2; do
  assert_eq "0 never always" "$(git -C "$STATE/mirrors/alice__$r.git" config gc.auto) $(git -C "$STATE/mirrors/alice__$r.git" config gc.pruneExpire) $(git -C "$STATE/mirrors/alice__$r.git" config core.logAllRefUpdates)" "I3 mirrors: $r never auto-gcs, never prunes, logs ref updates"
done
assert_eq "seed | mirrors: alice__r1.git alice__r2.git " "$(cat "$T/reconcile.log")" "mirrors: reconcile seed ran once, after both mirrors existed"
assert_eq mirrors "$(step_file)" "mirrors recorded"
# present mirror -> fetch picks up new commits; an existing (unhardened) mirror gets the gc settings
git -C "$T/work/alice__r1" commit -q --allow-empty -m two; git -C "$T/work/alice__r1" push -q "$T/remote/alice/r1.git" main
git -C "$STATE/mirrors/alice__r1.git" config --unset gc.auto; git -C "$STATE/mirrors/alice__r1.git" config --unset gc.pruneExpire
GITZILLA_INSTALL_STOP_AFTER=mirrors run --from-step mirrors
assert_eq "0 never" "$(git -C "$STATE/mirrors/alice__r1.git" config gc.auto) $(git -C "$STATE/mirrors/alice__r1.git" config gc.pruneExpire)" "I3 mirrors: existing mirror hardened on rerun"
assert_eq 0 "$(rc)" "mirrors rerun ok"
assert_eq "$(git -C "$T/remote/alice/r1.git" rev-parse main)" "$(git -C "$STATE/mirrors/alice__r1.git" rev-parse main)" "mirrors: existing mirror fetched"
# failure: a repo that cannot be cloned
rm -f "$T/reconcile.log" "$STATE/install-step"
printf 'alice/r1 public\nalice/ghost private\n' > "$STATE/repos.txt"
GITZILLA_INSTALL_STOP_AFTER=mirrors run --from-step mirrors
assert_eq 1 "$(rc)" "mirrors: a failed clone fails the step"
assert_contains "$(out)" "alice/ghost" "mirrors: failures listed"
assert_contains "$(out)" "--from-step mirrors" "mirrors: tells how to retry"
assert_eq 0 "$([ -e "$T/reconcile.log" ] && echo 1 || echo 0)" "mirrors: no seed when a mirror failed"
assert_eq "" "$(step_file)" "mirrors: not recorded on failure"
# seed failure
printf 'alice/r1 public\n' > "$STATE/repos.txt"; touch "$T/reconcile.fail"
GITZILLA_INSTALL_STOP_AFTER=mirrors run --from-step mirrors
assert_eq 1 "$(rc)" "mirrors: seed failure fails the step"
rm -f "$T/reconcile.fail"

# --- 9. known-keys
reset
write_config
mkkey ghauth; mkkey sign; mkkey stranger
mkdir -p "$HOME/.ssh"; cp "$T/keys/ghauth.pub" "$HOME/.ssh/github-auth.pub"
git config --global user.signingkey "$T/keys/sign.pub"
blob() { awk '{print $1" "$2}' "$T/keys/$1.pub"; }
signing_json() { jq -cn --arg k "$(cat "$T/keys/$1.pub")" '[{id:1,key:$k,title:"signing"}]' > "$T/curl/signing.json"; }
# github-auth.pub not on GitHub -> refused
cat "$T/keys/stranger.pub" > "$T/curl/auth.keys"; signing_json sign
GITZILLA_INSTALL_STOP_AFTER=known-keys runin 'yes\n' --from-step known-keys
assert_eq 1 "$(rc)" "known-keys: refuses when github-auth.pub isn't on GitHub"
assert_eq 0 "$([ -e "$STATE/known-keys.txt" ] && echo 1 || echo 0)" "known-keys: nothing written when refused"
# not typing yes
cat "$T/keys/ghauth.pub" "$T/keys/stranger.pub" > "$T/curl/auth.keys"
GITZILLA_INSTALL_STOP_AFTER=known-keys runin 'no\n' --from-step known-keys
assert_eq 1 "$(rc)" "known-keys: needs the owner to type yes"
assert_eq 0 "$([ -e "$STATE/known-keys.txt" ] && echo 1 || echo 0)" "known-keys: nothing written without yes"
# ok
GITZILLA_INSTALL_STOP_AFTER=known-keys runin 'yes\n' --from-step known-keys
assert_eq 0 "$(rc)" "known-keys ok"
assert_eq 600 "$(stat -f %Lp "$STATE/known-keys.txt")" "known-keys: mode 600"
KK="$(cat "$STATE/known-keys.txt")"
assert_contains "$KK" "$(blob ghauth)" "known-keys: includes the auth key"
assert_contains "$KK" "$(blob stranger)" "known-keys: includes every listed auth key"
assert_contains "$KK" "$(blob sign)" "known-keys: includes the signing key"
assert_contains "$(out)" "SHA256:" "known-keys: prints fingerprints"
assert_contains "$(out)" "[title: signing]" "known-keys: shows the GitHub title beside the signing-key fingerprint"
# existing file -> skipped
echo "marker" >> "$STATE/known-keys.txt"
GITZILLA_INSTALL_STOP_AFTER=known-keys run --from-step known-keys
assert_eq 0 "$(rc)" "known-keys: existing file skipped"
assert_contains "$(cat "$STATE/known-keys.txt")" "marker" "known-keys: existing file untouched"

# --- 10. launchd + first-rotation + self-test; rerun idempotent
reset
write_config
LA="$HOME/Library/LaunchAgents"
GITZILLA_INSTALL_STOP_AFTER=launchd run --from-step launchd
assert_eq 0 "$(rc)" "launchd ok"
for j in agent reconcile rotate; do
  p="$LA/io.github.gitzilla.$j.plist"
  [ -f "$p" ] && plutil -lint "$p" >/dev/null && _ok || _bad "launchd: $j plist exists and passes plutil -lint"
  case "$(cat "$p")" in *@*@*) _bad "launchd: $j has unrendered tokens" ;; *) _ok ;; esac
  assert_contains "$(cat "$p")" "$STATE/log/$j.out" "launchd: $j log path"
  assert_contains "$(cat "$p")" "io.github.gitzilla.$j" "launchd: $j label"
done
assert_eq 300 "$(plutil -extract StartInterval raw "$LA/io.github.gitzilla.agent.plist")" "launchd: agent StartInterval 300"
assert_eq true "$(plutil -extract RunAtLoad raw "$LA/io.github.gitzilla.agent.plist")" "launchd: agent RunAtLoad"
assert_eq 3600 "$(plutil -extract StartInterval raw "$LA/io.github.gitzilla.reconcile.plist")" "launchd: reconcile StartInterval 3600"
assert_eq 10 "$(plutil -extract StartCalendarInterval.Hour raw "$LA/io.github.gitzilla.rotate.plist")" "launchd: rotate daily at 10:00"
assert_eq /bin/bash "$(plutil -extract ProgramArguments.0 raw "$LA/io.github.gitzilla.reconcile.plist")" "launchd: /bin/bash"
assert_eq "\"$WD_ROOT/bin/reconcile\" public && \"$WD_ROOT/bin/reconcile\" all" "$(plutil -extract ProgramArguments.2 raw "$LA/io.github.gitzilla.reconcile.plist")" "launchd: reconcile public && all"
assert_eq "$WD_ROOT/bin/rotate" "$(plutil -extract ProgramArguments.1 raw "$LA/io.github.gitzilla.rotate.plist")" "launchd: rotate absolute path"
assert_eq check "$(plutil -extract ProgramArguments.2 raw "$LA/io.github.gitzilla.rotate.plist")" "launchd: rotate check"
assert_eq 3 "$(grep -c '^bootout' "$T/launchctl.log")" "launchd: one bootout per job (not-loaded error ignored)"
assert_eq 3 "$(grep -c '^bootstrap' "$T/launchctl.log")" "launchd: one bootstrap per job"
assert_eq "bootout print bootstrap" "$(head -n3 "$T/launchctl.log" | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')" "launchd: bootout, wait via print, then bootstrap"
assert_contains "$(grep '^bootstrap' "$T/launchctl.log" | head -n1)" "bootstrap gui/$(id -u) $LA/io.github.gitzilla.agent.plist" "launchd: bootstrap args"
GITZILLA_INSTALL_STOP_AFTER=launchd run --from-step launchd
assert_eq 0 "$(rc)" "launchd rerun ok"
# bootout race: the label lingers for 2 print calls, then the first bootstrap fails once
rm -f "$T/launchctl.log"; echo 2 > "$T/lc.print.left"; : > "$T/lc.bootstrap.fail"
GITZILLA_INSTALL_STOP_AFTER=launchd run --from-step launchd
assert_eq 0 "$(rc)" "launchd: retries bootstrap once after a failure"
assert_eq 4 "$(grep -c '^bootstrap' "$T/launchctl.log")" "launchd: agent bootstrapped twice (one retry), the others once"
assert_eq 5 "$(grep -c '^print' "$T/launchctl.log")" "launchd: waits via print until the label is gone (agent: 2 lingering + 1, others 1 each)"
rm -f "$T/launchctl.log"; : > "$T/lc.bootstrap.fail"; echo 0 > "$T/lc.print.left"
cat > "$S/launchctl2" <<STUB
#!/bin/sh
[ "\$1" = bootstrap ] && exit 5
exit 0
STUB
chmod +x "$S/launchctl2"
GITZILLA_LAUNCHCTL_CMD="$S/launchctl2" GITZILLA_INSTALL_STOP_AFTER=launchd run --from-step launchd
assert_eq 1 "$(rc)" "launchd: bootstrap failing twice dies"

# full chain from a mid step: skips earlier steps, runs the rest, failures in self-test are recorded not fatal
reset
write_config
mkbare alice/r1; printf 'alice/r1 public\n' > "$STATE/repos.txt"
mkkey ghauth; mkkey sign
mkdir -p "$HOME/.ssh"; cp "$T/keys/ghauth.pub" "$HOME/.ssh/github-auth.pub"; git config --global user.signingkey "$T/keys/sign.pub"
cp "$T/keys/ghauth.pub" "$T/curl/auth.keys"; signing_json sign
runin 'yes\ny\nn\n' --from-step mirrors
assert_eq 0 "$(rc)" "chain from mirrors: exit 0 even with a failed self-test row"
case "$(out)" in *"== step: prereqs"*|*"== step: worker"*|*"== step: hook"*|*"== step: repos"*) _bad "--from-step mirrors skipped earlier steps" ;; *) _ok ;; esac
assert_contains "$(out)" "== step: mirrors" "chain: mirrors ran"
assert_contains "$(out)" "== step: self-test" "chain: self-test ran"
assert_eq self-test "$(step_file)" "chain: last step recorded"
assert_eq "gh" "$(cat "$T/rotate.log")" "chain: first-rotation runs rotate gh"
assert_contains "$(cat "$STATE/install-selftest.log")" "row2 FAIL" "self-test: failure recorded"
assert_contains "$(cat "$STATE/install-selftest.log")" "row1 pass" "self-test: pass recorded"
assert_contains "$(out)" "Row 2 result: an orange (🟠) alert reached your phone within 30 seconds?" "M11: self-test row 2 targets the phone within 30 s"
# finished install: plain rerun does nothing
run
assert_eq 0 "$(rc)" "rerun after completion: exit 0"
assert_contains "$(out)" "already complete" "rerun after completion says so"
# resume after the recorded step (no --from-step)
echo hook > "$STATE/install-step"; echo '[{"nameWithOwner":"alice/r1","visibility":"PUBLIC"}]' > "$T/gh.repos"; rm -f "$STATE/repos.txt"
GITZILLA_INSTALL_STOP_AFTER=repos run
assert_eq 0 "$(rc)" "resume ok"
assert_contains "$(out)" "== step: repos" "resume starts after the recorded step"
case "$(out)" in *"== step: hook"*) _bad "resume must not rerun hook" ;; *) _ok ;; esac

finish
