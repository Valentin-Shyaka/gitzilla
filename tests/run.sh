#!/usr/bin/env bash
# Runs every tests/test_*.sh; exits non-zero if any fail.
dir="$(cd "$(dirname "$0")" && pwd)"
fail=0; total=0
for t in "$dir"/test_*.sh; do
  [ -e "$t" ] || continue
  total=$((total+1))
  echo "== $(basename "$t")"
  if bash "$t"; then echo "PASS $(basename "$t")"; else echo "FAIL $(basename "$t")"; fail=$((fail+1)); fi
done
echo "---- $((total-fail))/$total test files passed"
[ "$fail" -eq 0 ]
