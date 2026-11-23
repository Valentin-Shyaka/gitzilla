# gitzilla shared helpers. Source me; defines functions/defaults only (no output, no exit), except that an invalid
# GITZILLA_PROFILE stops the caller (exit 2) before anything is read or written.
# Compatible with macOS bash 3.2.

# Profiles: GITZILLA_PROFILE=<p> runs a separate instance (an org's, next to the personal one) with its config in
# ~/.config/gitzilla/<p>, its state, log and mirrors in ~/.local/state/gitzilla/<p>, and its own launchd labels.
# Unset or empty = personal: today's paths. GITZILLA_CONFIG_DIR / GITZILLA_STATE_DIR, when set, still win (the
# launchd jobs set both). A profile may not be named like an entry bin/* or install.sh writes directly in the
# personal config dir or state dir (WD_RESERVED_NAMES), since its directory would then be that file or directory.
# Entries with a dot (repos.txt, rotation.json, ...) cannot collide: a profile name has no dot. Keep this list
# complete when a new file is added under $GITZILLA_CONFIG_DIR or $STATE.
WD_RESERVED_NAMES="config jq-path log mirrors incidents install-step install-set-hookspath install-secrets-rotated
queue-cursor queue-fail-since queue-notified health-notified health-fail-since reconcile-all-at allowed_signers gh"
GITZILLA_PROFILE="${GITZILLA_PROFILE:-}"
if [ -n "$GITZILLA_PROFILE" ]; then
  _wd_ok='^[a-z0-9][a-z0-9-]{0,39}$'
  if [[ $GITZILLA_PROFILE =~ $_wd_ok ]]; then _wd_ok=1; else _wd_ok=0; fi
  for _wd_r in $WD_RESERVED_NAMES; do [ "$GITZILLA_PROFILE" = "$_wd_r" ] && _wd_ok=0; done
  unset _wd_r
  if [ "$_wd_ok" != 1 ]; then
    printf 'gitzilla: invalid GITZILLA_PROFILE: use 1-40 lower-case letters, digits or hyphens, starting with a letter or digit, and not a name gitzilla uses for its own files (%s)\n' "$(echo $WD_RESERVED_NAMES)" >&2
    exit 2
  fi
  unset _wd_ok
  GITZILLA_CONFIG_DIR="${GITZILLA_CONFIG_DIR:-$HOME/.config/gitzilla/$GITZILLA_PROFILE}"
  STATE="${GITZILLA_STATE_DIR:-$HOME/.local/state/gitzilla/$GITZILLA_PROFILE}"
else
  GITZILLA_CONFIG_DIR="${GITZILLA_CONFIG_DIR:-$HOME/.config/gitzilla}"
  STATE="${GITZILLA_STATE_DIR:-$HOME/.local/state/gitzilla}"
fi
# A profile has its own gh login (install.sh's prereqs step: a read-only fine-grained token whose resource owner is the
# org), kept by gh in <profile config dir>/gh, never the personal login (a user-owned token cannot see an org's private
# repos). The gh token variables would override that store, so a profile drops them. Personal: gh as it is.
if [ -n "$GITZILLA_PROFILE" ]; then
  GH_CONFIG_DIR="$GITZILLA_CONFIG_DIR/gh"; export GH_CONFIG_DIR
  unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST
fi
SECRETIVE_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
WD_REVOKE="If this wasn't you: revoke tokens at https://github.com/settings/applications"
WD_REASON=""

# wd_allowed_signers: the allowed-signers file git verifies commit signatures with: the global
# gpg.ssh.allowedSignersFile (a leading ~ expanded), else ~/.config/git/allowed_signers.
wd_allowed_signers() {
  local f
  f="$(git config --global --includes --get gpg.ssh.allowedSignersFile 2>/dev/null)" # --includes: dotfile include.path
  case "$f" in "~") f="$HOME" ;; "~/"*) f="$HOME/${f#\~/}" ;; esac
  printf '%s\n' "${f:-$HOME/.config/git/allowed_signers}"
}

