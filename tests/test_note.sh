#!/usr/bin/env bash
. "$(dirname "$0")/helpers.sh"
make_test_key
start_stub
cat > "$GITZILLA_CONFIG_DIR/config" <<CFG
GITZILLA_URL=$STUB_URL
OWNER=alice
NOTE_PUBKEY_FILE=$T/key.pub
TZ_LOCAL=UTC
CFG

# --- repo_slug
. "$WD_ROOT/bin/lib.sh"
for u in git@github.com:Alice/Repo.git https://github.com/alice/repo \
         ssh://git@github.com/Alice/Repo.git https://github.com/Alice/Repo/; do
  assert_eq "alice/repo" "$(repo_slug "$u")" "repo_slug $u"
done
assert_eq "" "$(repo_slug git@gitlab.com:x/y.git)" "repo_slug non-github"

# --- a repo with a mirror
Z=0000000000000000000000000000000000000000
R="$T/work"; git init -q "$R"; git -C "$R" commit -q --allow-empty -m one
SHA="$(git -C "$R" rev-parse HEAD)"
OLD="1111111111111111111111111111111111111111"
git init -q --bare "$(mirror_path alice/repo)"

lines() { wc -l < "$STUB_LOG" | tr -d ' '; }
run_note() { # url ; stdin lines
  ( cd "$R" && bash "$WD_ROOT/bin/note" origin "$1" 2>"$T/err" ); echo $? > "$T/rc"
}

# push to owned repo
echo "refs/heads/main $SHA refs/heads/main $OLD" | run_note git@github.com:Alice/Repo.git
assert_eq 0 "$(cat "$T/rc")" "exit 0"
assert_eq 1 "$(lines)" "one note received"
assert_eq "" "$(cat "$T/err")" "no stderr on success"
req="$(head -n1 "$STUB_LOG")"
assert_eq "POST" "$(echo "$req" | jq -r .method)" "method"
assert_eq "/note" "$(echo "$req" | jq -r .path)" "path"
body="$(echo "$req" | jq -r .body)"
echo "$body" | jq -r .payload | base64 -d > "$T/payload"
echo "$body" | jq -r .sig > "$T/sig"
ssh-keygen -Y verify -f "$T/allowed_signers" -I test-owner -n gitzilla-note -s "$T/sig" < "$T/payload" >/dev/null 2>&1
assert_eq 0 "$?" "signature verifies"
assert_eq "alice/repo" "$(jq -r .repo "$T/payload")" "repo"
assert_eq "refs/heads/main" "$(jq -r .ref "$T/payload")" "ref"
assert_eq "$OLD" "$(jq -r .old_sha "$T/payload")" "old_sha"
assert_eq "$SHA" "$(jq -r .new_sha "$T/payload")" "new_sha"
assert_eq "number" "$(jq -r '.ts|type' "$T/payload")" "ts number"
now="$(date +%s)"; ts="$(jq -r .ts "$T/payload")"
[ $((now-ts)) -lt 60 ] && _ok || _bad "ts recent"
nonce="$(jq -r .nonce "$T/payload")"
assert_eq 32 "${#nonce}" "nonce length"
case "$nonce" in *[!0-9a-f]*) _bad "nonce hex" ;; *) _ok ;; esac
git -C "$(mirror_path alice/repo)" cat-file -e "$SHA" 2>/dev/null
assert_eq 0 "$?" "mirror has pushed commit"

# branch delete
: > "$STUB_LOG"
echo "(delete) $Z refs/heads/gone $SHA" | run_note https://github.com/Alice/Repo
assert_eq 0 "$(cat "$T/rc")" "delete exit 0"
assert_eq 1 "$(lines)" "delete note sent"
jq -r .body "$STUB_LOG" | jq -r .payload | base64 -d > "$T/payload"
assert_eq "$Z" "$(jq -r .new_sha "$T/payload")" "delete new_sha zeros"
assert_eq "$SHA" "$(jq -r .old_sha "$T/payload")" "delete old_sha"
assert_eq "" "$(cat "$T/err")" "delete no stderr"

# other owner
: > "$STUB_LOG"
echo "refs/heads/main $SHA refs/heads/main $OLD" | run_note git@github.com:someone-else/Repo.git
assert_eq 0 "$(cat "$T/rc")" "other owner exit 0"
assert_eq 0 "$(lines)" "other owner no note"

# non-2xx from worker: fail-open with warning
echo 401 > "$STUB_STATUS_FILE"
echo "refs/heads/main $SHA refs/heads/main $OLD" | run_note git@github.com:Alice/Repo.git
assert_eq 0 "$(cat "$T/rc")" "401 exit 0"
assert_contains "$(cat "$T/err")" "note not sent" "401 warns"
rm -f "$STUB_STATUS_FILE"

# stub stopped
stop_stub
echo "refs/heads/main $SHA refs/heads/main $OLD" | run_note git@github.com:Alice/Repo.git
assert_eq 0 "$(cat "$T/rc")" "down exit 0"
assert_contains "$(cat "$T/err")" "note not sent" "down warns"
assert_contains "$(cat "$T/err")" "this push will raise a warning" "down warning text"

