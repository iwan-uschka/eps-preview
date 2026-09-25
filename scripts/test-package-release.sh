#!/usr/bin/env bash
# Pins package-release.sh's version validation: anything that is not
# MAJOR.MINOR.PATCH must exit 1 with the usage text before any build starts.
# Every case here is rejected on the first lines of the script, so nothing is
# built, signed or packaged. The release checks that need a real build (the
# converter and version-mismatch errors) are not covered.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

for version in 1.0 v1.0.0 1.0.0-beta 1.0.0.0 abc; do
  RC=0
  OUT="$(bash "$ROOT/scripts/package-release.sh" "$version" 2>&1)" || RC=$?
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"MAJOR.MINOR.PATCH"* ]] \
     && [[ "$OUT" == *"usage: bash scripts/package-release.sh"* ]] \
     && [[ "$OUT" != *"Build app"* ]]; then
    pass "package-release.sh rejects version '$version' before building"
  else
    fail "package-release.sh rejects version '$version' before building" "rc=$RC out=$OUT"
  fi
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