# The org-profile settings come only from the profile's config (install.sh --org writes them), never from the
# environment: a stray exported MODE=org must not turn the personal instance into an org one.
unset MODE ORG WORKER_NAME WEB_FLOW
# shellcheck disable=SC1090
[ -f "$GITZILLA_CONFIG_DIR/config" ] && . "$GITZILLA_CONFIG_DIR/config"

# wd_signers_file: the allowed-signers file the signature checks (agent deep check, restore target) use. Personal:
# ALLOWED_SIGNERS_FILE (tests), else git's (wd_allowed_signers). Org profile (MODE=org): only the profile's own
# $GITZILLA_CONFIG_DIR/allowed_signers (the members' commit-signing keys), never the admin's personal one; it may be
# missing or empty, which wd_org_signers_ok reports.
wd_signers_file() {
  if [ "${MODE:-}" = org ]; then printf '%s\n' "$GITZILLA_CONFIG_DIR/allowed_signers"
  else printf '%s\n' "${ALLOWED_SIGNERS_FILE:-$(wd_allowed_signers)}"; fi
}
# wd_org_signers_ok: org profile only; 0 when the profile's allowed_signers holds at least one non-comment line.
wd_org_signers_ok() {
  [ -s "$GITZILLA_CONFIG_DIR/allowed_signers" ] && grep -qv '^[[:space:]]*\(#\|$\)' "$GITZILLA_CONFIG_DIR/allowed_signers" 2>/dev/null
}

# wd_timeout <seconds> <cmd...>: run cmd, kill it after <seconds>, then print what it wrote to stdout (stderr passes
# through). Returns cmd's status (non-zero when it was killed). The output goes through a temp file, not a pipe, so a
# $(...) caller never waits for a killed command's children (or the watcher) to let go of the pipe.
wd_timeout() {
  local s="$1" pid w rc f
  shift
  f="$(mktemp)" || return 1
  "$@" > "$f" </dev/null &
  pid=$!
  ( sleep "$s"; kill "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  w=$!
  wait "$pid"; rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  cat "$f"; rm -f "$f"
  return "$rc"
}

# Hooks run from GUI git clients (GitHub Desktop, Tower, Xcode, ...) get PATH=/usr/bin:/bin:/usr/sbin:/sbin. When no jq
# is on PATH, use the one install.sh's hook step recorded in $GITZILLA_CONFIG_DIR/jq-path.
if ! command -v jq >/dev/null 2>&1 && [ -f "$GITZILLA_CONFIG_DIR/jq-path" ]; then
  _wd_jq="$(head -n1 "$GITZILLA_CONFIG_DIR/jq-path" 2>/dev/null)"
  [ -n "$_wd_jq" ] && [ -x "$_wd_jq" ] && PATH="${_wd_jq%/*}:$PATH"
  unset _wd_jq
fi

# repo_slug <remote-url> -> lower-case owner/repo, or nothing if not github.com
repo_slug() {
  local u="$1" rest
  case "$u" in
    git@github.com:*)            rest="${u#git@github.com:}" ;;
    ssh://git@github.com/*)      rest="${u#ssh://git@github.com/}" ;;
    ssh://github.com/*)          rest="${u#ssh://github.com/}" ;;
    https://github.com/*)        rest="${u#https://github.com/}" ;;
    https://*@github.com/*)      rest="${u#https://*@github.com/}" ;;
    http://github.com/*)         rest="${u#http://github.com/}" ;;
    git://github.com/*)          rest="${u#git://github.com/}" ;;
    *) return 0 ;;
  esac
  rest="${rest%/}"; rest="${rest%.git}"; rest="${rest%/}"
  case "$rest" in */*/*|""|/*|*/) return 0 ;; */*) ;; *) return 0 ;; esac
  printf '%s\n' "$rest" | tr '[:upper:]' '[:lower:]'
}

wd_log() {
  mkdir -p "$STATE/log" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/log/gitzilla.log" 2>/dev/null
  return 0
}

# wd_title <title>: in a profile, "gitzilla: X" -> "gitzilla (<profile>): X" and "gitzilla" -> "gitzilla (<profile>)", so
# an org's notifications and dialogs are told apart from the personal ones. Personal: unchanged.
wd_title() {
  if [ -z "$GITZILLA_PROFILE" ]; then printf '%s\n' "$1"; return 0; fi
  case "$1" in
    gitzilla) printf 'gitzilla (%s)\n' "$GITZILLA_PROFILE" ;;
    gitzilla:*) printf 'gitzilla (%s):%s\n' "$GITZILLA_PROFILE" "${1#gitzilla:}" ;;
    *) printf '%s (%s)\n' "$1" "$GITZILLA_PROFILE" ;;
  esac
}

# wd_notify <title> <message>: desktop notification (GITZILLA_NOTIFY_CMD overrides, for tests). The title names the
# profile (wd_title).
wd_notify() {
  local t
  t="$(wd_title "$1")"
  if [ -n "${GITZILLA_NOTIFY_CMD:-}" ]; then
    "$GITZILLA_NOTIFY_CMD" "$t" "$2" </dev/null >/dev/null 2>&1 || { wd_log "notify command failed"; return 1; }
  else
    osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' -- "$t" "$2" </dev/null >/dev/null 2>&1 || { wd_log "osascript notify failed"; return 1; }
  fi
  return 0
}

# mirror_path <slug> -> $STATE/mirrors/<owner>__<repo>.git
mirror_path() {
  local s="$1"
  printf '%s/mirrors/%s__%s.git\n' "$STATE" "${s%%/*}" "${s#*/}"
}

