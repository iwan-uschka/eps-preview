#!/usr/bin/env bash
# Pins the make_*.sh wrappers' real logic: make_install.sh/make_uninstall.sh
# must refuse to run when invoked as root, before they touch anything else,
# and must otherwise delegate to build.sh/install.sh/uninstall.sh in order;
# make_test.sh must refuse to run when xcodegen isn't on PATH. Follows the
# PATH-stub technique in scripts/test-githooks.sh — a stubbed `id` stands in
# for actually running under sudo, so this never needs real root.
#
# make_install.sh/make_uninstall.sh/make_test.sh are run from a throwaway
# copy of scripts/, alongside fake build.sh/install.sh/uninstall.sh, rather
# than against $ROOT/scripts directly — so that if the root guard itself
# ever regresses, this test still never calls the real build/install/
# uninstall scripts (uninstall.sh does `rm -rf /Applications/EPSPreview.app`
# and kills Finder). A regressed guard shows up as the marker-file
# assertions failing, not as a real install/uninstall running.
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

# A throwaway copy of scripts/ with fake build/install/uninstall in place of
# the real (destructive) ones. Each fake records that it was invoked, in
# order, so the non-root delegation path can be checked too.
FAKE_ROOT="$WORK/fake-root"
mkdir -p "$FAKE_ROOT/scripts"
cp "$ROOT/scripts/make_install.sh" "$ROOT/scripts/make_uninstall.sh" "$FAKE_ROOT/scripts/"
for real in build.sh install.sh uninstall.sh; do
  {
    printf '#!/bin/sh\n'
    printf 'echo %s >> "%s/call-order.log"\n' "$real" "$WORK"
    printf 'touch "%s/called-%s"\n' "$WORK" "$real"
  } > "$FAKE_ROOT/scripts/$real"
  chmod 0755 "$FAKE_ROOT/scripts/$real"
done

run_as_root() {
  local script="$1"
  rm -f "$WORK"/called-* "$WORK/call-order.log"
  OUT=""
  RC=0
  OUT="$(env PATH="$STUB:$PATH" bash "$FAKE_ROOT/scripts/$script" 2>&1)" || RC=$?
}

# Same as run_as_root, but without the root-reporting `id` stub — exercises
# the delegation path (build.sh → install.sh, or → uninstall.sh) that the
# root guard only short-circuits, not the guard itself. Relies on the test
# actually running as a non-root user, same as everything else here.
run_as_non_root() {
  local script="$1"
  rm -f "$WORK"/called-* "$WORK/call-order.log"
  OUT=""
  RC=0
  OUT="$(bash "$FAKE_ROOT/scripts/$script" 2>&1)" || RC=$?
}

OUT=""
RC=0

run_as_root make_install.sh
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"do not run this with sudo"* ]]; then
  pass "make_install.sh refuses to run as root"
else
  fail "make_install.sh refuses to run as root" "rc=$RC out=$OUT"
fi
if [ ! -e "$WORK/called-build.sh" ] && [ ! -e "$WORK/called-install.sh" ]; then
  pass "make_install.sh's root guard never reaches build.sh/install.sh"
else
  fail "make_install.sh's root guard never reaches build.sh/install.sh" \
    "found: $(cd "$WORK" && ls called-* 2>/dev/null | tr '\n' ' ')"
fi

run_as_root make_uninstall.sh
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"do not run this with sudo"* ]]; then
  pass "make_uninstall.sh refuses to run as root"
else
  fail "make_uninstall.sh refuses to run as root" "rc=$RC out=$OUT"
fi
if [ ! -e "$WORK/called-uninstall.sh" ]; then
  pass "make_uninstall.sh's root guard never reaches uninstall.sh"
else
  fail "make_uninstall.sh's root guard never reaches uninstall.sh" "uninstall.sh was invoked"
fi

run_as_non_root make_install.sh
if [ "$RC" -eq 0 ] && [ "$(cat "$WORK/call-order.log" 2>/dev/null)" = "$(printf 'build.sh\ninstall.sh')" ]; then
  pass "make_install.sh delegates to build.sh then install.sh when not root"
else
  fail "make_install.sh delegates to build.sh then install.sh when not root" \
    "rc=$RC out=$OUT order=$(cat "$WORK/call-order.log" 2>/dev/null | tr '\n' ',')"
fi

run_as_non_root make_uninstall.sh
if [ "$RC" -eq 0 ] && [ "$(cat "$WORK/call-order.log" 2>/dev/null)" = "uninstall.sh" ]; then
  pass "make_uninstall.sh delegates to uninstall.sh when not root"
else
  fail "make_uninstall.sh delegates to uninstall.sh when not root" \
    "rc=$RC out=$OUT order=$(cat "$WORK/call-order.log" 2>/dev/null | tr '\n' ',')"
fi

# --- make_test.sh: the xcodegen-missing guard ------------------------------
# Only the early-exit guard is covered here. The xcbeautify-vs-cat fallback
# a few lines further down runs a real `xcodebuild test`, which would need a
# fake xcodebuild plumbed through the same throwaway-scripts.sh technique as
# scripts/test-githooks.sh's pre-push case — worthwhile, but a separate,
# larger addition than this guard check.
cp "$ROOT/scripts/make_test.sh" "$FAKE_ROOT/scripts/"
NO_XCODEGEN_STUB="$WORK/no-xcodegen-stub"
mkdir -p "$NO_XCODEGEN_STUB"
OUT=""
RC=0
OUT="$(env PATH="$NO_XCODEGEN_STUB:/usr/bin:/bin" bash "$FAKE_ROOT/scripts/make_test.sh" 2>&1)" || RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"xcodegen not found"* ]]; then
  pass "make_test.sh refuses to run without xcodegen on PATH"
else
  fail "make_test.sh refuses to run without xcodegen on PATH" "rc=$RC out=$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
