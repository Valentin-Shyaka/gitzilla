#!/usr/bin/env bash
# scanner/scan.sh (the bundled scanner) on a temp repo: flags the stager fixture, passes clean files.
. "$(dirname "$0")/helpers.sh"
SCAN="$WD_ROOT/scanner/scan.sh"
if [ -z "$NODE_BIN" ]; then _bad "no usable node found (the scanner needs node)"; finish; exit 1; fi
export PATH="$(dirname "$NODE_BIN"):$PATH"
export TMPDIR="$T/tmpdir"; mkdir -p "$TMPDIR"
R="$T/repo"
git init -q -b main "$R"
scan() { ( cd "$R" && bash "$SCAN" "$@" ) >"$T/out" 2>&1; echo $?; }

echo 'export const answer = 42;' > "$R/clean.js"
printf '# hello\n' > "$R/README.md"
git -C "$R" add . && git -C "$R" commit -q -m clean
assert_eq 0 "$(scan range "" HEAD)" "clean repo: exit 0"
assert_eq 0 "$(scan range 0000000000000000000000000000000000000000 HEAD)" "clean repo, zero base: exit 0"

base64 --decode < "$WD_ROOT/tests/fixtures/stager.js.b64" > "$R/vite.config.js"
git -C "$R" add vite.config.js && git -C "$R" commit -q -m payload
assert_eq 1 "$(scan range "" HEAD)" "stager fixture: exit 1"
assert_contains "$(cat "$T/out")" "vite.config.js" "stager fixture: finding names the file"
assert_eq 1 "$(scan range HEAD~1 HEAD)" "stager in base..tip: exit 1"
echo 'export const more = 1;' > "$R/more.js"
git -C "$R" add more.js && git -C "$R" commit -q -m more
assert_eq 0 "$(scan range HEAD~1 HEAD)" "range without the stager: exit 0"
assert_eq 2 "$(scan bogus)" "bad usage: exit 2"
# a repo allowlist must not switch the scan off
echo '{"ignore":["**"]}' > "$R/.polinguardrc.json"
git -C "$R" add .polinguardrc.json && git -C "$R" commit -q -m rc
assert_eq 1 "$(scan range "" HEAD)" "repo .polinguardrc.json is ignored"
# R2: only polin-guard's findings exit counts as findings; a node that fails or crashes means "could not run" (exit 2)
SC="$T/sc"; cp -R "$WD_ROOT/scanner" "$SC"; rm -f "$SC/node-path"
fake() { printf '#!/bin/sh\n%s\n' "$1" > "$T/fakenode"; chmod 755 "$T/fakenode"; echo "$T/fakenode" > "$SC/node-path"; }
scanc() { ( cd "$R" && bash "$SC/scan.sh" "$@" ) >"$T/out" 2>&1; echo $?; }
echo 'export const z = 3;' > "$R/z.js"; git -C "$R" add z.js && git -C "$R" commit -q -m z
fake 'echo "SyntaxError: boom" >&2; exit 2'
assert_eq 2 "$(scanc range HEAD~1 HEAD)" "R2 scanner: node exiting 2 -> exit 2, not findings"
assert_contains "$(cat "$T/out")" "polin-guard could not run (node exit 2)" "R2 scanner: says polin-guard could not run"
fake 'kill -9 $$'
assert_eq 2 "$(scanc range HEAD~1 HEAD)" "R2 scanner: node killed by a signal -> exit 2"
fake 'exit 1'
assert_eq 1 "$(scanc range HEAD~1 HEAD)" "R2 scanner: polin-guard findings exit (1) -> exit 1"
fake 'exit 0'
assert_eq 0 "$(scanc range HEAD~1 HEAD)" "R2 scanner: polin-guard clean -> exit 0"
echo "$NODE_BIN" > "$SC/node-path"
assert_eq 1 "$(scanc range "" HEAD)" "R2 scanner: real node from node-path, real finding -> exit 1"
assert_eq 0 "$(scanc range HEAD~1 HEAD)" "R2 scanner: real node from node-path, clean range -> exit 0"
assert_eq 0 "$(grep -c 'dist/bin/cli.js' "$SCAN")" "scan.sh uses the vendored scanner/polin-guard"
[ -f "$WD_ROOT/scanner/polin-guard/bin/cli.js" ] && _ok || _bad "vendored polin-guard cli present"
finish
