#!/usr/bin/env bash
# install.sh [--from-step <name>] — guided, resumable install of the account watchdog. Compatible with macOS bash 3.2.
#
# Steps (in order): prereqs note-key worker github-app hook repos mirrors known-keys launchd first-rotation self-test
# $STATE/install-step holds the last completed step; a rerun resumes after it. --from-step <name> forces the start.
#
# No secret is ever written to disk or to the log: WEBHOOK_SECRET and NTFY_TOPIC are printed once and piped to
# `wrangler secret put` on stdin; the (optional) Slack URL is read silently and piped the same way.
#
# Env overrides (tests): WATCHDOG_GH_CMD, WATCHDOG_NPM_CMD, WATCHDOG_NPX_CMD, WATCHDOG_OPEN_CMD, WATCHDOG_PBPASTE_CMD,
# WATCHDOG_CURL, WATCHDOG_LAUNCHCTL_CMD, WATCHDOG_RM_CMD, WATCHDOG_LAUNCHD_POLL/RETRY, WATCHDOG_RECONCILE_CMD, WATCHDOG_ROTATE_CMD, WATCHDOG_SECRETIVE_APP,
# WATCHDOG_REMOTE_URL_TEMPLATE, WATCHDOG_POLL_INTERVAL, WATCHDOG_POLL_TIMEOUT, WATCHDOG_INSTALL_STOP_AFTER (stop
# after that step).
# Install-time setting: WATCHDOG_DRILL_REPO (name of the throwaway drill repo; default watchdog-drill), saved in the
# config as DRILL_REPO by the worker step. WATCHDOG_ALERT_TZ (IANA zone for the local time in alerts; default: the
# config's ALERT_TZ, else the Mac's zone from /etc/localtime), deployed as the Worker var ALERT_TZ and saved in the
# config. WATCHDOG_LOCALTIME (tests) replaces /etc/localtime; WATCHDOG_NODE_PATH_FILE (tests) replaces scanner/node-path.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/bin/lib.sh"
WATCHDOG_HOME="$here"
GH="${WATCHDOG_GH_CMD:-gh}"
NPM="${WATCHDOG_NPM_CMD:-npm}"
NPX="${WATCHDOG_NPX_CMD:-npx}"
OPEN="${WATCHDOG_OPEN_CMD:-open}"
PBPASTE="${WATCHDOG_PBPASTE_CMD:-pbpaste}"
CURL="${WATCHDOG_CURL:-curl}"
LAUNCHCTL="${WATCHDOG_LAUNCHCTL_CMD:-launchctl}"
RM="${WATCHDOG_RM_CMD:-rm}"
LPOLL="${WATCHDOG_LAUNCHD_POLL:-0.25}"
LRETRY="${WATCHDOG_LAUNCHD_RETRY:-1}"
RECONCILE="${WATCHDOG_RECONCILE_CMD:-$WATCHDOG_HOME/bin/reconcile}"
ROTATE="${WATCHDOG_ROTATE_CMD:-$WATCHDOG_HOME/bin/rotate}"
SECRETIVE_APP="${WATCHDOG_SECRETIVE_APP:-/Applications/Secretive.app}"
REMOTE_TPL="${WATCHDOG_REMOTE_URL_TEMPLATE:-git@github.com:%s.git}"
POLL_INTERVAL="${WATCHDOG_POLL_INTERVAL:-5}"
POLL_TIMEOUT="${WATCHDOG_POLL_TIMEOUT:-180}"
KEY_RE='^(ssh-|ecdsa-|sk-)[^ ]+ [A-Za-z0-9+/=]+'
LABEL_PREFIX="io.github.account-watchdog"
STEPS="prereqs note-key worker github-app hook repos mirrors known-keys launchd first-rotation self-test"
STEPFILE="$STATE/install-step"
PUBFILE="$WATCHDOG_CONFIG_DIR/push-note.pub"
HOOK="" # set by step_hook from core.hooksPath
HOOK_MARK="# account-watchdog: push note (fail-open)"
HOOK_ANCHOR='done <<< "$input"'
HOOK_STANDALONE="# account-watchdog standalone pre-push hook"
HOOK_PREV_NAME="pre-push.account-watchdog-prev"
HOOK_PREV_LINK="account-watchdog-prev/pre-push" # runs the moved hook under the name pre-push (basename dispatch)
DRILL_DEFAULT="watchdog-drill"
APP_PREFIX="account-watchdog-"
APP_NAME_MAX=34 # GitHub's limit for a GitHub App name
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
export GIT_TERMINAL_PROMPT=0

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; wd_log "install: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing prerequisite: $1"; }
ask_yes() { # prompt -> 0 on y/yes
  local a; printf '%s [y/N] ' "$1"; read -r a || a=""
  case "$a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
wait_enter() { local _x; printf '%s ' "${1:-Press Enter to continue.}"; read -r _x || true; }
atomic_write() { local tmp="$1.tmp.$$"; cat > "$tmp" && mv -f "$tmp" "$1"; }
fp_of() { ssh-keygen -lf - 2>/dev/null; } # public key line on stdin

require_config() {
  [ -n "${WATCHDOG_URL:-}" ] && [ -n "${OWNER:-}" ] || die "no config ($WATCHDOG_CONFIG_DIR/config): run the worker step first"
  # configs written before APP_NAME / DRILL_REPO existed get the defaults
  APP_NAME="${APP_NAME:-$(app_name_for "$OWNER")}"
  DRILL_REPO="${DRILL_REPO:-$DRILL_DEFAULT}"
}

# app_name_for <login>: GitHub App names are globally unique, so the app is per user:
# account-watchdog-<lower-cased login>, cut to GitHub's 34-char limit (and no trailing hyphen after the cut).
app_name_for() {
  local n
  n="$APP_PREFIX$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  n="$(printf '%s' "$n" | cut -c1-"$APP_NAME_MAX")"
  while :; do case "$n" in *-) n="${n%-}" ;; *) break ;; esac; done
  printf '%s\n' "$n"
}