# One ssh session (one Touch ID) per job. ControlPath lives in ~/.ssh (short: ssh needs the socket path plus a
# 17-char temp suffix under 104 bytes). IdentityAgent names Secretive explicitly, so launchd jobs work even when
# the socket is only exported in a shell profile.
wd_ssh_env() {
  mkdir -p "$STATE" 2>/dev/null
  [ -d "$HOME/.ssh" ] || mkdir -m 700 "$HOME/.ssh" 2>/dev/null
  export GIT_SSH_COMMAND="ssh -o ControlMaster=auto -o \"ControlPath=$HOME/.ssh/wd-%C\" -o ControlPersist=120 -o \"IdentityAgent=$SECRETIVE_SOCK\" -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"
}

# wd_mirror_harden <mirror>: a mirror must keep every object restore may need (commits copied in by `note` are
# referenced only by FETCH_HEAD; forced fetches orphan old tips), so it never auto-gcs or prunes, and logs ref moves.
wd_mirror_harden() {
  git -C "$1" config gc.auto 0 &&
  git -C "$1" config gc.pruneExpire never &&
  git -C "$1" config core.logAllRefUpdates always
}

# wd_repos_from_gh <owner-lc>: `gh repo list --json nameWithOwner,visibility` JSON on stdin ->
# "<lower-case slug> public|private" lines for the owner's repos (the repos.txt format; install and rotate share it).
wd_repos_from_gh() {
  jq -r --arg o "$1" '.[] | [(.nameWithOwner | ascii_downcase), (if (.visibility | ascii_downcase) == "public" then "public" else "private" end)]
      | select(.[0] | startswith($o + "/")) | join(" ")'
}

