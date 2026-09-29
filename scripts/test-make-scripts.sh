#!/usr/bin/env bash
# Pins the make_*.sh wrappers' real logic: make_install.sh/make_uninstall.sh
# must refuse to run when invoked as root, before they touch anything else,
# and must otherwise delegate to build.sh/install.sh/uninstall.sh in order;
# make_test.sh must refuse to run when xcodegen isn't on PATH; the repo-root
# make_build.sh/make_install.sh/make_release.sh must forward their arguments
# and exit status to build.sh/install.sh/package-release.sh, and the root
# make_install.sh must refuse to run as root too. Follows the
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

# --- repo-root make_build.sh / make_install.sh / make_release.sh ----------
# Thin wrappers: each must cd to its own directory, hand every argument
# through unchanged and pass the underlying script's exit status back. Run
# from a throwaway copy of the repo root, against fake scripts that record
# their working directory and arguments and exit 7 — never the real
# build/install/release. Invoked from $WORK, so a wrapper that skipped its
# `cd` shows up as the wrong recorded directory.
TOP="$WORK/fake-top"
mkdir -p "$TOP/scripts"
cp "$ROOT/make_build.sh" "$ROOT/make_install.sh" "$ROOT/make_release.sh" "$TOP/"
for real in build.sh install.sh package-release.sh; do
  {
    printf '#!/bin/sh\n'
    printf 'pwd > "%s/%s.cwd"\n' "$WORK" "$real"
    printf 'printf "%%s\\n" "$@" > "%s/%s.args"\n' "$WORK" "$real"
    printf 'exit 7\n'
  } > "$TOP/scripts/$real"
done
TOP_REAL="$(cd "$TOP" && pwd -P)"

# breaks-if: a root wrapper drops "$@", stops exec'ing (masking the exit code) or skips its cd
for pair in make_build.sh:build.sh make_install.sh:install.sh make_release.sh:package-release.sh; do
  wrapper="${pair%%:*}"; real="${pair#*:}"
  rm -f "$WORK/$real.cwd" "$WORK/$real.args"
  RC=0
  OUT="$(cd "$WORK" && bash "$TOP/$wrapper" 1.2.3 'two words' 2>&1)" || RC=$?
  if [ "$RC" -eq 7 ] \
     && [ "$(cat "$WORK/$real.args" 2>/dev/null)" = "$(printf '1.2.3\ntwo words')" ] \
     && [ "$(cd "$(cat "$WORK/$real.cwd" 2>/dev/null)" 2>/dev/null && pwd -P)" = "$TOP_REAL" ]; then
    pass "$wrapper runs scripts/$real from the repo root with its args and exit code"
  else
    fail "$wrapper runs scripts/$real from the repo root with its args and exit code" \
      "rc=$RC out=$OUT args=$(tr '\n' '|' < "$WORK/$real.args" 2>/dev/null) cwd=$(cat "$WORK/$real.cwd" 2>/dev/null)"
  fi
done

# breaks-if: the repo-root make_install.sh loses its no-sudo guard
rm -f "$WORK/install.sh.args"
RC=0
OUT="$(env PATH="$STUB:$PATH" bash "$TOP/make_install.sh" 2>&1)" || RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"do not run this with sudo"* ]] && [ ! -e "$WORK/install.sh.args" ]; then
  pass "repo-root make_install.sh refuses to run as root before reaching install.sh"
else
  fail "repo-root make_install.sh refuses to run as root before reaching install.sh" "rc=$RC out=$OUT"
fi

# The real wrapper against the real package-release.sh: its usage error must
# come back through make_release.sh unchanged (exit 1, same message).
RC=0
OUT="$(bash "$ROOT/make_release.sh" 2>&1)" || RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"version argument required"* ]]; then
  pass "make_release.sh without a version fails with package-release.sh's usage error"
else
  fail "make_release.sh without a version fails with package-release.sh's usage error" "rc=$RC out=$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
