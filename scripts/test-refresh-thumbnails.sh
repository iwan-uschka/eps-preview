#!/usr/bin/env bash
# Pins refresh-thumbnails.sh's failure path: when `qlmanage -r cache` fails,
# the script must stop with exit 1 and say the cache was NOT reset, before it
# restarts Finder or any agent. Uses the same PATH-stub technique as
# scripts/test-make-scripts.sh — stubbed `qlmanage` and `killall` shadow the
# real ones, so this never resets a real cache or kills a real process.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-refresh-thumbnails-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# A fake `killall` that only records it was called.
STUB="$WORK/stub"
mkdir -p "$STUB"
{
  printf '#!/bin/sh\n'
  printf 'touch "%s/called-killall"\n' "$WORK"
} > "$STUB/killall"
chmod 0755 "$STUB/killall"

# Installs a fake `qlmanage` that exits with the given code.
stub_qlmanage() {
  printf '#!/bin/sh\nexit %s\n' "$1" > "$STUB/qlmanage"
  chmod 0755 "$STUB/qlmanage"
}

run_refresh() {
  rm -f "$WORK/called-killall"
  OUT=""
  RC=0
  OUT="$(env PATH="$STUB:$PATH" bash "$ROOT/scripts/refresh-thumbnails.sh" 2>&1)" || RC=$?
}

stub_qlmanage 1
run_refresh
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"NOT reset"* ]]; then
  pass "refresh-thumbnails.sh exits 1 and reports the cache NOT reset when qlmanage fails"
else
  fail "refresh-thumbnails.sh exits 1 and reports the cache NOT reset when qlmanage fails" \
    "rc=$RC out=$OUT"
fi
if [ ! -e "$WORK/called-killall" ]; then
  pass "refresh-thumbnails.sh restarts nothing when qlmanage fails"
else
  fail "refresh-thumbnails.sh restarts nothing when qlmanage fails" "killall was invoked"
fi

stub_qlmanage 0
run_refresh
if [ "$RC" -eq 0 ] && [ -e "$WORK/called-killall" ]; then
  pass "refresh-thumbnails.sh succeeds and restarts Finder/agents when qlmanage succeeds"
else
  fail "refresh-thumbnails.sh succeeds and restarts Finder/agents when qlmanage succeeds" \
    "rc=$RC out=$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