# wd_sign <namespace> <file> -> armored SSHSIG on stdout
wd_sign() {
  local ns="$1" file="$2" dir rc=0
  dir="$(mktemp -d)" || return 1
  cp "$file" "$dir/msg" || { rm -rf "$dir"; return 1; }
  if [ -n "${GITZILLA_SIGN_KEY:-}" ]; then
    ssh-keygen -q -Y sign -f "$GITZILLA_SIGN_KEY" -n "$ns" "$dir/msg" >/dev/null 2>&1 || rc=1
  else
    SSH_AUTH_SOCK="$SECRETIVE_SOCK" ssh-keygen -q -Y sign -f "$NOTE_PUBKEY_FILE" -n "$ns" "$dir/msg" >/dev/null 2>&1 || rc=1
  fi
  [ "$rc" -eq 0 ] && [ -s "$dir/msg.sig" ] && cat "$dir/msg.sig" || rc=1
  rm -rf "$dir"
  return "$rc"
}

# ---- organizations. The personal config's ORG_WORKERS holds space-separated "<org-login>=<worker-url>" pairs
# (install.sh --join-org writes it): pushes to that org's repos send their note to that org's Worker.
# GitHub login, lower-cased (the Worker's LOGIN_RE); "_" for Enterprise Managed Users (<user>_<shortcode>)
WD_LOGIN_RE='^[a-z0-9][a-z0-9_-]{0,38}$'
WD_BOT_RE='^[a-z0-9][a-z0-9_-]{0,38}(\[bot\])?$' # an allow-listed bot login (the Worker's BOT_RE)
WD_FP_RE='^SHA256:[A-Za-z0-9+/]{43}$'

# wd_lc <s> -> lower-cased s
wd_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# wd_valid_worker_url <url>: an https origin with no path (http only for 127.0.0.1 / localhost, for tests).
wd_valid_worker_url() {
  local re_https='^https://[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?(:[0-9]{1,5})?$'
  local re_local='^http://(127\.0\.0\.1|localhost)(:[0-9]{1,5})?$'
  [[ $1 =~ $re_https ]] || [[ $1 =~ $re_local ]]
}

# wd_org_worker <org-login>: the Worker URL ORG_WORKERS holds for that org (compared lower-cased), or nothing.
wd_org_worker() {
  local want pair o u pairs=()
  want="$(wd_lc "$1")"
  [ -n "$want" ] || return 0
  # split without globbing: a hand-edited entry with * or ? must not expand to file names
  IFS=$' \t\n' read -r -d '' -a pairs <<< "${ORG_WORKERS:-}" || true
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    o="$(wd_lc "${pair%%=*}")"; u="${pair#*=}"
    [ "$o" = "$want" ] && [ "$pair" != "$u" ] && wd_valid_worker_url "$u" && { printf '%s\n' "$u"; return 0; }
  done
  return 0
}

# wd_envelope <namespace> <payload-file> <body-file>: sign the payload; write {payload: base64, sig} to body-file.
# Sets WD_REASON and returns 1 on failure.
wd_envelope() {
  local sig
  if ! sig="$(wd_sign "$1" "$2")"; then WD_REASON="signing failed"; return 1; fi
  if ! jq -cn --arg p "$(base64 < "$2" | tr -d '\n')" --arg s "$sig" '{payload:$p,sig:$s}' > "$3"; then
    WD_REASON="body build failed"; return 1
  fi
}