# ---------------------------------------------------------------------------------------------------------------
step_prereqs() {
  local c
  for c in git jq curl openssl ssh-keygen node plutil awk sed; do need "$c"; done
  for c in "$GH" "$NPM" "$NPX" "$OPEN" "$LAUNCHCTL"; do need "$c"; done
  [ -d "$SECRETIVE_APP" ] || die "Secretive is not installed ($SECRETIVE_APP)"
  [ -f "$here/worker/package.json" ] || die "worker/ not found next to install.sh"
  "$GH" auth status >/dev/null 2>&1 || die "gh is not logged in: run 'gh auth login' first"
  local ghauth="$HOME/.ssh/github-auth.pub"
  if [ ! -s "$ghauth" ] || ! head -n1 "$ghauth" | grep -Eq "$KEY_RE"; then
    cat >&2 <<'EOF'
install: ~/.ssh/github-auth.pub (your Secretive GitHub authentication key) is missing or not a public key.
  1. In Secretive click "+", name the key  github-auth  (Require authentication: Touch ID).
  2. Save its public key as ~/.ssh/github-auth.pub ("Copy Public Key", then  pbpaste > ~/.ssh/github-auth.pub ).
  3. Add it at https://github.com/settings/keys as an Authentication key.
  4. In ~/.ssh/config:
       Host github.com
         IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
         IdentityFile ~/.ssh/github-auth.pub
         IdentitiesOnly yes
  5. Check with  ssh -T git@github.com , then rerun ./install.sh  (README: "Secretive SSH setup").
EOF
    wd_log "install: prereqs: ~/.ssh/github-auth.pub missing"
    exit 1
  fi
  local signers
  signers="$(wd_allowed_signers)"
  if [ ! -f "$signers" ]; then
    say "WARNING: no allowed-signers file at $signers (git config gpg.ssh.allowedSignersFile, else"
    say "  ~/.config/git/allowed_signers). The unsigned-commit check then treats every commit as unsigned, so every"
    say "  push without a note (even one of yours) turns into a red alert. Set up commit signing first: README, \"Commit signing\"."
  fi
  say "prerequisites ok"
}

step_note_key() {
  mkdir -p "$WATCHDOG_CONFIG_DIR" || die "cannot create $WATCHDOG_CONFIG_DIR"
  if [ -s "$PUBFILE" ] && head -n1 "$PUBFILE" | grep -Eq "$KEY_RE" && head -n1 "$PUBFILE" | fp_of >/dev/null; then
    say "push-note public key already present: $(head -n1 "$PUBFILE" | fp_of)"
    return 0
  fi
  cat <<'EOF'
Create the note key in Secretive:
  1. Open Secretive, click "+", name it  push-note
  2. Authentication: choose "Not Required" (the pre-push hook must send a note without a Touch ID prompt;
     the key only proves that a note came from this Mac, it cannot push code)
  3. Click the new key, then "Copy Public Key" (the clipboard now holds one line)
EOF
  wait_enter "Press Enter when the public key is on the clipboard."
  local line
  line="$("$PBPASTE" 2>/dev/null | head -n1)"
  printf '%s\n' "$line" | grep -Eq "$KEY_RE" || die "the clipboard does not hold a public key line"
  printf '%s\n' "$line" | fp_of >/dev/null || die "ssh-keygen cannot parse that key"
  case "$line" in ssh-rsa*) die "use an ECDSA (Secretive) key, not RSA" ;; esac
  printf '%s\n' "$line" | atomic_write "$PUBFILE" || die "cannot write $PUBFILE"
  say "saved $PUBFILE: $(printf '%s\n' "$line" | fp_of)"
}

wrangler_tokens_left() { # prints the offending files
  local f
  for f in "$HOME/.wrangler/config/default.toml" "$HOME/Library/Preferences/.wrangler/config/default.toml" \
           ${XDG_CONFIG_HOME:+"$XDG_CONFIG_HOME/.wrangler/config/default.toml"}; do
    [ -f "$f" ] && grep -Eq 'oauth_token|refresh_token|api_token' "$f" && printf '%s\n' "$f"
  done
  return 0
}

# worker_die <msg>: log out of wrangler (best effort), report any credential still on disk, then die.
worker_die() {
  local left
  ( cd "$here/worker" && "$NPX" wrangler logout ) >/dev/null 2>&1
  left="$(wrangler_tokens_left | tr '\n' ' ')"
  [ -z "$left" ] || set -- "$1 (wrangler credentials remain in: $left- delete them)"
  die "$1"
}

step_index() { # name -> 1-based index in STEPS, 0 if unknown
  local n=0 x
  for x in $STEPS; do n=$((n + 1)); [ "$x" = "$1" ] && { echo "$n"; return; }; done
  echo 0
}

