# account-watchdog shared helpers. Source me; defines functions/defaults only (no output, no exit).
# Compatible with macOS bash 3.2.

WATCHDOG_CONFIG_DIR="${WATCHDOG_CONFIG_DIR:-$HOME/.config/account-watchdog}"
STATE="${WATCHDOG_STATE_DIR:-$HOME/.local/state/account-watchdog}"
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

# shellcheck disable=SC1090
[ -f "$WATCHDOG_CONFIG_DIR/config" ] && . "$WATCHDOG_CONFIG_DIR/config"

# Hooks run from GUI git clients (GitHub Desktop, Tower, Xcode, ...) get PATH=/usr/bin:/bin:/usr/sbin:/sbin. When no jq
# is on PATH, use the one install.sh's hook step recorded in $WATCHDOG_CONFIG_DIR/jq-path.
if ! command -v jq >/dev/null 2>&1 && [ -f "$WATCHDOG_CONFIG_DIR/jq-path" ]; then
  _wd_jq="$(head -n1 "$WATCHDOG_CONFIG_DIR/jq-path" 2>/dev/null)"
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
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$STATE/log/watchdog.log" 2>/dev/null
  return 0
}

# wd_notify <title> <message>: desktop notification (WATCHDOG_NOTIFY_CMD overrides, for tests).
wd_notify() {
  if [ -n "${WATCHDOG_NOTIFY_CMD:-}" ]; then
    "$WATCHDOG_NOTIFY_CMD" "$1" "$2" </dev/null >/dev/null 2>&1 || { wd_log "notify command failed"; return 1; }
  else
    osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
      -e 'end run' -- "$1" "$2" </dev/null >/dev/null 2>&1 || { wd_log "osascript notify failed"; return 1; }
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
  if [ -n "${WATCHDOG_SIGN_KEY:-}" ]; then
    ssh-keygen -q -Y sign -f "$WATCHDOG_SIGN_KEY" -n "$ns" "$dir/msg" >/dev/null 2>&1 || rc=1
  else
    SSH_AUTH_SOCK="$SECRETIVE_SOCK" ssh-keygen -q -Y sign -f "$NOTE_PUBKEY_FILE" -n "$ns" "$dir/msg" >/dev/null 2>&1 || rc=1
  fi
  [ "$rc" -eq 0 ] && [ -s "$dir/msg.sig" ] && cat "$dir/msg.sig" || rc=1
  rm -rf "$dir"
  return "$rc"
}

# wd_send_note <repo> <ref> <old_sha> <new_sha> -> 0 on 204; on failure sets WD_REASON, returns 1
wd_send_note() {
  local repo="$1" ref="$2" old="$3" new="$4" dir payload sig body code
  WD_REASON=""
  if [ -z "${WATCHDOG_URL:-}" ] || { [ -z "${WATCHDOG_SIGN_KEY:-}" ] && [ -z "${NOTE_PUBKEY_FILE:-}" ]; }; then
    WD_REASON="not configured"; return 1
  fi
  dir="$(mktemp -d)" || { WD_REASON="no temp dir"; return 1; }
  if ! jq -cn --arg repo "$repo" --arg ref "$ref" --arg old "$old" --arg new "$new" \
        --argjson ts "$(date +%s)" --arg nonce "$(openssl rand -hex 16)" \
        '{repo:$repo,ref:$ref,old_sha:$old,new_sha:$new,ts:$ts,nonce:$nonce}' | tr -d '\n' > "$dir/payload"; then
    WD_REASON="payload build failed"; rm -rf "$dir"; return 1
  fi
  if ! sig="$(wd_sign account-watchdog-note "$dir/payload")"; then
    WD_REASON="signing failed"; rm -rf "$dir"; return 1
  fi
  if ! jq -cn --arg p "$(base64 < "$dir/payload" | tr -d '\n')" --arg s "$sig" '{payload:$p,sig:$s}' > "$dir/body"; then
    WD_REASON="body build failed"; rm -rf "$dir"; return 1
  fi
  code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' -X POST \
          -H 'Content-Type: application/json' --data-binary @"$dir/body" "$WATCHDOG_URL/note" 2>/dev/null)"
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
  if [ -z "${WATCHDOG_URL:-}" ] || { [ -z "${WATCHDOG_SIGN_KEY:-}" ] && [ -z "${NOTE_PUBKEY_FILE:-}" ]; }; then
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
      if ! sig="$(wd_sign account-watchdog-report "$dir/payload")"; then
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
          -H 'Content-Type: application/json' --data-binary @"$dir/body" "$WATCHDOG_URL/report" 2>/dev/null)"
  rm -rf "$dir"
  if [ "$code" = "204" ]; then return 0; fi
  case "$code" in ""|000) WD_REASON="worker unreachable" ;; *) WD_REASON="worker returned $code" ;; esac
  return 1
}

# wd_send_alert new-key <key_type> <fingerprint> <auth|signing>
# wd_send_alert missed-webhook <refs> <repos>
# Signed account alert to the Worker (POST /alert -> phone + Slack; the Worker writes the text). 0 on 204; on
# failure sets WD_REASON, returns 1.
wd_send_alert() {
  local kind="$1" dir sig code
  WD_REASON=""
  if [ -z "${WATCHDOG_URL:-}" ] || { [ -z "${WATCHDOG_SIGN_KEY:-}" ] && [ -z "${NOTE_PUBKEY_FILE:-}" ]; }; then
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
    *) false ;;
  esac 2>/dev/null | tr -d '\n' > "$dir/payload"
  if [ ! -s "$dir/payload" ]; then WD_REASON="payload build failed"; rm -rf "$dir"; return 1; fi
  if ! sig="$(wd_sign account-watchdog-alert "$dir/payload")"; then
    WD_REASON="signing failed"; rm -rf "$dir"; return 1
  fi
  if ! jq -cn --arg p "$(base64 < "$dir/payload" | tr -d '\n')" --arg s "$sig" '{payload:$p,sig:$s}' > "$dir/body"; then
    WD_REASON="body build failed"; rm -rf "$dir"; return 1
  fi
  code="$(curl --max-time 5 -sS -o /dev/null -w '%{http_code}' -X POST \
          -H 'Content-Type: application/json' --data-binary @"$dir/body" "$WATCHDOG_URL/alert" 2>/dev/null </dev/null)"
  rm -rf "$dir"
  if [ "$code" = "204" ]; then return 0; fi
  case "$code" in ""|000) WD_REASON="worker unreachable" ;; *) WD_REASON="worker returned $code" ;; esac
  return 1
}
