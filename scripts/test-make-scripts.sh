#!/usr/bin/env bash
# Pins the one piece of real logic in scripts/make_install.sh and
# scripts/make_uninstall.sh: both must refuse to run when invoked as root,
# before they touch anything else. Follows the PATH-stub technique in
# scripts/test-githooks.sh — a stubbed `id` stands in for actually running
# under sudo, so this never needs real root and never calls the underlying
# build/install/uninstall scripts.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-make-scripts-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# A fake `id` that always reports root (uid 0), regardless of the flags it's
# called with — enough to make `[ "$(id -u)" -eq 0 ]` true.
STUB="$WORK/stub"
mkdir -p "$STUB"
{
  printf '#!/bin/sh\n'
  printf 'echo 0\n'
} > "$STUB/id"
chmod 0755 "$STUB/id"

run_as_root() {
  local script="$1"
  OUT=""
  RC=0
  OUT="$(env PATH="$STUB:$PATH" bash "$ROOT/scripts/$script" 2>&1)" || RC=$?
}

OUT=""
RC=0

run_as_root make_install.sh
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"do not run this with sudo"* ]]; then
  pass "make_install.sh refuses to run as root"
else
  fail "make_install.sh refuses to run as root" "rc=$RC out=$OUT"
fi

run_as_root make_uninstall.sh
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"do not run this with sudo"* ]]; then
  pass "make_uninstall.sh refuses to run as root"
else
  fail "make_uninstall.sh refuses to run as root" "rc=$RC out=$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