# wd_send_note <worker-url> <repo> <ref> <old_sha> <new_sha> -> 0 on 204; on failure sets WD_REASON, returns 1.
# The note goes to <worker-url>/note: the personal Worker for the owner's repos, an org's Worker for its repos.
wd_send_note() {
  local url="$1" repo="$2" ref="$3" old="$4" new="$5" dir payload sig body code
  WD_REASON=""
  if [ -z "$url" ] || { [ -z "${GITZILLA_SIGN_KEY:-}" ] && [ -z "${NOTE_PUBKEY_FILE:-}" ]; }; then
    WD_REASON="not configured"; return 1
  fi
  dir="$(mktemp -d)" || { WD_REASON="no temp dir"; return 1; }
  if ! jq -cn --arg repo "$repo" --arg ref "$ref" --arg old "$old" --arg new "$new" \
        --argjson ts "$(date +%s)" --arg nonce "$(openssl rand -hex 16)" \
        '{repo:$repo,ref:$ref,old_sha:$old,new_sha:$new,ts:$ts,nonce:$nonce}' | tr -d '\n' > "$dir/payload"; then
    WD_REASON="payload build failed"; rm -rf "$dir"; return 1
  fi
  if ! sig="$(wd_sign gitzilla-note "$dir/payload")"; then
    WD_REASON="signing failed"; rm -rf "$dir"; return 1
  fi
  if ! jq -cn --arg p "$(base64 < "$dir/payload" | tr -d '\n')" --arg s "$sig" '{payload:$p,sig:$s}' > "$dir/body"; then
    WD_REASON="body build failed"; rm -rf "$dir"; return 1
  fi
  code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' -X POST \
          -H 'Content-Type: application/json' --data-binary @"$dir/body" "$url/note" 2>/dev/null)"
  rm -rf "$dir"
  if [ "$code" = "204" ]; then return 0; fi
  case "$code" in ""|000) WD_REASON="worker unreachable" ;; *) WD_REASON="worker returned $code" ;; esac
  return 1
}