# T6 fail-fast: with the Worker unreachable, only the first ref waits on curl; the others warn at once
mkdir -p "$T/countbin"
printf '#!/bin/sh\necho call >> "%s/curl.calls"\nexec "%s" "$@"\n' "$T" "$(command -v curl)" > "$T/countbin/curl"; chmod +x "$T/countbin/curl"
rm -f "$T/curl.calls"
printf 'refs/heads/a %s refs/heads/a %s\nrefs/heads/b %s refs/heads/b %s\nrefs/tags/v1 %s refs/tags/v1 %s\n' \
  "$SHA" "$OLD" "$SHA" "$OLD" "$SHA" "$Z" | PATH="$T/countbin:$PATH" run_note git@github.com:Alice/Repo.git
assert_eq 0 "$(cat "$T/rc")" "fail-fast: exit 0"
assert_eq 1 "$(wc -l < "$T/curl.calls" | tr -d ' ')" "fail-fast: one curl for three refs"
assert_eq 3 "$(grep -c 'note not sent (worker unreachable) — this push will raise a warning' "$T/err" | tr -d ' ')" "fail-fast: every ref warned"
# a non-unreachable failure (HTTP error) does not skip the rest
start_stub; sed -i.bak "s#^GITZILLA_URL=.*#GITZILLA_URL=$STUB_URL#" "$GITZILLA_CONFIG_DIR/config"
echo 500 > "$STUB_STATUS_FILE"; : > "$STUB_LOG"
printf 'refs/heads/a %s refs/heads/a %s\nrefs/heads/b %s refs/heads/b %s\n' "$SHA" "$OLD" "$SHA" "$OLD" | run_note git@github.com:Alice/Repo.git
assert_eq 2 "$(lines)" "fail-fast: HTTP errors still try every ref"
rm -f "$STUB_STATUS_FILE"; stop_stub

# multi-line push: two branches + tag, plus a new branch (old_sha zeros)
rm -f "$STUB_STATUS_FILE"; start_stub
sed -i.bak "s#^GITZILLA_URL=.*#GITZILLA_URL=$STUB_URL#" "$GITZILLA_CONFIG_DIR/config"
verify_all() { # expected count
  assert_eq "$1" "$(lines)" "note count"
  i=0
  while IFS= read -r l; do
    i=$((i+1))
    echo "$l" | jq -r .body | jq -r .payload | base64 -d > "$T/p$i"
    echo "$l" | jq -r .body | jq -r .sig > "$T/s$i"
    ssh-keygen -Y verify -f "$T/allowed_signers" -I test-owner -n gitzilla-note -s "$T/s$i" < "$T/p$i" >/dev/null 2>&1
    assert_eq 0 "$?" "multi sig $i verifies"
  done < "$STUB_LOG"
}
printf 'refs/heads/a %s refs/heads/a %s\nrefs/heads/b %s refs/heads/b %s\nrefs/tags/v1 %s refs/tags/v1 %s\n' \
  "$SHA" "$OLD" "$SHA" "$OLD" "$SHA" "$Z" | run_note git@github.com:Alice/Repo.git
verify_all 3
assert_eq "refs/heads/a" "$(jq -r .ref "$T/p1")" "multi ref 1"
assert_eq "refs/heads/b" "$(jq -r .ref "$T/p2")" "multi ref 2"
assert_eq "refs/tags/v1" "$(jq -r .ref "$T/p3")" "multi ref 3 tag"
assert_eq "$Z" "$(jq -r .old_sha "$T/p3")" "new ref old_sha zeros"
assert_eq "$OLD" "$(jq -r .old_sha "$T/p1")" "multi old_sha 1"

# stdin isolation: a curl that reads stdin must not swallow remaining lines
: > "$STUB_LOG"
REAL_CURL="$(command -v curl)"
mkdir -p "$T/fakebin"
printf '#!/bin/sh\ncat >/dev/null\nexec "%s" "$@"\n' "$REAL_CURL" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
printf 'refs/heads/a %s refs/heads/a %s\nrefs/heads/b %s refs/heads/b %s\nrefs/tags/v1 %s refs/tags/v1 %s\n' \
  "$SHA" "$OLD" "$SHA" "$OLD" "$SHA" "$Z" | PATH="$T/fakebin:$PATH" run_note git@github.com:Alice/Repo.git
verify_all 3

# GIT_DIR exported (as git may do for hooks): mirror must still receive objects
R2="$T/work2"; git init -q "$R2"; git -C "$R2" commit -q --allow-empty -m two
SHA2="$(git -C "$R2" rev-parse HEAD)"
echo "refs/heads/main $SHA2 refs/heads/main $OLD" | ( cd "$R2" && GIT_DIR="$R2/.git" bash "$WD_ROOT/bin/note" origin git@github.com:Alice/Repo.git 2>/dev/null )
git -C "$(mirror_path alice/repo)" cat-file -e "$SHA2" 2>/dev/null
assert_eq 0 "$?" "mirror receives commit with GIT_DIR set"
stop_stub

# not configured
rm "$GITZILLA_CONFIG_DIR/config"
echo "refs/heads/main $SHA refs/heads/main $OLD" | run_note git@github.com:Alice/Repo.git
assert_eq 0 "$(cat "$T/rc")" "unconfigured exit 0"
assert_contains "$(cat "$T/err")" "not configured" "unconfigured reason"

finish
