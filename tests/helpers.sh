# Test helpers. Source from tests/test_*.sh. Fully isolated from the owner's environment.
WD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Pick a node that still works with a swapped HOME (mise shims need the real one).
NODE_BIN=""
for c in $(type -aP node 2>/dev/null) "$HOME"/.local/share/mise/installs/node/*/bin/node; do
  if [ -x "$c" ] && HOME=/nonexistent "$c" -e 0 >/dev/null 2>&1; then NODE_BIN="$c"; break; fi
done
T="$(mktemp -d)"
[ -n "$T" ] || exit 1
trap 'stop_stub; rm -rf "$T"' EXIT

REAL_HOME="${REAL_HOME:-$HOME}"
export HOME="$T/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$T/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
printf '[user]\n\tname = Test\n\temail = test@example.com\n' > "$GIT_CONFIG_GLOBAL"
export GITZILLA_CONFIG_DIR="$T/config"
export GITZILLA_STATE_DIR="$T/state"
mkdir -p "$GITZILLA_CONFIG_DIR" "$GITZILLA_STATE_DIR"
unset SSH_AUTH_SOCK GIT_SSH_COMMAND

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); }
_bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() { # expected actual msg
  if [ "$1" = "$2" ]; then _ok; else _bad "$3 (expected '$1', got '$2')"; fi
}
assert_contains() { # haystack needle msg
  case "$1" in *"$2"*) _ok ;; *) _bad "$3 (missing '$2' in '$1')" ;; esac
}
finish() { echo "  $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }

# Test signing key + allowed_signers.
make_test_key() {
  ssh-keygen -q -t ed25519 -N '' -C test -f "$T/key" >/dev/null
  export GITZILLA_SIGN_KEY="$T/key"
  echo "test-owner $(cut -d' ' -f1,2 "$T/key.pub")" > "$T/allowed_signers"
}

STUB_PID=""
start_stub() {
  export STUB_LOG="$T/stub.jsonl" STUB_STATUS_FILE="$T/stub.status"
  : > "$STUB_LOG"; rm -f "$STUB_STATUS_FILE" "$T/stub.port"
  "$NODE_BIN" "$WD_ROOT/tests/stub-worker.mjs" > "$T/stub.port" &
  STUB_PID=$!
  local i=0
  while [ ! -s "$T/stub.port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  STUB_PORT="$(head -n1 "$T/stub.port")"
  STUB_URL="http://127.0.0.1:$STUB_PORT"
}
stop_stub() {
  if [ -n "$STUB_PID" ]; then kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null; STUB_PID=""; fi
}