# wd_send_report <result-json-file> -> 0 on 204; on failure sets WD_REASON, returns 1
# Builds the report the Worker accepts from restore's result.json:
#  - repo is lower-cased (the Worker only accepts lower-case slugs; GitHub slugs are case-insensitive);
#  - restored_total / skipped_total carry the real counts; the lists hold at most 50 entries each and are
#    trimmed (from the end of the longer list, skipped first on a tie) until the whole request body is
#    <= 7600 bytes (Worker limit 8192);
#  - a reason's "(detail)" is sanitised to [A-Za-z0-9 ._:/-] (other chars -> "-", max 100), as the Worker requires.
wd_send_report() {
  local file="$1" dir sig code kr ks nr ns reserve=1300 tries=0 size b64
  WD_REASON=""
  if [ -z "${GITZILLA_URL:-}" ] || { [ -z "${GITZILLA_SIGN_KEY:-}" ] && [ -z "${NOTE_PUBKEY_FILE:-}" ]; }; then
    WD_REASON="not configured"; return 1
  fi
  dir="$(mktemp -d)" || { WD_REASON="no temp dir"; return 1; }
  if ! jq -c --argjson ts "$(date +%s)" --arg nonce "$(openssl rand -hex 16)" '
        def clean: (.reason | split(" (")) as $p
          | if ($p | length) == 1 then .reason
            else $p[0] + " (" + (($p[1:] | join(" (") | sub("\\)$"; "") | gsub("[^A-Za-z0-9 ._:/-]"; "-"))[:100]) + ")" end;
        {ts:$ts,nonce:$nonce,
         restored_total:((.restored // []) | length), skipped_total:((.skipped // []) | length),
         restored:[(.restored // [])[:50][] | {repo:(.repo|ascii_downcase),ref}],
         skipped:[(.skipped // [])[:50][] | {repo:(.repo|ascii_downcase),ref,reason:clean}]}' "$file" > "$dir/full.json" 2>/dev/null \
     || [ ! -s "$dir/full.json" ]; then
    WD_REASON="payload build failed"; rm -rf "$dir"; return 1
  fi
  kr="$(jq '.restored|length' "$dir/full.json")"; ks="$(jq '.skipped|length' "$dir/full.json")"
  while :; do
    jq -c --argjson kr "$kr" --argjson ks "$ks" '.restored |= .[:$kr] | .skipped |= .[:$ks]' "$dir/full.json" | tr -d '\n' > "$dir/payload"
    size="$(wc -c < "$dir/payload" | tr -d ' ')"
    b64=$(( (size + 2) / 3 * 4 ))
    if [ $((b64 + reserve + 40)) -le 7600 ] || { [ "$kr" -eq 0 ] && [ "$ks" -eq 0 ]; }; then
      if ! sig="$(wd_sign gitzilla-report "$dir/payload")"; then
        WD_REASON="signing failed"; rm -rf "$dir"; return 1
      fi
      if ! jq -cn --arg p "$(base64 < "$dir/payload" | tr -d '\n')" --arg s "$sig" '{payload:$p,sig:$s}' > "$dir/body"; then
        WD_REASON="body build failed"; rm -rf "$dir"; return 1
      fi
      size="$(wc -c < "$dir/body" | tr -d ' ')"
      [ "$size" -le 7600 ] && break
      # signature larger than reserved: reserve more and re-trim (rare)
      tries=$((tries + 1))
      [ "$tries" -ge 3 ] && { WD_REASON="report too large"; rm -rf "$dir"; return 1; }
      reserve=$((reserve + size - 7600 + 100))
      continue
    fi
    if [ "$kr" -gt "$ks" ]; then kr=$((kr - 1)); else ks=$((ks - 1)); fi
  done
  code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' -X POST \
          -H 'Content-Type: application/json' --data-binary @"$dir/body" "$GITZILLA_URL/report" 2>/dev/null)"
  rm -rf "$dir"
  if [ "$code" = "204" ]; then return 0; fi
  case "$code" in ""|000) WD_REASON="worker unreachable" ;; *) WD_REASON="worker returned $code" ;; esac
  return 1
}

# wd_send_alert new-key <key_type> <fingerprint> <auth|signing>
# wd_send_alert missed-webhook <refs> <repos>
# wd_send_alert test                       (bin/notify-test: exactly {kind, ts, nonce})
# Signed account alert to the Worker (POST /alert -> phone + Slack; the Worker writes the text). 0 on 204; on
# failure sets WD_REASON, returns 1.
wd_send_alert() {
  local kind="$1" dir sig code
  WD_REASON=""
  if [ -z "${GITZILLA_URL:-}" ] || { [ -z "${GITZILLA_SIGN_KEY:-}" ] && [ -z "${NOTE_PUBKEY_FILE:-}" ]; }; then
    WD_REASON="not configured"; return 1
  fi
  dir="$(mktemp -d)" || { WD_REASON="no temp dir"; return 1; }
  case "$kind" in
    new-key)
      jq -cn --arg t "$2" --arg f "$3" --arg s "$4" --argjson ts "$(date +%s)" --arg nonce "$(openssl rand -hex 16)" \
        '{kind:"new-key",ts:$ts,nonce:$nonce,key_type:$t,fingerprint:$f,source:$s}' ;;
    missed-webhook)
      jq -cn --argjson r "$2" --argjson p "$3" --argjson ts "$(date +%s)" --arg nonce "$(openssl rand -hex 16)" \
        '{kind:"missed-webhook",ts:$ts,nonce:$nonce,refs:$r,repos:$p}' ;;
    test)
      jq -cn --argjson ts "$(date +%s)" --arg nonce "$(openssl rand -hex 16)" '{kind:"test",ts:$ts,nonce:$nonce}' ;;
    *) false ;;
  esac 2>/dev/null | tr -d '\n' > "$dir/payload"
  if [ ! -s "$dir/payload" ]; then WD_REASON="payload build failed"; rm -rf "$dir"; return 1; fi
  if ! sig="$(wd_sign gitzilla-alert "$dir/payload")"; then
    WD_REASON="signing failed"; rm -rf "$dir"; return 1
  fi
  if ! jq -cn --arg p "$(base64 < "$dir/payload" | tr -d '\n')" --arg s "$sig" '{payload:$p,sig:$s}' > "$dir/body"; then
    WD_REASON="body build failed"; rm -rf "$dir"; return 1
  fi
  code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' -X POST \
          -H 'Content-Type: application/json' --data-binary @"$dir/body" "$GITZILLA_URL/alert" 2>/dev/null </dev/null)"
  rm -rf "$dir"
  if [ "$code" = "204" ]; then return 0; fi
  case "$code" in ""|000) WD_REASON="worker unreachable" ;; *) WD_REASON="worker returned $code" ;; esac
  return 1
}
