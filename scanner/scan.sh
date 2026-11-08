#!/usr/bin/env bash
# gitzilla bundled scanner: polin-guard plus a few extra checks, run on pushed commits by the standalone
# pre-push hook (hooks/pre-push) and by the Mac agent's deep check (bin/agent).
# READ-ONLY: never executes repo content. Exit 0 clean · 1 findings · 2 error.
#
#   scan.sh staged                  files staged for commit (index content)
#   scan.sh range <base> <tip>      files changed base..tip, read from git objects (no checkout needed)
#                                   base may be "" / 000… → every file in <tip>
#
# Uses the vendored copy of polin-guard 0.3.2 in scanner/polin-guard/ (MIT), so a poisoned pull of the polin-guard
# repo can't disarm the scan. Adds checks polin-guard 0.3.2 lacks: VS Code auto-run tasks, fake-font droppers.
# Node: an optional file scanner/node-path may name the node binary to use; otherwise node from PATH.

set -u
G="$(cd "$(dirname "$0")" && pwd)"
NODE=""
[ -f "$G/node-path" ] && NODE="$(head -n1 "$G/node-path" 2>/dev/null)"
[ -n "$NODE" ] && [ -x "$NODE" ] || NODE="$(command -v node 2>/dev/null)"
[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "gitzilla scanner: node not found — cannot scan" >&2; exit 2; }

ZERO=0000000000000000000000000000000000000000
tmp="$(mktemp -d "${TMPDIR:-/tmp}/aw-scan.XXXXXX")"; trap 'rm -rf "$tmp"' EXIT

# --- collect changed paths and materialize their content into $tmp/w (same relative paths) ---
# Skip: node_modules, and data .json (lottie/fixtures — never executed, huge minified blobs). JSON that
# CAN execute code is kept: package.json (scripts) and .vscode/*.json (tasks/launch/settings).
keep() {
  grep -zvE '(^|/)node_modules/' "$tmp/.all" | grep -zvE '\.json$'
  grep -zvE '(^|/)node_modules/' "$tmp/.all" | grep -zE '(\.vscode/[^/]+|(^|/)package)\.json$'
}
case "${1:-}" in
  staged)
    git diff --cached --name-only --diff-filter=ACMR -z > "$tmp/.all"
    idx="$(git rev-parse --git-path index)" ;;
  range)
    base="${2:-}"; tip="${3:?tip required}"
    if [ -z "$base" ] || [ "$base" = "$ZERO" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
      git ls-tree -r -z --name-only "$tip" > "$tmp/.all"
    else
      git diff --name-only --diff-filter=ACMR -z "$base" "$tip" > "$tmp/.all"
    fi
    idx="$tmp/index"; GIT_INDEX_FILE="$idx" git read-tree "$tip" || exit 2 ;;
  *) echo "usage: scan.sh staged | range <base> <tip>" >&2; exit 2 ;;
esac
keep > "$tmp/.list"
[ -s "$tmp/.list" ] || exit 0
# one process for all files; repo .gitattributes can't run commands (filter drivers need local config)
GIT_INDEX_FILE="$idx" git checkout-index -z --stdin --prefix="$tmp/w/" < "$tmp/.list" 2>/dev/null
[ -d "$tmp/w" ] || exit 0

rc=0
# polin-guard's allowlist lives in the repo, so an attacker can ship one — never let it apply here.
if grep -qzE '(^|/)\.polinguardrc\.json$' "$tmp/.all"; then
  echo "  note     repo .polinguardrc.json is in the scanned files — repo allowlists are IGNORED by this guard" >&2
fi
find "$tmp/w" -name .polinguardrc.json -delete

# --- 1. polin-guard: obfuscated / concealed stagers in JS-family files ---
# polin-guard exits 0 clean, 1 findings, 2 error. macOS xargs reports every failure as exit 1, so each batch runs
# through sh, which leaves a marker: $tmp/.pg-found for findings (exit 1), $tmp/.pg-err for anything else (error,
# crash, signal, a broken node). Only findings count as findings; any other failure means the scan could not run.
pgerr=0
( cd "$tmp/w" && find . -type f -print0 | PGM="$tmp" xargs -0 sh -c '"$0" "$@"; r=$?
    case "$r" in 0) exit 0 ;; 1) : > "$PGM/.pg-found"; exit 1 ;; esac
    : > "$PGM/.pg-err"; echo "gitzilla scanner: polin-guard could not run (node exit $r)" >&2; exit 1' \
    "$NODE" "$G/polin-guard/bin/cli.js" --quiet )
pgx=$?
[ -e "$tmp/.pg-found" ] && rc=1
if [ -e "$tmp/.pg-err" ]; then pgerr=1
elif [ "$pgx" -ne 0 ] && [ "$rc" -eq 0 ]; then pgerr=1; echo "gitzilla scanner: could not start polin-guard (xargs exit $pgx)" >&2
fi


# --- 2. extras polin-guard misses ---
extra() { echo "  CRITICAL $1" >&2; rc=1; }
while IFS= read -r -d '' f; do
  rel="${f#"$tmp/w/"}"
  case "$rel" in
    */.vscode/tasks.json|.vscode/tasks.json)
      grep -qE '"runOn"[[:space:]]*:[[:space:]]*"folderOpen"' "$f" && extra "$rel  [vscode-autorun] task runs automatically when the folder is opened" ;;
    *.llf) extra "$rel  [fake-font-dropper] .llf payload file (PolinRider fonts dropper)" ;;
    *temp_auto_push.bat) extra "$rel  [propagation-artifact] PolinRider worm artifact" ;;
  esac
  case "$rel" in
    *.json|*.js|*.mjs|*.cjs|*.ts|*.sh)
      grep -qE 'node[[:space:]]+\.?/?public/fonts/' "$f" && extra "$rel  [fake-font-dropper] executes a file under public/fonts with node" ;;
  esac
done < <(find "$tmp/w" -type f -print0)

# findings win; otherwise a polin-guard that could not run makes the whole scan an error
[ "$rc" -eq 0 ] && [ "$pgerr" = 1 ] && { echo "gitzilla scanner: scan incomplete (node failed)" >&2; exit 2; }
exit $rc
