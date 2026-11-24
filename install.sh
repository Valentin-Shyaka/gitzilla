#!/usr/bin/env bash
# install.sh [--from-step <name>] — guided, resumable install of the gitzilla. Compatible with macOS bash 3.2.
# install.sh --join-org <worker-url> — join an organization's gitzilla (personal profile; see join_org below).
# install.sh --org <org-login> [--from-step <name>] — an org admin installs the organization's gitzilla (see below).
#
# GITZILLA_PROFILE=<name> installs a separate instance (bin/lib.sh: its own config, state and launchd labels
# io.github.gitzilla.<name>.<job>); unset = personal. In a plain profile the worker step refuses (it would deploy over
# the personal Worker; profile Workers come with --org), the hook and first-rotation steps are skipped (both belong to
# the personal profile), and launchd loads only the agent and reconcile jobs (no rotate job).
#
# --org <org-login>: the profile org-<login> (lower-cased) in org mode. Its steps are
#   prereqs note-key worker github-app repos mirrors launchd self-test
# (no hook, known-keys or first-rotation). In any profile the prereqs step sets up the profile's own gh login
# (profile_gh_login: a read-only fine-grained token owned by the org, in GH_CONFIG_DIR=<profile config>/gh); the
# github-app step has the admin create a missing drill repo on GitHub (that token cannot). The worker step deploys the Worker named gitzilla-<login> (every wrangler
# deploy and secret call carries --name gitzilla-<login>, never touching the personal Worker "gitzilla") with
# --var MODE:org --var ORG:<login> --var ADMIN_PUBKEYS:<the push-note key> and writes OWNER=<login>, MODE=org,
# ORG=<login>, WORKER_NAME and WEB_FLOW into the profile's config. GITZILLA_WEB_FLOW=orange|silent (default: the
# config's WEB_FLOW, else orange) is deployed as the Worker var WEB_FLOW. A rerun may name the profile instead
# (GITZILLA_PROFILE=org-<login> ./install.sh ...): a profile whose config says MODE=org is in org mode too.
#
# Steps (in order): prereqs note-key worker github-app hook repos mirrors known-keys launchd first-rotation self-test
# $STATE/install-step holds the last completed step; a rerun resumes after it. --from-step <name> forces the start.
#
# No secret is ever written to disk or to the log: WEBHOOK_SECRET and NTFY_TOPIC are printed once and piped to
# `wrangler secret put` on stdin; the (optional) Slack URL, red-alert call numbers and ntfy call token are read
# silently and piped the same way.
#
# Env overrides (tests): GITZILLA_GH_CMD, GITZILLA_NPM_CMD, GITZILLA_NPX_CMD, GITZILLA_OPEN_CMD, GITZILLA_PBPASTE_CMD,
# GITZILLA_CURL, GITZILLA_LAUNCHCTL_CMD, GITZILLA_NOTIFY_TEST_CMD, GITZILLA_RM_CMD, GITZILLA_LAUNCHD_POLL/RETRY, GITZILLA_RECONCILE_CMD, GITZILLA_ROTATE_CMD, GITZILLA_SECRETIVE_APP,
# GITZILLA_REMOTE_URL_TEMPLATE, GITZILLA_POLL_INTERVAL, GITZILLA_POLL_TIMEOUT, GITZILLA_INSTALL_STOP_AFTER (stop
# after that step).
# Install-time setting: GITZILLA_DRILL_REPO (name of the throwaway drill repo; default gitzilla-drill), saved in the
# config as DRILL_REPO by the worker step. GITZILLA_ALERT_TZ (IANA zone for the local time in alerts; default: the
# config's ALERT_TZ, else the Mac's zone from /etc/localtime), deployed as the Worker var ALERT_TZ and saved in the
# config. GITZILLA_LOCALTIME (tests) replaces /etc/localtime; GITZILLA_NODE_PATH_FILE (tests) replaces scanner/node-path.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USAGE="usage: install.sh [--from-step <name>]
       install.sh --org <org-login> [--from-step <name>]
       install.sh --join-org <https-worker-url>"
# --org picks the profile, so it is read before bin/lib.sh chooses the config and state directories.
ORG_LOGIN=""; org_set=0
_args=("$@"); _i=0
while [ "$_i" -lt "${#_args[@]}" ]; do
  case "${_args[$_i]}" in
    --from-step|--join-org) _i=$((_i + 1)) ;;
    --org) org_set=1; ORG_LOGIN="${_args[$((_i + 1))]:-}"; _i=$((_i + 1)) ;;
  esac
  _i=$((_i + 1))
done
unset _args _i
if [ "$org_set" = 1 ]; then
  ORG_LOGIN="$(printf '%s' "$ORG_LOGIN" | tr '[:upper:]' '[:lower:]')"
  # an organization login: letters, digits, hyphens (GitHub allows no "_" in org names, unlike WD_LOGIN_RE for users),
  # and it must fit the profile name org-<login>
  _re='^[a-z0-9][a-z0-9-]{0,38}$'
  [[ $ORG_LOGIN =~ $_re ]] || { printf 'install: --org needs the organization'"'"'s GitHub login (1-39 letters, digits or hyphens, not starting with a hyphen)\n%s\n' "$USAGE" >&2; exit 2; }
  unset _re
  # the profile name org-<login> must be a valid profile name (at most 40 characters), the Worker name at most 63
  [ "${#ORG_LOGIN}" -le 36 ] || { echo "install: the org login '$ORG_LOGIN' is too long: the profile name org-$ORG_LOGIN may have at most 40 characters" >&2; exit 2; }
  _w="gitzilla-$ORG_LOGIN"
  [ "${#_w}" -le 63 ] || { echo "install: the Worker name $_w is longer than 63 characters" >&2; exit 2; }
  unset _w
  if [ -n "${GITZILLA_PROFILE:-}" ] && [ "$GITZILLA_PROFILE" != "org-$ORG_LOGIN" ]; then
    echo "install: --org $ORG_LOGIN installs the profile org-$ORG_LOGIN, but GITZILLA_PROFILE is '$GITZILLA_PROFILE'; drop GITZILLA_PROFILE" >&2; exit 2
  fi
  GITZILLA_PROFILE="org-$ORG_LOGIN"; export GITZILLA_PROFILE # the steps' child commands (reconcile seed, notify-test) too
  # the org profile lives in ~/.config/gitzilla/org-<login> and ~/.local/state/gitzilla/org-<login>, always: exported
  # directories (copied from a launchd job, or the personal ones) would make it read and rewrite another instance
  if [ -n "${GITZILLA_CONFIG_DIR:-}" ] || [ -n "${GITZILLA_STATE_DIR:-}" ]; then
    echo "install: --org ignores the exported GITZILLA_CONFIG_DIR / GITZILLA_STATE_DIR (the org profile uses ~/.config/gitzilla/org-$ORG_LOGIN and ~/.local/state/gitzilla/org-$ORG_LOGIN)"
    unset GITZILLA_CONFIG_DIR GITZILLA_STATE_DIR
  fi