step_worker() {
  [ -s "$PUBFILE" ] || die "no $PUBFILE: run the note-key step first"
  local owner pub out url wsec topic slack left last mode=fresh ans drill app tz
  owner="${OWNER:-$("$GH" api user --jq .login 2>/dev/null)}"
  [ -n "$owner" ] || die "cannot determine the GitHub login (gh api user)"
  app="$(app_name_for "$owner")"
  drill="${WATCHDOG_DRILL_REPO:-${DRILL_REPO:-$DRILL_DEFAULT}}"
  case "$drill" in ''|.|..|*[!A-Za-z0-9._-]*) die "invalid drill repo name '$drill' (WATCHDOG_DRILL_REPO: a repository name, no owner)" ;; esac
  tz="${WATCHDOG_ALERT_TZ:-${ALERT_TZ:-}}"
  if [ -z "$tz" ]; then
    tz="$(readlink "${WATCHDOG_LOCALTIME:-/etc/localtime}" 2>/dev/null)"
    case "$tz" in *zoneinfo/*) tz="${tz##*zoneinfo/}" ;; *) tz="" ;; esac
  fi
  case "$tz" in ''|/*|*..*|*[!A-Za-z0-9_+/-]*) [ -z "$tz" ] || say "note: '$tz' is not a time-zone name; alerts use UTC"; tz=UTC ;; esac
  pub="$(head -n1 "$PUBFILE")"
  last="$(cat "$STEPFILE" 2>/dev/null)"
  if [ -f "$WATCHDOG_CONFIG_DIR/config" ] || { [ -n "$last" ] && [ "$(step_index "$last")" -ge "$(step_index worker)" ]; }; then
    say "The Worker secrets already exist. Regenerating them breaks the GitHub App webhook (its secret must be"
    say "edited by hand) and the phone subscription."
    printf 'Press Enter to KEEP them (redeploy only), or type rotate to regenerate: '
    read -r ans || ans=""
    if [ "$ans" = "rotate" ]; then mode=rotate; else mode=keep; fi
  fi
  out="$(mktemp)" || die "mktemp failed"
  (
    cd "$here/worker" || exit 1
    "$NPM" ci || exit 1
    "$NPX" wrangler login || exit 1
    "$NPX" wrangler deploy --var "NOTE_PUBKEY:$pub" --var "ALERT_TZ:$tz" 2>&1 | tee "$out"
    exit "${PIPESTATUS[0]}"
  ) || { rm -f "$out"; worker_die "worker build/deploy failed"; }
  url="$(grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' "$out" | head -n1)"
  rm -f "$out"
  [ -n "$url" ] || worker_die "could not find the workers.dev URL in the deploy output"

  if [ "$mode" = keep ]; then
    say "keeping the existing secrets (no secret put)"
  else
    wsec="$(openssl rand -hex 32)"
    topic="wd-$(openssl rand -hex 16)"
    say ""
    say "WEBHOOK_SECRET (shown once; you paste it into the GitHub App form in the github-app step):"
    say "  $wsec"
    say "NTFY_TOPIC (shown once; subscribe to it in the ntfy app on your phone):"
    say "  $topic"
    say ""
    printf 'Slack incoming-webhook URL, or press Enter to skip Slack (input hidden): '
    read -rs slack || slack=""; echo
    case "$slack" in ''|https://*) ;; *) worker_die "the Slack webhook URL must start with https://" ;; esac
    ( cd "$here/worker" || exit 1
      printf '%s' "$wsec" | "$NPX" wrangler secret put WEBHOOK_SECRET || exit 1
      printf '%s' "$topic" | "$NPX" wrangler secret put NTFY_TOPIC || exit 1
      # the Worker treats SLACK_WEBHOOK_URL as optional (notify.js posts to Slack only when it is set)
      if [ -n "$slack" ]; then printf '%s' "$slack" | "$NPX" wrangler secret put SLACK_WEBHOOK_URL || exit 1; fi
    ) || worker_die "wrangler secret put failed"
    [ -n "$slack" ] || say "Slack skipped: alerts go to the phone (ntfy) only"
    wsec=""; topic=""; slack=""
    # Only an app that already exists needs its webhook secret edited; before that the create flow uses the new secret.
    if [ "$mode" = rotate ]; then
      if [ -n "$last" ] && [ "$(step_index "$last")" -ge "$(step_index github-app)" ] || [ -f "$STATE/queue-cursor" ]; then
        : > "$STATE/install-secrets-rotated"
      else
        rm -f "$STATE/install-secrets-rotated"
      fi
    fi
  fi

  ( cd "$here/worker" && "$NPX" wrangler logout ) >/dev/null 2>&1 || worker_die "wrangler logout failed"
  left="$(wrangler_tokens_left)"
  [ -z "$left" ] || die "wrangler credentials remain in: $left (delete them, then rerun --from-step worker)"

  ( umask 077
    { printf 'OWNER=%q\n' "$owner"
      printf 'WATCHDOG_URL=%q\n' "$url"
      printf 'NOTE_PUBKEY_FILE=%q\n' "$PUBFILE"
      printf 'WATCHDOG_HOME=%q\n' "$WATCHDOG_HOME"
      printf 'APP_NAME=%q\n' "$app"
      printf 'DRILL_REPO=%q\n' "$drill"
      printf 'ALERT_TZ=%q\n' "$tz"
    } | atomic_write "$WATCHDOG_CONFIG_DIR/config" ) || die "cannot write the config"
  chmod 600 "$WATCHDOG_CONFIG_DIR/config"
  # shellcheck disable=SC1090
  . "$WATCHDOG_CONFIG_DIR/config"
  say "worker deployed at $WATCHDOG_URL; config written"
}

# queue_scan <after>: signed, paged read of /queue. Sets QMAX (highest seq seen, at least <after>) and QDRILL=1 if an
# event for the drill repo ($DRILL_REPO, any owner, case-insensitive) was seen. Returns 1 if the queue could not be read.
queue_scan() {
  local after="$1" d sig msg code next drill
  drill="$(printf '%s' "${DRILL_REPO:-$DRILL_DEFAULT}" | tr '[:upper:]' '[:lower:]')"
  QMAX="$after"; QDRILL=0
  d="$(mktemp -d)" || return 1
  while :; do
    printf '{"ts":%s}' "$(date +%s)" > "$d/msg"
    sig="$(wd_sign account-watchdog-queue "$d/msg")" || { rm -rf "$d"; return 1; }
    msg="$(base64 < "$d/msg" | tr -d '\n')"
    sig="$(printf '%s' "$sig" | base64 | tr -d '\n')"
    code="$("$CURL" --max-time 10 -sS -o "$d/out" -w '%{http_code}' -H "X-Watchdog-Auth: $msg.$sig" \
            "$WATCHDOG_URL/queue?after=$QMAX" 2>/dev/null </dev/null)"
    [ "$code" = "200" ] || { rm -rf "$d"; return 1; }
    jq -e --arg drill "$drill" '[.events[]? | select((.repo // "") | ascii_downcase | endswith("/" + $drill))] | length > 0' \
      "$d/out" >/dev/null 2>&1 && QDRILL=1
    next="$(jq -r '.next' "$d/out" 2>/dev/null)"
    case "$next" in ''|*[!0-9]*) rm -rf "$d"; return 1 ;; esac
    [ "$next" -gt "$QMAX" ] || break
    QMAX="$next"
  done
  rm -rf "$d"
  return 0
}

step_github_app() {
  require_config
  local rotated="$STATE/install-secrets-rotated"
  if [ -f "$rotated" ]; then
    cat <<EOF

The Worker secrets were regenerated. The GitHub App already exists: do NOT create another one.
  1. Edit the EXISTING app's webhook secret at https://github.com/settings/apps/$APP_NAME/advanced
     (Webhook secret: paste the new WEBHOOK_SECRET printed in the worker step, then Save changes).
  2. Re-subscribe the phone to the new ntfy topic (printed in the worker step).
EOF
    "$OPEN" "https://github.com/settings/apps/$APP_NAME/advanced" >/dev/null 2>&1 || true
    wait_enter "Press Enter once the webhook secret is updated and the phone is re-subscribed."
  else
    cat <<EOF

Create the GitHub App at https://github.com/settings/apps/new with exactly these settings
(if the app already exists, edit its webhook secret at https://github.com/settings/apps/$APP_NAME/advanced instead):
  GitHub App name   : $APP_NAME
  Homepage URL      : https://github.com/$OWNER
  Webhook           : Active
  Webhook URL       : $WATCHDOG_URL/webhook
  Webhook secret    : the WEBHOOK_SECRET printed in the worker step (shown only once; if you lost it, rerun
                      --from-step worker and type rotate to regenerate the secrets)
  Permissions       : Repository > Contents: Read-only ; Metadata: Read-only (nothing else)
  Subscribe to events: Push (installation events are sent to every app; tick Installation and
                      Installation repositories too if the form lists them)
  Where installable : Only on this account
After creating it: generate a private key (GitHub requires one before the app can be installed; the file
lands in ~/Downloads and is deleted below), then install the app on ALL repositories.
EOF
    "$OPEN" "https://github.com/settings/apps/new" >/dev/null 2>&1 || true
    wait_enter "Press Enter once the app is created, a key generated and the app installed on all repos."
  fi

  local pems=() f
  # GitHub names the download <app-name>.<date>.private-key.pem
  for f in "$HOME"/Downloads/"$APP_NAME".*.private-key*.pem; do [ -e "$f" ] && pems+=("$f"); done
  if [ "${#pems[@]}" -gt 0 ]; then
    say "Private key file(s) of the $APP_NAME app to delete (GitHub keeps only the public half):"
    for f in "${pems[@]}"; do printf '  %s\n' "$f"; done
    ask_yes "Delete these $APP_NAME private key files now?" || die "private keys must not stay on disk; rerun --from-step github-app"
    for f in "${pems[@]}"; do "$RM" -f -- "$f" || true; done
  else
    say "no $APP_NAME.*.private-key*.pem found in ~/Downloads"
  fi
  for f in "$HOME"/Downloads/"$APP_NAME".*.private-key*.pem; do
    [ -e "$f" ] && die "a private key file is still in ~/Downloads: $f"
  done

  say ""
  if ! "$GH" repo view "$OWNER/$DRILL_REPO" >/dev/null 2>&1 </dev/null; then
    say "The drill repo $OWNER/$DRILL_REPO does not exist. The installer and the drill push to it (never to a real repo)."
    ask_yes "Create it now as a private repo (gh repo create $OWNER/$DRILL_REPO --private --add-readme)?" \
      || die "a drill repo is needed: create $OWNER/$DRILL_REPO (or set WATCHDOG_DRILL_REPO and rerun --from-step worker), then rerun --from-step github-app"
    "$GH" repo create "$OWNER/$DRILL_REPO" --private --add-readme --description "throwaway repo for account-watchdog drills" \
      </dev/null >/dev/null 2>&1 || die "gh repo create $OWNER/$DRILL_REPO failed; create it by hand, then rerun --from-step github-app"
    say "created $OWNER/$DRILL_REPO"
  fi
  queue_scan 0 || die "cannot read the Worker queue ($WATCHDOG_URL/queue); check the deploy, then rerun --from-step github-app"
  local base="$QMAX"
  say "Verify: in your drill repo $OWNER/$DRILL_REPO make a commit and push it (any branch)."
  say "  (no clone yet?  gh repo clone $OWNER/$DRILL_REPO  or  git clone git@github.com:$OWNER/$DRILL_REPO.git)"
  say "This push raises an orange (🟠) alert on your phone: expected, the hook that sends push notes is installed later."
  say "Waiting up to ${POLL_TIMEOUT}s for the push to appear in the Worker queue..."
  local waited=0
  while :; do
    if queue_scan "$base" && [ "$QDRILL" = 1 ]; then
      say "push seen in /queue: webhook path works"
      # an existing cursor belongs to the agent: only create one when none exists
      if [ ! -e "$STATE/queue-cursor" ]; then printf '%s\n' "$QMAX" | atomic_write "$STATE/queue-cursor" || die "cannot write queue-cursor"; fi
      rm -f "$rotated"
      return 0
    fi
    [ "$waited" -ge "$POLL_TIMEOUT" ] && break
    sleep "$POLL_INTERVAL"; waited=$((waited + POLL_INTERVAL))
  done
  die "no new push from $OWNER/$DRILL_REPO reached the queue (check the app's Recent Deliveries, then rerun --from-step github-app)"
}

# render_hook <out>: the standalone hook from hooks/pre-push with the absolute WATCHDOG_HOME (bash substitution, so no
# character of the path is special; step_hook already refuses quotes, $, backquotes and backslashes in it).
render_hook() {
  local t
  t="$(cat "$here/hooks/pre-push")" || return 1
  printf '%s\n' "${t//@WATCHDOG_HOME@/$WATCHDOG_HOME}" > "$1"
}

# install_standalone: write the standalone hook to $HOOK (atomic, mode 755).
install_standalone() {
  local tmp="$HOOK.tmp.$$"
  render_hook "$tmp" || { rm -f "$tmp"; die "cannot render hooks/pre-push"; }
  chmod 755 "$tmp" && mv -f "$tmp" "$HOOK" || { rm -f "$tmp"; die "cannot write $HOOK"; }
}

# step_hook: the global pre-push hook lives in core.hooksPath (read with --includes, so a value from an included
# dotfile counts; set to ~/.config/git/hooks, after a yes, only when it is unset everywhere in the global config).
#   - hook with the polin-guard anchor or our marker: insert / refresh the two note lines (polin-guard scans first);
#   - our standalone hook: re-render it from hooks/pre-push when it differs (a moved checkout);
#   - any other existing hook (after a yes): back it up, move it aside to pre-push.account-watchdog-prev and install
#     the standalone hook, which runs it through the symlink account-watchdog-prev/pre-push (so it still sees the name
#     pre-push) with the same stdin and arguments and exits with its status. Moving it aside (rather than editing it)
#     works for hooks in any language and any shape. A hook that was not executable stays so: git ignored it, and the
#     standalone hook ignores it too;
#   - no hook: install the standalone hook.
# Also records the absolute node (scanner/node-path) and jq ($WATCHDOG_CONFIG_DIR/jq-path) for hooks run by GUI clients.
step_hook() {
  case "$WATCHDOG_HOME" in *\"*|*\$*|*\`*|*\\*) die "unsupported characters in $WATCHDOG_HOME" ;; esac
  [ -f "$here/hooks/pre-push" ] || die "hooks/pre-push not found next to install.sh"
  local dir set_path=0 tmp prev link existing
  dir="$(git config --global --includes --get core.hooksPath 2>/dev/null)"
  case "$dir" in "~") dir="$HOME" ;; "~/"*) dir="$HOME/${dir#\~/}" ;; esac
  case "$dir" in
    ""|/*) ;;
    *) die "the global core.hooksPath '$dir' is a relative path (git reads it relative to each repo, so it is not one global hooks directory); set an absolute one, e.g.  git config --global core.hooksPath ~/.config/git/hooks , then rerun --from-step hook; nothing changed" ;;
  esac
  if [ -z "$dir" ]; then
    dir="$HOME/.config/git/hooks"; set_path=1
    say "No global git hooks directory is set. The push note needs a global pre-push hook, so the installer would set"
    say "  git config --global core.hooksPath $dir"
    say "A global hooks path makes git ignore each repo's own .git/hooks; the installed hook chains to the repo's"
    say ".git/hooks/pre-push itself, but other repo-local hooks (pre-commit, commit-msg, ...) stop running."
    existing="$(ls -A "$dir" 2>/dev/null | tr '\n' ' ')"
    [ -z "$existing" ] || say "$dir already holds: $existing- these become active too."
    ask_yes "Set core.hooksPath to $dir and install the pre-push hook there?" \
      || die "core.hooksPath not set; nothing changed. To continue, set your own global hooks dir (git config --global core.hooksPath <absolute dir>) and rerun ./install.sh --from-step hook"
  fi
  HOOK="$dir/pre-push"; tmp="$HOOK.tmp.$$"; prev="$dir/$HOOK_PREV_NAME"; link="$dir/$HOOK_PREV_LINK"
  if [ -f "$HOOK" ] && grep -qxF "$HOOK_STANDALONE" "$HOOK"; then
    render_hook "$tmp" || { rm -f "$tmp"; die "cannot render hooks/pre-push"; }
    if cmp -s "$tmp" "$HOOK"; then rm -f "$tmp"; say "standalone hook already up to date: $HOOK"
    else chmod 755 "$tmp" && mv -f "$tmp" "$HOOK" || { rm -f "$tmp"; die "cannot replace the hook"; }; say "standalone hook refreshed: $HOOK"; fi
  elif [ -f "$HOOK" ] && { grep -qxF "$HOOK_MARK" "$HOOK" || grep -qxF "$HOOK_ANCHOR" "$HOOK"; }; then
    hook_insert_note || return 1
  elif [ -e "$HOOK" ]; then
    [ -f "$HOOK" ] || die "$HOOK is not a regular file; nothing changed"
    [ ! -e "$prev" ] || die "$prev already exists (a hook chained earlier); merge the two by hand, then rerun --from-step hook; nothing changed"
    say "$HOOK is an existing pre-push hook. The installer moves it to $prev and installs its own hook, which runs"
    say "yours with the same input and arguments (as $link) and blocks the push when yours fails."
    ask_yes "Chain your existing pre-push hook this way?" \
      || die "existing hook left as it is; nothing changed. Add the note line to it by hand (README), or rerun --from-step hook"
    [ -e "$HOOK.bak-account-watchdog" ] || cp -p "$HOOK" "$HOOK.bak-account-watchdog" || die "cannot back up the hook"
    mv "$HOOK" "$prev" || die "cannot move $HOOK aside"
    mkdir -p "${link%/*}" && ln -sfn "../$HOOK_PREV_NAME" "$link" || die "cannot link $link"
    install_standalone
    if [ -x "$prev" ]; then
      say "existing hook moved to $prev and chained from the new $HOOK (backup: $HOOK.bak-account-watchdog)"
    else
      say "existing hook moved to $prev; it was not executable, so git never ran it, and it is NOT chained (make it"
      say "executable yourself if you want it to run). Backup: $HOOK.bak-account-watchdog"
    fi
  else
    mkdir -p "$dir" || die "cannot create $dir"
    install_standalone
    say "standalone pre-push hook installed: $HOOK"
  fi
  # a chained hook whose account-watchdog-prev/pre-push link went missing (deleted by hand, older install) is linked again
  if [ -e "$prev" ] && [ "$(readlink "$link" 2>/dev/null)" != "../$HOOK_PREV_NAME" ]; then
    [ -d "$link" ] && [ ! -L "$link" ] && die "$link is a directory; remove it, then rerun --from-step hook"
    mkdir -p "${link%/*}" && ln -sfn "../$HOOK_PREV_NAME" "$link" || die "cannot link $link"
    say "relinked the chained hook: $link -> ../$HOOK_PREV_NAME"
  fi
  record_tool_paths
  if [ "$set_path" = 1 ]; then
    git config --global core.hooksPath "$dir" || die "cannot set core.hooksPath"
    printf '%s\n' "$dir" | atomic_write "$STATE/install-set-hookspath" || die "cannot record install-set-hookspath"
    say "core.hooksPath set to $dir (recorded in $STATE/install-set-hookspath for uninstall)"
  fi
  return 0
}

# record_tool_paths: absolute node and jq for hooks run with a minimal PATH (GUI git clients).
record_tool_paths() {
  local n j
  # the real binary, never a version-manager shim (a shim may not work from a GUI client or another HOME)
  n="$(node -p process.execPath 2>/dev/null </dev/null)" || n=""
  [ -x "$n" ] || n="$(command -v node 2>/dev/null)"
  j="$(command -v jq 2>/dev/null)"
  case "$n" in /*) printf '%s\n' "$n" | atomic_write "${WATCHDOG_NODE_PATH_FILE:-$WATCHDOG_HOME/scanner/node-path}" || die "cannot write scanner/node-path" ;; esac
  case "$j" in /*) mkdir -p "$WATCHDOG_CONFIG_DIR" && printf '%s\n' "$j" | atomic_write "$WATCHDOG_CONFIG_DIR/jq-path" || die "cannot write jq-path" ;; esac
  return 0
}

# hook_insert_note: a polin-guard-shaped hook (anchor) or one already carrying the marker: insert or refresh the note.
hook_insert_note() {
  local expect cur shape tmp="$HOOK.tmp.$$"
  expect="printf '%s\\n' \"\$input\" | \"$WATCHDOG_HOME/bin/note\" \"\$@\" || true"
  if grep -qxF "$HOOK_MARK" "$HOOK"; then
    cur="$(grep -xF -A1 -- "$HOOK_MARK" "$HOOK" | sed -n 2p)"
    if [ "$cur" = "$expect" ]; then say "hook already contains the push note"; return 0; fi
    [ -e "$HOOK.bak-account-watchdog" ] || cp -p "$HOOK" "$HOOK.bak-account-watchdog" || die "cannot back up the hook"
    cp -p "$HOOK" "$tmp" || die "cannot copy the hook"
    # replace the next line only if it is a note line; otherwise insert a fresh one and leave that line alone
    shape=0
    case "$cur" in "printf '%s\\n' \"\$input\" | \""*) case "$cur" in *'/bin/note" "$@"'*) shape=1 ;; esac ;; esac
    SHAPE="$shape" EXPECT="$expect" awk -v mark="$HOOK_MARK" '
      skip { skip = 0; if (ENVIRON["SHAPE"] == "1") { print ENVIRON["EXPECT"]; next } else { print ENVIRON["EXPECT"] } }
      { print }
      $0 == mark && !done { skip = 1; done = 1 }
      END { if (skip) print ENVIRON["EXPECT"] }' "$HOOK" > "$tmp" || { rm -f "$tmp"; die "cannot edit the hook"; }
    chmod +x "$tmp"; mv -f "$tmp" "$HOOK" || die "cannot replace the hook"
    say "hook note path updated (backup: $HOOK.bak-account-watchdog)"
    return 0
  fi
  grep -qxF "$HOOK_ANCHOR" "$HOOK" || die "anchor line '$HOOK_ANCHOR' not found in $HOOK; nothing changed"
  [ -e "$HOOK.bak-account-watchdog" ] || cp -p "$HOOK" "$HOOK.bak-account-watchdog" || die "cannot back up the hook"
  cp -p "$HOOK" "$tmp" || die "cannot copy the hook"
  EXPECT="$expect" awk -v mark="$HOOK_MARK" -v anchor="$HOOK_ANCHOR" '
    { print }
    !done && $0 == anchor { print mark; print ENVIRON["EXPECT"]; done = 1 }' "$HOOK" > "$tmp" || { rm -f "$tmp"; die "cannot edit the hook"; }
  chmod +x "$tmp"
  mv -f "$tmp" "$HOOK" || die "cannot replace the hook"
  say "hook updated (backup: $HOOK.bak-account-watchdog)"
}

# repos.txt: "<lower-case slug> public|private" per line, the format reconcile and rotate use (wd_repos_from_gh).
step_repos() {
  require_config
  local json list owner
  owner="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
  json="$("$GH" repo list "$OWNER" --limit 1000 --json nameWithOwner,visibility 2>/dev/null </dev/null)" || json=""
  list="$(printf '%s' "$json" | wd_repos_from_gh "$owner" 2>/dev/null | sed '/^$/d' | sort -u)"
  [ -n "$list" ] || die "gh returned no repositories for $OWNER; refusing to write an empty repos.txt"
  mkdir -p "$STATE" || die "cannot create $STATE"
  printf '%s\n' "$list" | atomic_write "$STATE/repos.txt" || die "cannot write repos.txt"
  say "$(printf '%s\n' "$list" | wc -l | tr -d ' ') repositories listed"
}

step_mirrors() {
  [ -s "$STATE/repos.txt" ] || die "no $STATE/repos.txt: run the repos step first"
  local slug _vis _rest m failed="" url
  wd_ssh_env
  while read -r slug _vis _rest; do
    case "$slug" in ''|\#*) continue ;; esac
    m="$(mirror_path "$slug")"
    if [ -d "$m" ]; then
      wd_mirror_harden "$m" || failed="$failed $slug"
      git -C "$m" fetch --quiet --prune </dev/null >/dev/null 2>&1 || failed="$failed $slug"
    else
      mkdir -p "$(dirname "$m")"
      # shellcheck disable=SC2059
      url="$(printf "$REMOTE_TPL" "$slug")"
      if git clone --mirror --quiet "$url" "$m" </dev/null >/dev/null 2>&1; then
        wd_mirror_harden "$m" || failed="$failed $slug"
      else
        rm -rf "$m"; failed="$failed $slug"
      fi
    fi
  done < "$STATE/repos.txt"
  if [ -n "$failed" ]; then
    printf 'install: mirror failures:\n' >&2
    for slug in $failed; do printf '  %s\n' "$slug" >&2; done
    die "some mirrors failed; rerun with --from-step mirrors"
  fi
  # The single trust point: baseline every mirrored repo (needs the mirrors, so it runs after them).
  "$RECONCILE" seed || die "reconcile seed failed; rerun with --from-step mirrors"
  say "mirrors ready and seeded"
}

step_known_keys() {
  require_config
  local kk="$STATE/known-keys.txt" owner tmp auth sign line fp k
  if [ -f "$kk" ]; then say "known-keys.txt already exists; leaving it alone"; return 0; fi
  owner="$(printf '%s' "$OWNER" | tr '[:upper:]' '[:lower:]')"
  tmp="$(mktemp -d)" || die "mktemp failed"
  fetch() { # url outfile
    local code
    code="$("$CURL" --max-time 15 -sS -o "$2" -w '%{http_code}' "$1" 2>/dev/null </dev/null)"
    [ "$code" = "200" ]
  }
  fetch "https://github.com/$owner.keys" "$tmp/auth.out" || { rm -rf "$tmp"; die "cannot fetch https://github.com/$owner.keys"; }
  fetch "https://api.github.com/users/$owner/ssh_signing_keys?per_page=100" "$tmp/sign.out" \
    || { rm -rf "$tmp"; die "cannot fetch the signing keys"; }
  jq -e 'type == "array"' "$tmp/sign.out" >/dev/null 2>&1 || { rm -rf "$tmp"; die "signing keys response is not a JSON array"; }
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$tmp/auth.out" | grep -E "$KEY_RE" | awk '{print $1" "$2}' > "$tmp/auth.keys"
  jq -r '.[] | (.key // empty)' "$tmp/sign.out" | grep -E "$KEY_RE" | awk '{print $1" "$2}' > "$tmp/sign.keys"

  say ""
  say "Keys GitHub currently lists for $OWNER. These become the trusted baseline: any other key that appears is an alert."
  say "Authentication keys:"
  while IFS= read -r line; do printf '  %s\n' "$(printf '%s\n' "$line" | fp_of)"; done < "$tmp/auth.keys"
  say "Signing keys:"
  jq -r '.[] | select(.key != null) | ((.key | split(" ") | .[0:2] | join(" ")) + "\t" + ((.title // "") | gsub("[\\t\\n\\r]"; " ")))' \
    "$tmp/sign.out" > "$tmp/sign.tsv" 2>/dev/null
  local ktab=$'\t' ttl
  while IFS="$ktab" read -r line ttl; do
    [ -n "$line" ] || continue
    ttl="$(printf '%s' "$ttl" | tr -cd '[:print:]')"
    printf '  %s  [title: %s]\n' "$(printf '%s\n' "$line" | fp_of)" "$ttl"
  done < "$tmp/sign.tsv"
  say "Keys on this Mac, for comparison:"
  local ghauth="$HOME/.ssh/github-auth.pub" sk
  [ -f "$ghauth" ] && say "  github-auth.pub : $(head -n1 "$ghauth" | fp_of)"
  sk="$(git config --global --includes --get user.signingkey 2>/dev/null)"
  if [ -n "$sk" ]; then
    case "$sk" in
      key::*) line="${sk#key::}" ;;
      ssh-*|ecdsa-*|sk-*) line="$sk" ;;
      *) sk="${sk/#\~/$HOME}"; line="$(head -n1 "$sk" 2>/dev/null)" ;;
    esac
    [ -n "$line" ] && say "  signing key     : $(printf '%s\n' "$line" | fp_of)"
  fi
  [ -f "$ghauth" ] || { rm -rf "$tmp"; die "$ghauth not found; cannot confirm the authentication key"; }
  k="$(head -n1 "$ghauth" | awk '{print $1" "$2}')"
  grep -qxF "$k" "$tmp/auth.keys" || { rm -rf "$tmp"; die "~/.ssh/github-auth.pub is not an authentication key on GitHub; refusing to trust this list"; }
  say ""
  printf 'Every key above is yours? Type yes to trust them: '
  read -r k || k=""
  [ "$k" = "yes" ] || { rm -rf "$tmp"; die "not confirmed; known-keys.txt not written"; }
  mkdir -p "$STATE"
  ( umask 077
    { sed 's/$/ github-auth/' "$tmp/auth.keys"; sed 's/$/ signing/' "$tmp/sign.keys"; } | atomic_write "$kk" ) \
    || { rm -rf "$tmp"; die "cannot write known-keys.txt"; }
  chmod 600 "$kk"
  rm -rf "$tmp"
  say "known-keys.txt written"
}

render() { # template out
  sed -e "s|@LABEL@|$3|g" -e "s|@WATCHDOG_HOME@|$WATCHDOG_HOME|g" -e "s|@STATE@|$STATE|g" \
      -e "s|@CONFIG@|$WATCHDOG_CONFIG_DIR|g" "$1" > "$2"
}

step_launchd() {
  local dir="$HOME/Library/LaunchAgents" job label plist uid out n
  case "$WATCHDOG_HOME$STATE$WATCHDOG_CONFIG_DIR" in *\&*|*\|*|*\<*|*\>*|*\\*) die "unsupported characters in install paths" ;; esac
  mkdir -p "$dir" "$STATE/log" || die "cannot create $dir"
  uid="$(id -u)"
  for job in agent reconcile rotate; do
    label="$LABEL_PREFIX.$job"; plist="$dir/$label.plist"
    render "$here/launchd/$job.plist.tmpl" "$plist" "$label" || die "cannot render $job"
    plutil -lint "$plist" >/dev/null || die "rendered $plist is not a valid plist"
    out="$("$LAUNCHCTL" bootout "gui/$uid/$label" 2>&1)" || {
      case "$out" in
        *"not find"*|*"No such"*|*"not loaded"*|*"Could not find"*|*"not found"*|"") ;;
        *) say "note: bootout $label: $out" ;;
      esac
    }
    # bootout is asynchronous: wait (at most ~5 s) until the label is gone before bootstrapping
    n=0
    while "$LAUNCHCTL" print "gui/$uid/$label" >/dev/null 2>&1 && [ "$n" -lt 20 ]; do sleep "$LPOLL"; n=$((n + 1)); done
    "$LAUNCHCTL" bootstrap "gui/$uid" "$plist" || {
      sleep "$LRETRY"
      "$LAUNCHCTL" bootstrap "gui/$uid" "$plist" || die "launchctl bootstrap failed for $label"
    }
  done
  say "launchd jobs loaded: agent (5 min), reconcile (hourly), rotate (daily 10:00)"
}

step_first_rotation() {
  require_config
  "$ROTATE" gh || die "rotate gh did not finish; rerun with --from-step first-rotation"
}

step_self_test() {
  mkdir -p "$STATE"
  local log="$STATE/install-selftest.log" bad=0
  say ""
  say "Self-test (use your drill repo ${OWNER:+$OWNER/}${DRILL_REPO:-$DRILL_DEFAULT}):"
  say "  row 1: make a SIGNED commit and push it normally."
  if ask_yes "  Row 1 result: no alert appeared within 2 minutes?"; then
    echo "row1 pass" >> "$log"
  else
    echo "row1 FAIL" >> "$log"; bad=1
  fi
  say "  row 2: make a commit and push it with  git push --no-verify  (skips the hook, so no note is sent)."
  if ask_yes "  Row 2 result: an orange (🟠) alert reached your phone within 30 seconds?"; then
    echo "row2 pass" >> "$log"
  else
    echo "row2 FAIL" >> "$log"; bad=1
  fi
  if [ "$bad" -eq 0 ]; then say "self-test passed"; else say "self-test: a row failed (recorded in $log); investigate before relying on the watchdog"; fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
from=""
while [ $# -gt 0 ]; do
  case "$1" in
    --from-step) [ $# -ge 2 ] || { echo "usage: install.sh [--from-step <name>]" >&2; exit 2; }; from="$2"; shift ;;
    -h|--help) echo "usage: install.sh [--from-step <name>]  (steps: $STEPS)"; exit 0 ;;
    *) echo "usage: install.sh [--from-step <name>]" >&2; exit 2 ;;
  esac
  shift
done
if [ -n "$from" ]; then
  case " $STEPS " in *" $from "*) ;; *) echo "install: unknown step '$from'. Valid steps: $STEPS" >&2; exit 2 ;; esac
fi
mkdir -p "$STATE" || die "cannot create $STATE"

start="$from"
if [ -z "$start" ]; then
  last="$(cat "$STEPFILE" 2>/dev/null)"
  if [ -z "$last" ]; then
    start="prereqs"
  else
    case " $STEPS " in *" $last "*) ;; *) die "$STEPFILE holds an unknown step '$last'" ;; esac
    start=""; seen=0
    for s in $STEPS; do
      if [ "$seen" = 1 ]; then start="$s"; break; fi
      [ "$s" = "$last" ] && seen=1
    done
    [ -n "$start" ] || { say "install already complete (last step: $last). Use --from-step <name> to rerun a step."; exit 0; }
  fi
fi

go=0
for s in $STEPS; do
  [ "$s" = "$start" ] && go=1
  [ "$go" = 1 ] || continue
  say "== step: $s"
  "step_${s//-/_}" || die "step $s failed"
  printf '%s\n' "$s" | atomic_write "$STEPFILE" || die "cannot record progress"
  wd_log "install: step $s done"
  [ "$s" = "${WATCHDOG_INSTALL_STOP_AFTER:-}" ] && break
done
say "install finished."