fi
. "$here/bin/lib.sh"
GITZILLA_HOME="$here"
GH="${GITZILLA_GH_CMD:-gh}"
NPM="${GITZILLA_NPM_CMD:-npm}"
NPX="${GITZILLA_NPX_CMD:-npx}"
OPEN="${GITZILLA_OPEN_CMD:-open}"
PBPASTE="${GITZILLA_PBPASTE_CMD:-pbpaste}"
CURL="${GITZILLA_CURL:-curl}"
LAUNCHCTL="${GITZILLA_LAUNCHCTL_CMD:-launchctl}"
RM="${GITZILLA_RM_CMD:-rm}"
LPOLL="${GITZILLA_LAUNCHD_POLL:-0.25}"
LRETRY="${GITZILLA_LAUNCHD_RETRY:-1}"
RECONCILE="${GITZILLA_RECONCILE_CMD:-$GITZILLA_HOME/bin/reconcile}"
ROTATE="${GITZILLA_ROTATE_CMD:-$GITZILLA_HOME/bin/rotate}"
NOTIFY_TEST="${GITZILLA_NOTIFY_TEST_CMD:-$GITZILLA_HOME/bin/notify-test}"
SECRETIVE_APP="${GITZILLA_SECRETIVE_APP:-/Applications/Secretive.app}"
REMOTE_TPL="${GITZILLA_REMOTE_URL_TEMPLATE:-git@github.com:%s.git}"
POLL_INTERVAL="${GITZILLA_POLL_INTERVAL:-5}"
POLL_TIMEOUT="${GITZILLA_POLL_TIMEOUT:-180}"
KEY_RE='^(ssh-|ecdsa-|sk-)[^ ]+ [A-Za-z0-9+/=]+'
LABEL_PREFIX="io.github.gitzilla${GITZILLA_PROFILE:+.$GITZILLA_PROFILE}" # personal: io.github.gitzilla.<job>
STEPS="prereqs note-key worker github-app hook repos mirrors known-keys launchd first-rotation self-test"
STEPFILE="$STATE/install-step"
PUBFILE="$GITZILLA_CONFIG_DIR/push-note.pub"
HOOK="" # set by step_hook from core.hooksPath
HOOK_MARK="# gitzilla: push note (fail-open)"
HOOK_ANCHOR='done <<< "$input"'
HOOK_STANDALONE="# gitzilla standalone pre-push hook"
HOOK_PREV_NAME="pre-push.gitzilla-prev"
HOOK_PREV_LINK="gitzilla-prev/pre-push" # runs the moved hook under the name pre-push (basename dispatch)
DRILL_DEFAULT="gitzilla-drill"
APP_PREFIX="gitzilla-"
APP_NAME_MAX=34 # GitHub's limit for a GitHub App name
# Org mode: --org <login>, or a profile whose config (written by an earlier --org run) says MODE=org for that org.
ORG_MODE=0; WORKER_NAME=""; WNAME=()
if [ "$org_set" = 1 ]; then
  ORG_MODE=1
elif [ -n "$GITZILLA_PROFILE" ] && [ "${MODE:-}" = org ] && [ "org-$(wd_lc "${ORG:-}")" = "$GITZILLA_PROFILE" ]; then
  ORG_MODE=1; ORG_LOGIN="$(wd_lc "$ORG")"
fi
if [ "$ORG_MODE" = 1 ]; then
  STEPS="prereqs note-key worker github-app repos mirrors launchd self-test"
  WORKER_NAME="gitzilla-$ORG_LOGIN"
  WNAME=(--name "$WORKER_NAME") # on every wrangler deploy / secret call: never the personal Worker "gitzilla"
fi
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
  [ -n "${GITZILLA_URL:-}" ] && [ -n "${OWNER:-}" ] || die "no config ($GITZILLA_CONFIG_DIR/config): run the worker step first"
  # configs written before APP_NAME / DRILL_REPO existed get the defaults
  APP_NAME="${APP_NAME:-$(app_name_for "$OWNER")}"
  DRILL_REPO="${DRILL_REPO:-$DRILL_DEFAULT}"
}

# app_name_for <login>: GitHub App names are globally unique, so the app is per user:
# gitzilla-<lower-cased login>, cut to GitHub's 34-char limit (and no trailing hyphen after the cut).
app_name_for() {
  local n
  n="$APP_PREFIX$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  n="$(printf '%s' "$n" | cut -c1-"$APP_NAME_MAX")"
  while :; do case "$n" in *-) n="${n%-}" ;; *) break ;; esac; done
  printf '%s\n' "$n"
}

# ---------------------------------------------------------------------------------------------------------------
# profile_gh_login: a profile's own gh login (bin/lib.sh exports GH_CONFIG_DIR=<profile config>/gh in a profile), so
# its gh calls (repo list, the restore push-permission check) never use the personal login: a fine-grained token has
# one resource owner, and the personal one (the user) cannot see an org's private repos. The admin creates a READ-ONLY
# fine-grained token owned by the org; it is read hidden and given to `gh auth login --with-token` on stdin, stored by
# gh in GH_CONFIG_DIR only (--insecure-storage: hosts.yml there, mode 600, never the macOS keychain entry the personal
# login uses for the same account). Never in argv, the log or any other file. A login already there is kept unless the
# admin types replace (an expired token: gh auth status fails, so it is asked for again).
GH_TOKEN_RE='^github_pat_[A-Za-z0-9_]{20,255}$'
# personal_gh_ok: gh auth status for the personal login (gh's default store: GH_CONFIG_DIR unset), bounded.
personal_gh_ok() { wd_timeout "${GITZILLA_GH_TIMEOUT:-15}" env -u GH_CONFIG_DIR "$GH" auth status >/dev/null 2>&1; }
profile_gh_login() {
  local ans tok owner="${ORG_LOGIN:-the account this profile watches}"
  { mkdir -p "$GH_CONFIG_DIR" && chmod 700 "$GH_CONFIG_DIR"; } || die "cannot create $GH_CONFIG_DIR"
  if "$GH" auth status >/dev/null 2>&1 </dev/null; then
    say "gh: profile $GITZILLA_PROFILE has its own login ($GH_CONFIG_DIR)."
    printf 'Press Enter to keep it, or type replace to give it a new token: '
    read -r ans || ans=""
    [ "$ans" = replace ] || return 0
  fi
  say "Profile $GITZILLA_PROFILE needs its own READ-ONLY GitHub token (your personal gh login cannot see the private"
  say "repos of $owner). Create a fine-grained personal access token:"
  say "  Token name        : gitzilla $GITZILLA_PROFILE (read-only)"
  say "  Resource owner    : $owner   (the organization, NOT your user)"
  say "  Expiration        : your choice; when it expires, rerun:"
  say "                        GITZILLA_PROFILE=$GITZILLA_PROFILE GITZILLA_INSTALL_STOP_AFTER=prereqs ./install.sh --from-step prereqs"
  say "  Repository access : All repositories"
  say "  Permissions       : Repository > Contents: Read-only"
  say "                      Repository > Metadata: Read-only"
  say "                      NOTHING else. Grant no write permission of any kind (no Contents: Read and write, no"
  say "                      Administration, no Workflows): no credential gitzilla stores may be able to push."
  say "If the organization requires approval of fine-grained tokens, an owner must approve it before it works."
  "$OPEN" "https://github.com/settings/personal-access-tokens/new" >/dev/null 2>&1 || true
  printf 'Paste the token (github_pat_..., input hidden): '
  if read -rs tok; then echo; else echo; tok=""; fi
  if ! [[ $tok =~ $GH_TOKEN_RE ]]; then
    tok=""; die "that is not a fine-grained token (github_pat_...); rerun --from-step prereqs"
  fi
  # the personal gh login (its own store, no GH_CONFIG_DIR) before and after: the profile login must not disturb it
  local pers_before=0
  personal_gh_ok && pers_before=1
  if ! printf '%s' "$tok" | "$GH" auth login --hostname github.com --with-token --insecure-storage >/dev/null 2>&1; then
    tok=""; die "gh auth login with that token failed (expired, not approved by the org, or mistyped); rerun --from-step prereqs"
  fi
  tok=""
  if [ "$pers_before" = 1 ] && ! personal_gh_ok; then
    say ""
    say "!!!! WARNING: your PERSONAL gh login worked before this step and fails now. The org token must not have"
    say "!!!! replaced it, but it looks like it did. Restore the personal login (no GITZILLA_PROFILE):"
    say "!!!!   bin/rotate gh        (or: gh auth login)"
    say "!!!! and check with:  gh auth status"
    say ""
    wd_log "install: personal gh login failing after the $GITZILLA_PROFILE gh login"
  fi
  "$GH" auth status >/dev/null 2>&1 </dev/null || die "gh in profile $GITZILLA_PROFILE is still not logged in; rerun --from-step prereqs"
  say "gh: profile $GITZILLA_PROFILE logged in with its own read-only token (stored by gh in $GH_CONFIG_DIR)"
}

step_prereqs() {
  local c
  for c in git jq curl openssl ssh-keygen node plutil awk sed; do need "$c"; done
  for c in "$GH" "$NPM" "$NPX" "$OPEN" "$LAUNCHCTL"; do need "$c"; done
  [ -d "$SECRETIVE_APP" ] || die "Secretive is not installed ($SECRETIVE_APP)"
  [ -f "$here/worker/package.json" ] || die "worker/ not found next to install.sh"
  if [ -n "$GITZILLA_PROFILE" ]; then
    profile_gh_login
  else
    "$GH" auth status >/dev/null 2>&1 || die "gh is not logged in: run 'gh auth login' first"
  fi
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
  mkdir -p "$GITZILLA_CONFIG_DIR" || die "cannot create $GITZILLA_CONFIG_DIR"
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
  if [ "$ORG_MODE" = 1 ]; then
    say "For the $ORG_LOGIN organization use the SAME push-note key as your personal gitzilla (in Secretive click"
    say "push-note, then \"Copy Public Key\"); create it as above only if you have none. It becomes the org Worker's"
    say "admin key (ADMIN_PUBKEYS), and it must be an ECDSA (ecdsa-sha2-nistp256) Secretive key."
  fi
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

# check_call_numbers <comma-separated list>: 1-5 numbers, each +E164 (^\+[1-9][0-9]{6,14}$). Sets CALL_ERR (which
# never contains the input) and returns 1 on failure. Builtins only, so the numbers never reach argv.
check_call_numbers() {
  local rest="$1," x n=0 re='^\+[1-9][0-9]{6,14}$'
  CALL_ERR=""
  while [ -n "$rest" ]; do
    x="${rest%%,*}"; rest="${rest#*,}"; n=$((n + 1))
    [[ $x =~ $re ]] || { CALL_ERR="invalid phone number #$n: use +E164 (a + then the country code and number, e.g. +14155550100), comma-separated"; return 1; }
  done
  [ "$n" -le 5 ] || { CALL_ERR="too many phone numbers: at most 5"; return 1; }
  return 0
}

# Validators for ask_hidden_valid: 0 if the answer is acceptable, else 1 with CHECK_ERR set (never holding the input).
check_slack_url() {
  CHECK_ERR="the Slack webhook URL must start with https://"
  case "$1" in ''|https://*) return 0 ;; esac
  return 1
}
check_call_input() { # empty = skip calls
  local v="${1// /}"
  [ -z "$v" ] && return 0
  check_call_numbers "$v" || { CHECK_ERR="$CALL_ERR"; return 1; }
}
check_call_token() {
  local tre='^tk_[A-Za-z0-9]{29}$'
  CHECK_ERR="invalid ntfy access token: it must be tk_ followed by 29 letters or digits (ntfy.sh > Account > Access tokens)"
  [[ $1 =~ $tre ]]
}

# ask_hidden_valid <prompt> <check-fn>: reads a hidden answer into ASK_VAL until <check-fn> accepts it, at most 3
# tries (a mistyped answer is asked again, since the one-time secrets are already on screen). End of input on the
# first try is an empty answer. The third refusal, or end of input after a refusal, gives up: the WEBHOOK_SECRET and
# NTFY_TOPIC just printed were never put, so the message says to rerun the step and rotate.
ask_hidden_valid() {
  local n=0 why
  ASK_VAL=""
  while :; do
    n=$((n + 1))
    printf '%s' "$1"
    if read -rs ASK_VAL; then echo; else
      ASK_VAL=""; echo
      [ "$n" -eq 1 ] || { why="$CHECK_ERR (no answer after it)"; break; }
    fi
    "$2" "$ASK_VAL" && return 0
    printf 'install: %s\n' "$CHECK_ERR" >&2
    [ "$n" -lt 3 ] || { why="$CHECK_ERR (3 tries)"; break; }
  done
  ASK_VAL=""
  worker_die "$why. The WEBHOOK_SECRET and NTFY_TOPIC shown above are not saved: rerun ./install.sh --from-step worker and type rotate (when asked) to get new ones"
}

# admin_pubkey: the push-note key as the org Worker's ADMIN_PUBKEYS value ("ecdsa-sha2-nistp256 <base64>", comment
# dropped). The Worker trusts no admin key at all when that value is malformed (it fails closed), so the file must hold
# exactly one ecdsa-sha2-nistp256 key line that ssh-keygen can read. Returns 1 otherwise.
admin_pubkey() {
  local n line t b _rest re='^[A-Za-z0-9+/]+={0,2}$'
  n="$(grep -c . "$PUBFILE" 2>/dev/null)"
  [ "$n" = 1 ] || return 1
  line="$(grep . "$PUBFILE")"
  read -r t b _rest <<< "$line"
  [ "$t" = ecdsa-sha2-nistp256 ] && [[ $b =~ $re ]] || return 1
  printf '%s %s\n' "$t" "$b" | fp_of >/dev/null || return 1
  printf '%s %s\n' "$t" "$b"
}

step_worker() {
  # a plain profile has no Worker of its own: without --name, deploy / secret put would hit the personal Worker "gitzilla"
  [ -z "$GITZILLA_PROFILE" ] || [ "$ORG_MODE" = 1 ] || die "profile $GITZILLA_PROFILE: the worker step is not available in a profile yet (it would deploy over the personal Worker 'gitzilla' and replace its secrets); Worker deploys for an org profile come with ./install.sh --org <org-login>. Nothing changed. If this profile already has a config for its own Worker in $GITZILLA_CONFIG_DIR/config, continue with: GITZILLA_PROFILE=$GITZILLA_PROFILE ./install.sh --from-step github-app"
  [ -s "$PUBFILE" ] || die "no $PUBFILE: run the note-key step first"
  local owner pub out url wsec topic slack nums ctok left last mode=fresh ans drill app tz admin="" orgvars=() wdel="" wf=""
  if [ "$ORG_MODE" = 1 ]; then
    owner="$ORG_LOGIN"
    admin="$(admin_pubkey)" || die "the push-note key ($PUBFILE) must be exactly one ecdsa-sha2-nistp256 (Secretive) public key line: it becomes the org Worker's ADMIN_PUBKEYS, and the Worker trusts no admin key at all when that value is malformed. Fix it with --from-step note-key. Nothing deployed."
    # pushes whose every commit GitHub's web UI made: orange (default) or silent (never a forced push)
    wf="${GITZILLA_WEB_FLOW:-${WEB_FLOW:-orange}}"
    case "$wf" in orange|silent) ;; *) die "GITZILLA_WEB_FLOW must be orange or silent, not '$wf'. Nothing deployed." ;; esac
    orgvars=(--var "MODE:org" --var "ORG:$ORG_LOGIN" --var "WEB_FLOW:$wf" --var "ADMIN_PUBKEYS:$admin")
    wdel=" --name $WORKER_NAME"
  else
    owner="${OWNER:-$("$GH" api user --jq .login 2>/dev/null)}"
  fi
  [ -n "$owner" ] || die "cannot determine the GitHub login (gh api user)"
  app="$(app_name_for "$owner")"
  drill="${GITZILLA_DRILL_REPO:-${DRILL_REPO:-$DRILL_DEFAULT}}"
  case "$drill" in ''|.|..|*[!A-Za-z0-9._-]*) die "invalid drill repo name '$drill' (GITZILLA_DRILL_REPO: a repository name, no owner)" ;; esac
  tz="${GITZILLA_ALERT_TZ:-${ALERT_TZ:-}}"
  if [ -z "$tz" ]; then
    tz="$(readlink "${GITZILLA_LOCALTIME:-/etc/localtime}" 2>/dev/null)"
    case "$tz" in *zoneinfo/*) tz="${tz##*zoneinfo/}" ;; *) tz="" ;; esac
  fi
  case "$tz" in ''|/*|*..*|*[!A-Za-z0-9_+/-]*) [ -z "$tz" ] || say "note: '$tz' is not a time-zone name; alerts use UTC"; tz=UTC ;; esac
  pub="$(head -n1 "$PUBFILE")"
  last="$(cat "$STEPFILE" 2>/dev/null)"
  if [ -f "$GITZILLA_CONFIG_DIR/config" ] || { [ -n "$last" ] && [ "$(step_index "$last")" -ge "$(step_index worker)" ]; }; then
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
    if [ "$ORG_MODE" = 1 ]; then
      "$NPX" wrangler deploy "${WNAME[@]}" --var "ALERT_TZ:$tz" "${orgvars[@]}" 2>&1 | tee "$out"
    else
      "$NPX" wrangler deploy --var "NOTE_PUBKEY:$pub" --var "ALERT_TZ:$tz" 2>&1 | tee "$out"
    fi
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
    ask_hidden_valid 'Slack incoming-webhook URL, or press Enter to skip Slack (input hidden): ' check_slack_url
    slack="$ASK_VAL"; ASK_VAL=""
    ask_hidden_valid 'Phone numbers for red-alert calls, comma-separated +E164 (ntfy Pro; Enter to skip) (input hidden): ' check_call_input
    nums="${ASK_VAL// /}"; ASK_VAL=""; ctok=""
    if [ -n "$nums" ]; then
      ask_hidden_valid 'ntfy access token (tk_...) (input hidden): ' check_call_token
      ctok="$ASK_VAL"; ASK_VAL=""
    fi
    ( cd "$here/worker" || exit 1
      # "${WNAME[@]}": --name gitzilla-<org> in org mode, nothing for the personal Worker
      printf '%s' "$wsec" | "$NPX" wrangler secret put WEBHOOK_SECRET "${WNAME[@]}" || exit 1
      printf '%s' "$topic" | "$NPX" wrangler secret put NTFY_TOPIC "${WNAME[@]}" || exit 1
      # the Worker treats SLACK_WEBHOOK_URL as optional (notify.js posts to Slack only when it is set)
      if [ -n "$slack" ]; then printf '%s' "$slack" | "$NPX" wrangler secret put SLACK_WEBHOOK_URL "${WNAME[@]}" || exit 1; fi
      # calls are optional too (notify.js calls only with a valid token and at least one valid number)
      if [ -n "$nums" ]; then
        printf '%s' "$nums" | "$NPX" wrangler secret put NTFY_CALL_NUMBERS "${WNAME[@]}" || exit 1
        printf '%s' "$ctok" | "$NPX" wrangler secret put NTFY_CALL_TOKEN "${WNAME[@]}" || exit 1
      fi
    ) || { wsec=""; topic=""; slack=""; nums=""; ctok=""; worker_die "wrangler secret put failed"; }
    if [ -z "$slack" ]; then
      # a rotate keeps any SLACK_WEBHOOK_URL a previous run put, so Slack may still be on
      if [ "$mode" = rotate ]; then
        say "Slack setting unchanged in the Worker; to remove it: npx wrangler secret delete SLACK_WEBHOOK_URL$wdel"
      else
        say "Slack skipped: alerts go to the phone (ntfy) only"
      fi
    fi
    if [ -z "$nums" ]; then
      # a rotate keeps any NTFY_CALL_* secrets a previous run put, so calls may still be on
      if [ "$mode" = rotate ]; then
        say "Call settings unchanged in the Worker; to remove them: npx wrangler secret delete NTFY_CALL_NUMBERS$wdel / NTFY_CALL_TOKEN$wdel"
      else
        say "Calls skipped: red alerts do not ring the phone"
      fi
    fi
    wsec=""; topic=""; slack=""; nums=""; ctok=""
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
      printf 'GITZILLA_URL=%q\n' "$url"
      printf 'NOTE_PUBKEY_FILE=%q\n' "$PUBFILE"
      printf 'GITZILLA_HOME=%q\n' "$GITZILLA_HOME"
      printf 'APP_NAME=%q\n' "$app"
      printf 'DRILL_REPO=%q\n' "$drill"
      printf 'ALERT_TZ=%q\n' "$tz"
      [ -z "${ORG_WORKERS:-}" ] || printf 'ORG_WORKERS=%q\n' "$ORG_WORKERS" # orgs joined with --join-org
      if [ "$ORG_MODE" = 1 ]; then
        printf 'MODE=org\n'
        printf 'ORG=%q\n' "$ORG_LOGIN"
        printf 'WORKER_NAME=%q\n' "$WORKER_NAME"
        printf 'WEB_FLOW=%q\n' "$wf"
      fi
    } | atomic_write "$GITZILLA_CONFIG_DIR/config" ) || die "cannot write the config"
  chmod 600 "$GITZILLA_CONFIG_DIR/config"
  # shellcheck disable=SC1090
  . "$GITZILLA_CONFIG_DIR/config"
  say "worker deployed at $GITZILLA_URL; config written"
  if [ "$ORG_MODE" = 1 ]; then
    say ""
    say "The $ORG_LOGIN Worker ($WORKER_NAME) is in org mode; your push-note key is its admin key."
    say "Members join it from their personal gitzilla with:  ./install.sh --join-org $GITZILLA_URL"
    say "Join it yourself the same way (personal install, no GITZILLA_PROFILE), then approve each member with:"
    say "  GITZILLA_PROFILE=$GITZILLA_PROFILE bin/org approve <login> <fingerprint>"
    org_signers_hint
  fi
}

# org_signers_hint: the org profile verifies commit signatures (deep check, restore target) only against its own
# allowed_signers, never the admin's personal one.
org_signers_hint() {
  local f="$GITZILLA_CONFIG_DIR/allowed_signers"
  say ""
  if wd_org_signers_ok; then
    say "Commit signatures in $ORG_LOGIN's repos are checked against $f ($(grep -cv '^[[:space:]]*\(#\|$\)' "$f" | tr -d ' ') key line(s))."
  else
    say "No $f yet: until it exists the org's deep check skips signatures (the Worker's alert level stands) and"
    say "restore skips every ref with \"no org signers file\". Populate it with the members' commit-signing public keys,"
    say "one line each:"
    say "  <login> namespaces=\"git\" <key type> <base64 key>"
    say "(e.g. from https://api.github.com/users/<login>/ssh_signing_keys, after checking each key with its owner)."
  fi
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
    sig="$(wd_sign gitzilla-queue "$d/msg")" || { rm -rf "$d"; return 1; }
    msg="$(base64 < "$d/msg" | tr -d '\n')"
    sig="$(printf '%s' "$sig" | base64 | tr -d '\n')"
    code="$("$CURL" --max-time 10 -sS -o "$d/out" -w '%{http_code}' -H "X-Gitzilla-Auth: $msg.$sig" \
            "$GITZILLA_URL/queue?after=$QMAX" 2>/dev/null </dev/null)"
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
  local rotated="$STATE/install-secrets-rotated" apps="https://github.com/settings/apps"
  # an org's app lives in the organization's settings
  [ "$ORG_MODE" = 1 ] && apps="https://github.com/organizations/$OWNER/settings/apps"
  if [ -f "$rotated" ]; then
    cat <<EOF

The Worker secrets were regenerated. The GitHub App already exists: do NOT create another one.
  1. Edit the EXISTING app's webhook secret at $apps/$APP_NAME/advanced
     (Webhook secret: paste the new WEBHOOK_SECRET printed in the worker step, then Save changes).
  2. Re-subscribe the phone to the new ntfy topic (printed in the worker step).
EOF
    "$OPEN" "$apps/$APP_NAME/advanced" >/dev/null 2>&1 || true
    wait_enter "Press Enter once the webhook secret is updated and the phone is re-subscribed."
  elif [ "$ORG_MODE" = 1 ]; then
    cat <<EOF

Create the organization's GitHub App at $apps/new (you must be an owner of $OWNER) with exactly these
settings (if the app already exists, edit its webhook secret at $apps/$APP_NAME/advanced instead):
  GitHub App name   : $APP_NAME
  Homepage URL      : https://github.com/$OWNER
  Webhook           : Active
  Webhook URL       : $GITZILLA_URL/webhook
  Webhook secret    : the WEBHOOK_SECRET printed in the worker step (shown only once; if you lost it, rerun
                      --from-step worker and type rotate to regenerate the secrets)
  Permissions       : Repository > Contents: Read-only ; Metadata: Read-only (nothing else)
  Subscribe to events: Push (installation events are sent to every app; tick Installation and
                      Installation repositories too if the form lists them)
  Where installable : Only on this account (the $OWNER organization)
After creating it: generate a private key (GitHub requires one before the app can be installed; the file
lands in ~/Downloads and is deleted below), then install the app on the organization $OWNER with access to
ALL repositories (Install App > $OWNER > All repositories).
EOF
    "$OPEN" "$apps/new" >/dev/null 2>&1 || true
    wait_enter "Press Enter once the app is created, a key generated and the app installed on all of $OWNER's repos."
  else
    cat <<EOF

Create the GitHub App at https://github.com/settings/apps/new with exactly these settings
(if the app already exists, edit its webhook secret at https://github.com/settings/apps/$APP_NAME/advanced instead):
  GitHub App name   : $APP_NAME
  Homepage URL      : https://github.com/$OWNER
  Webhook           : Active
  Webhook URL       : $GITZILLA_URL/webhook
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
  if [ "$ORG_MODE" = 1 ] && ! "$GH" repo view "$OWNER/$DRILL_REPO" >/dev/null 2>&1 </dev/null; then
    # the profile's gh token is read-only: the admin creates the drill repo in the org on GitHub
    say "The drill repo $OWNER/$DRILL_REPO does not exist. The installer and the drill push to it (never to a real repo)."
    say "Create it on GitHub (the profile's gh token is read-only and cannot): owner $OWNER, name $DRILL_REPO, Private,"
    say "  \"Add a README file\" ticked:  https://github.com/organizations/$OWNER/repositories/new"
    "$OPEN" "https://github.com/organizations/$OWNER/repositories/new" >/dev/null 2>&1 || true
    wait_enter "Press Enter once $OWNER/$DRILL_REPO exists."
    "$GH" repo view "$OWNER/$DRILL_REPO" >/dev/null 2>&1 </dev/null \
      || die "$OWNER/$DRILL_REPO is not visible to the profile's gh token: create it (the token's \"All repositories\" access then covers it), then rerun --from-step github-app"
  fi
  if ! "$GH" repo view "$OWNER/$DRILL_REPO" >/dev/null 2>&1 </dev/null; then
    say "The drill repo $OWNER/$DRILL_REPO does not exist. The installer and the drill push to it (never to a real repo)."
    ask_yes "Create it now as a private repo (gh repo create $OWNER/$DRILL_REPO --private --add-readme)?" \
      || die "a drill repo is needed: create $OWNER/$DRILL_REPO (or set GITZILLA_DRILL_REPO and rerun --from-step worker), then rerun --from-step github-app"
    "$GH" repo create "$OWNER/$DRILL_REPO" --private --add-readme --description "throwaway repo for gitzilla drills" \
      </dev/null >/dev/null 2>&1 || die "gh repo create $OWNER/$DRILL_REPO failed; create it by hand, then rerun --from-step github-app"
    say "created $OWNER/$DRILL_REPO"
  fi
  queue_scan 0 || die "cannot read the Worker queue ($GITZILLA_URL/queue); check the deploy, then rerun --from-step github-app"
  local base="$QMAX"
  say "Verify: in your drill repo $OWNER/$DRILL_REPO make a commit and push it (any branch)."
  say "  (no clone yet?  gh repo clone $OWNER/$DRILL_REPO  or  git clone git@github.com:$OWNER/$DRILL_REPO.git)"
  if [ "$ORG_MODE" = 1 ]; then
    say "This push raises an orange (🟠) alert on your phone: expected until you have joined the org from your personal"
    say "gitzilla (./install.sh --join-org $GITZILLA_URL) and approved your own key with bin/org approve."
  else
    say "This push raises an orange (🟠) alert on your phone: expected, the hook that sends push notes is installed later."
  fi
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

# render_hook <out>: the standalone hook from hooks/pre-push with the absolute GITZILLA_HOME (bash substitution, so no
# character of the path is special; step_hook already refuses quotes, $, backquotes and backslashes in it).
render_hook() {
  local t
  t="$(cat "$here/hooks/pre-push")" || return 1
  printf '%s\n' "${t//@GITZILLA_HOME@/$GITZILLA_HOME}" > "$1"
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
#   - any other existing hook (after a yes): back it up, move it aside to pre-push.gitzilla-prev and install
#     the standalone hook, which runs it through the symlink gitzilla-prev/pre-push (so it still sees the name
#     pre-push) with the same stdin and arguments and exits with its status. Moving it aside (rather than editing it)
#     works for hooks in any language and any shape. A hook that was not executable stays so: git ignored it, and the
#     standalone hook ignores it too;
#   - no hook: install the standalone hook.
# Also records the absolute node (scanner/node-path) and jq ($GITZILLA_CONFIG_DIR/jq-path) for hooks run by GUI clients.
step_hook() {
  # one global pre-push hook serves every profile; routing notes per profile comes later
  if [ -n "$GITZILLA_PROFILE" ]; then
    say "hook step skipped in profile $GITZILLA_PROFILE: the hook is installed by the personal profile (./install.sh --from-step hook without GITZILLA_PROFILE)"
    return 0
  fi
  case "$GITZILLA_HOME" in *\"*|*\$*|*\`*|*\\*) die "unsupported characters in $GITZILLA_HOME" ;; esac
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
    [ -e "$HOOK.bak-gitzilla" ] || cp -p "$HOOK" "$HOOK.bak-gitzilla" || die "cannot back up the hook"
    mv "$HOOK" "$prev" || die "cannot move $HOOK aside"
    mkdir -p "${link%/*}" && ln -sfn "../$HOOK_PREV_NAME" "$link" || die "cannot link $link"
    install_standalone
    if [ -x "$prev" ]; then
      say "existing hook moved to $prev and chained from the new $HOOK (backup: $HOOK.bak-gitzilla)"
    else
      say "existing hook moved to $prev; it was not executable, so git never ran it, and it is NOT chained (make it"
      say "executable yourself if you want it to run). Backup: $HOOK.bak-gitzilla"
    fi
  else
    mkdir -p "$dir" || die "cannot create $dir"
    install_standalone
    say "standalone pre-push hook installed: $HOOK"
  fi
  # a chained hook whose gitzilla-prev/pre-push link went missing (deleted by hand, older install) is linked again
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
  case "$n" in /*) printf '%s\n' "$n" | atomic_write "${GITZILLA_NODE_PATH_FILE:-$GITZILLA_HOME/scanner/node-path}" || die "cannot write scanner/node-path" ;; esac
  case "$j" in /*) mkdir -p "$GITZILLA_CONFIG_DIR" && printf '%s\n' "$j" | atomic_write "$GITZILLA_CONFIG_DIR/jq-path" || die "cannot write jq-path" ;; esac
  return 0
}

# hook_insert_note: a polin-guard-shaped hook (anchor) or one already carrying the marker: insert or refresh the note.
hook_insert_note() {
  local expect cur shape tmp="$HOOK.tmp.$$"
  expect="printf '%s\\n' \"\$input\" | \"$GITZILLA_HOME/bin/note\" \"\$@\" || true"
  if grep -qxF "$HOOK_MARK" "$HOOK"; then
    cur="$(grep -xF -A1 -- "$HOOK_MARK" "$HOOK" | sed -n 2p)"
    if [ "$cur" = "$expect" ]; then say "hook already contains the push note"; return 0; fi
    [ -e "$HOOK.bak-gitzilla" ] || cp -p "$HOOK" "$HOOK.bak-gitzilla" || die "cannot back up the hook"
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
    say "hook note path updated (backup: $HOOK.bak-gitzilla)"
    return 0
  fi
  grep -qxF "$HOOK_ANCHOR" "$HOOK" || die "anchor line '$HOOK_ANCHOR' not found in $HOOK; nothing changed"
  [ -e "$HOOK.bak-gitzilla" ] || cp -p "$HOOK" "$HOOK.bak-gitzilla" || die "cannot back up the hook"
  cp -p "$HOOK" "$tmp" || die "cannot copy the hook"
  EXPECT="$expect" awk -v mark="$HOOK_MARK" -v anchor="$HOOK_ANCHOR" '
    { print }
    !done && $0 == anchor { print mark; print ENVIRON["EXPECT"]; done = 1 }' "$HOOK" > "$tmp" || { rm -f "$tmp"; die "cannot edit the hook"; }
  chmod +x "$tmp"
  mv -f "$tmp" "$HOOK" || die "cannot replace the hook"
  say "hook updated (backup: $HOOK.bak-gitzilla)"
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
  [ "$ORG_MODE" = 1 ] && push_sample "$list"
  return 0
}

# push_sample <repos.txt lines>: org mode. Restore needs push access to put a ref back; ask GitHub for a sample of up to
# 3 repos and warn about those this account cannot push to (restore skips them with "no push permission").
push_sample() {
  local slug _vis v no="" hidden="" n=0 err
  err="$(mktemp)" || die "mktemp failed"
  while read -r slug _vis; do
    [ -n "$slug" ] || continue
    n=$((n + 1)); [ "$n" -le 3 ] || break
    v="$(wd_timeout "${GITZILLA_GH_TIMEOUT:-15}" "$GH" api "repos/$slug" --jq '.permissions.push // .permissions.admin' 2>"$err")" || v=no
    v="${v%%$'\n'*}"
    if [ "$v" != true ]; then
      case "$(cat "$err")" in
        *"(HTTP 404)"*|*"(HTTP 403)"*|*"(HTTP 401)"*) hidden="${hidden:+$hidden }$slug" ;;
        *) no="${no:+$no }$slug" ;;
      esac
    fi
  done <<EOF
$1
EOF
  rm -f "$err"
  if [ -n "$hidden" ]; then
    say "WARNING: the profile's gh token cannot see: $hidden. Restore skips such repos with \"repo not visible to org"
    say "  token\": give the token access to all of the organization's repositories (rerun --from-step prereqs, type replace)."
  fi
  if [ -n "$no" ]; then
    say "WARNING: your account cannot push to: $no (sample of $((n > 3 ? 3 : n)) repos). Restore skips such repos with"
    say "  \"no push permission\": an org owner must give you push access (and the right to bypass branch protection)."
  elif [ -z "$hidden" ]; then
    say "push access checked on a sample of repos: ok"
  fi
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

# render <template> <out> <label>: fill the launchd template. The @PROFILE@ line becomes the GITZILLA_PROFILE
# environment entry in a profile and is dropped for personal (so a personal plist is what it was before profiles).
render() {
  local prof='/@PROFILE@/d'
  [ -z "$GITZILLA_PROFILE" ] || prof="s|@PROFILE@|<key>GITZILLA_PROFILE</key><string>$GITZILLA_PROFILE</string>|"
  sed -e "$prof" -e "s|@LABEL@|$3|g" -e "s|@GITZILLA_HOME@|$GITZILLA_HOME|g" -e "s|@STATE@|$STATE|g" \
      -e "s|@CONFIG@|$GITZILLA_CONFIG_DIR|g" "$1" > "$2"
}

step_launchd() {
  local dir="$HOME/Library/LaunchAgents" job label plist uid out n jobs="agent reconcile rotate"
  case "$GITZILLA_HOME$STATE$GITZILLA_CONFIG_DIR" in *\&*|*\|*|*\<*|*\>*|*\\*) die "unsupported characters in install paths" ;; esac
  mkdir -p "$dir" "$STATE/log" || die "cannot create $dir"
  uid="$(id -u)"
  if [ -n "$GITZILLA_PROFILE" ]; then
    # rotation belongs to the personal profile: no rotate job here, and one an earlier install loaded is removed
    jobs="agent reconcile"; label="$LABEL_PREFIX.rotate"
    "$LAUNCHCTL" bootout "gui/$uid/$label" >/dev/null 2>&1 || true
    rm -f "$dir/$label.plist"
  fi
  for job in $jobs; do
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
  if [ -n "$GITZILLA_PROFILE" ]; then
    say "launchd jobs loaded: agent (5 min), reconcile (hourly); no rotate job in a profile"
  else
    say "launchd jobs loaded: agent (5 min), reconcile (hourly), rotate (daily 10:00)"
  fi
}

step_first_rotation() {
  if [ -n "$GITZILLA_PROFILE" ]; then
    say "first-rotation skipped in profile $GITZILLA_PROFILE: rotation belongs to the personal profile"
    return 0
  fi
  require_config
  "$ROTATE" gh || die "rotate gh did not finish; rerun with --from-step first-rotation"
}

step_self_test() {
  mkdir -p "$STATE"
  local log="$STATE/install-selftest.log" bad=0
  say ""
  say "Self-test (use your drill repo ${OWNER:+$OWNER/}${DRILL_REPO:-$DRILL_DEFAULT}):"
  if [ "$ORG_MODE" = 1 ]; then
    say "  (org: push from a Mac that joined the org with ./install.sh --join-org and whose key you approved, e.g. yours)"
  fi
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
  if ask_yes "  Row 3: Send a test alert to every channel (rings the phone if calls are set up)?"; then
    if "$NOTIFY_TEST" </dev/null; then
      if ask_yes "  Row 3 result: did every channel (ntfy, Slack and the call, as set up) receive the test alert?"; then
        echo "row3 pass" >> "$log"
      else
        echo "row3 FAIL" >> "$log"; bad=1
      fi
    else
      echo "row3 FAIL" >> "$log"; bad=1
    fi
  else
    echo "row3 skipped" >> "$log"
  fi
  if [ "$bad" -eq 0 ]; then say "self-test passed"; else say "self-test: a row failed (recorded in $log); investigate before relying on the watchdog"; fi
  return 0
}

# ---------------------------------------------------------------------------------------------------------------
# --join-org <worker-url>: this Mac's developer joins an organization's gitzilla. Personal profile only; needs the
# personal config (OWNER) and push-note key. Reads the org login from <url>/health (which must report mode "org"),
# asks the org Worker to enroll the push-note key under OWNER (POST /enroll, signed by that key in namespace
# gitzilla-enroll; an admin approves it with bin/org approve), then records "<org>=<url>" in ORG_WORKERS so that
# bin/note sends notes for that org's repos to that Worker. Rerunning is safe: the same org and URL only re-posts
# /enroll (202 pending / 409 already a member); a new URL for a joined org asks first (default no).
JOIN_USAGE="usage: install.sh --join-org <https-worker-url>"
join_org() {
  local url="${1%/}" login pubfile pub fp health mode org cur dir code err new pair rfp other="" pairs=()
  [ -z "$GITZILLA_PROFILE" ] || die "--join-org runs in the personal profile only (it records the org in the personal config, which the pre-push hook reads); run it without GITZILLA_PROFILE. Nothing changed."
  wd_valid_worker_url "$url" || die "--join-org needs the org Worker's https URL with no path (e.g. https://gitzilla-acme.example.workers.dev). Nothing changed."
  [ -n "${OWNER:-}" ] && [ -n "${GITZILLA_URL:-}" ] || die "no personal config ($GITZILLA_CONFIG_DIR/config): install gitzilla for your own account first (./install.sh), then join the org. Nothing changed."
  login="$(wd_lc "$OWNER")"
  [[ $login =~ $WD_LOGIN_RE ]] || die "OWNER '$OWNER' in $GITZILLA_CONFIG_DIR/config is not a GitHub login. Nothing changed."
  pubfile="${NOTE_PUBKEY_FILE:-$PUBFILE}"
  pub="$(head -n1 "$pubfile" 2>/dev/null | awk '{print $1" "$2}')"
  case "$pub" in "ecdsa-sha2-nistp256 "?*) ;; *) die "the push-note key ($pubfile) is missing or not an ecdsa-sha2-nistp256 (Secretive) key; run ./install.sh --from-step note-key. Nothing changed." ;; esac
  fp="$(printf '%s\n' "$pub" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  [[ $fp =~ $WD_FP_RE ]] || die "ssh-keygen cannot read the push-note key ($pubfile). Nothing changed."

  health="$("$CURL" --max-time 10 -sS -f "$url/health" </dev/null 2>/dev/null)" || die "cannot reach $url/health; check the URL your admin gave you. Nothing changed."
  mode="$(printf '%s' "$health" | jq -r '.mode // empty' 2>/dev/null)"
  org="$(printf '%s' "$health" | jq -r '.org // empty' 2>/dev/null)"
  [ "$mode" = org ] || die "$url is not an organization's gitzilla Worker (its /health does not report mode \"org\"). Nothing changed."
  org="$(wd_lc "$org")"
  [[ $org =~ $WD_LOGIN_RE ]] || die "$url does not name its organization (/health has no valid org login; the admin must set ORG). Nothing changed."
  [ "$org" != "$login" ] || die "$url watches $org, which is your own account (the personal Worker covers it). Nothing changed."

  # split without globbing: a hand-edited entry with * or ? must not expand to file names
  IFS=$' \t\n' read -r -d '' -a pairs <<< "${ORG_WORKERS:-}" || true
  cur="$(wd_org_worker "$org")"
  if [ -n "$cur" ] && [ "$cur" != "$url" ]; then
    say "You already joined $org with the Worker $cur."
    ask_yes "Replace it with $url?" || die "kept $org=$cur. Nothing changed."
  fi
  if [ "$cur" != "$url" ]; then
    # the same URL already recorded for another org: its /health now names $org (its ORG changed, or it is not who
    # you think). Adding a second mapping would send $org's push notes there, so ask first.
    for pair in ${pairs[@]+"${pairs[@]}"}; do
      [ "${pair#*=}" = "$url" ] && [ "$(wd_lc "${pair%%=*}")" != "$org" ] && other="${other:+$other, }${pair%%=*}"
    done
    if [ -n "$other" ]; then
      say "The Worker $url is already recorded for: $other. It now says it watches $org's repos."
      ask_yes "This Worker watches $org's repos. Join $org with it as well?" || die "$org not joined. Nothing changed."
    fi
  fi

  dir="$(mktemp -d)" || die "mktemp failed"
  jq -cn --arg l "$login" --arg k "$pub" --argjson ts "$(date +%s)" --arg n "$(openssl rand -hex 16)" \
    '{login:$l,pubkey:$k,ts:$ts,nonce:$n}' | tr -d '\n' > "$dir/payload"
  [ -s "$dir/payload" ] || { rm -rf "$dir"; die "cannot build the enrollment request. Nothing changed."; }
  wd_envelope gitzilla-enroll "$dir/payload" "$dir/body" || { rm -rf "$dir"; die "enrollment request: $WD_REASON (is Secretive running?). Nothing changed."; }
  code="$("$CURL" --max-time 15 -sS -o "$dir/resp" -w '%{http_code}' -X POST -H 'Content-Type: application/json' \
          --data-binary @"$dir/body" "$url/enroll" </dev/null 2>/dev/null)"
  err="$(jq -r '.error // empty' "$dir/resp" 2>/dev/null | tr -cd 'A-Za-z0-9 ._:/()-' | cut -c1-200)"
  rfp="$(jq -r '.fingerprint // empty' "$dir/resp" 2>/dev/null | tr -cd 'A-Za-z0-9+/:=' | cut -c1-100)"
  rm -rf "$dir"
  case "$code" in
    202) say "enrollment requested: $login is pending approval by a $org gitzilla admin"
         if [ "$rfp" != "$fp" ]; then
           say ""
           say "WARNING: FINGERPRINT MISMATCH. The $org Worker recorded ${rfp:-no fingerprint}, but your push-note key is $fp."
           say "WARNING: something between this Mac and the Worker changed the request, or the Worker is not what it claims."
           say "WARNING: do not ask your admin to approve anything; tell them about this mismatch instead."
           say ""
           wd_log "install: join $org: fingerprint mismatch (Worker: ${rfp:-none})"
         fi ;;
    409) say "already a member of $org's gitzilla with this key (nothing to approve)" ;;
    ""|000) die "cannot reach $url/enroll. Nothing changed." ;;
    *) die "the $org Worker refused the enrollment: ${err:-HTTP $code} (HTTP $code). Nothing changed." ;;
  esac

  if [ "$cur" != "$url" ]; then
    new=""
    for pair in ${pairs[@]+"${pairs[@]}"}; do [ "$(wd_lc "${pair%%=*}")" = "$org" ] || new="${new:+$new }$pair"; done
    new="${new:+$new }$org=$url"
    ( umask 077
      { grep -v '^ORG_WORKERS=' "$GITZILLA_CONFIG_DIR/config"; printf 'ORG_WORKERS=%q\n' "$new"; } \
        | atomic_write "$GITZILLA_CONFIG_DIR/config" ) || die "cannot write $GITZILLA_CONFIG_DIR/config"
    chmod 600 "$GITZILLA_CONFIG_DIR/config"
    ORG_WORKERS="$new"
    wd_log "install: joined org $org ($url)"
    say "push notes for $org/* repos now go to $url"
  else
    say "$org is already set up on this Mac ($url)"
  fi
  say ""
  say "Tell your gitzilla admin this fingerprint: $fp"
  say "  (in person or over a channel you trust; they approve it with: bin/org approve $login $fp)"
}

# ---------------------------------------------------------------------------------------------------------------
from=""; join=""; join_set=0
while [ $# -gt 0 ]; do
  case "$1" in
    --from-step) [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }; from="$2"; shift ;;
    --join-org) [ $# -ge 2 ] || { echo "$JOIN_USAGE" >&2; exit 2; }; join="$2"; join_set=1; shift ;;
    --org) shift ;; # read (and checked) before bin/lib.sh, above
    -h|--help) echo "$USAGE"; echo "steps: $STEPS"; exit 0 ;;
    *) echo "$USAGE" >&2; exit 2 ;;
  esac
  shift
done
if [ "$join_set" = 1 ]; then
  [ -z "$from" ] || { echo "install: --join-org and --from-step do not combine" >&2; exit 2; }
  [ "$org_set" = 0 ] || { echo "install: --join-org and --org do not combine (join from your personal gitzilla, without --org)" >&2; exit 2; }
  join_org "$join"
  exit 0
fi
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
  [ "$s" = "${GITZILLA_INSTALL_STOP_AFTER:-}" ] && break
done
say "install finished."
if [ "$ORG_MODE" = 1 ]; then
  # restore sends its note to the org Worker's /note, which accepts member keys only (not the admin key as such)
  say ""
  say "IMPORTANT: join your own organization and approve your own key, or restore cannot send its note and skips every"
  say "ref with \"could not send note (worker returned 401)\":"
  say "  ./install.sh --join-org ${GITZILLA_URL:-<org-worker-url>}      (personal gitzilla, no GITZILLA_PROFILE)"
  say "  GITZILLA_PROFILE=$GITZILLA_PROFILE bin/org approve <your-login> <the fingerprint --join-org printed>"
fi
