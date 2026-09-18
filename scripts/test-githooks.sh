#!/usr/bin/env bash
# Pins the branching logic in githooks/pre-commit and githooks/pre-push
# against throwaway git repos and stubbed tools. Plain bash — no bats, no
# other dependency — so it runs on a clean checkout:
#
#   bash scripts/test-githooks.sh
#
# Every case copies the real hooks into a fresh `git init` repo under a temp
# workdir, stages fixture files there, and runs the hook with a PATH that
# either provides a stubbed tool or deliberately lacks one. Nothing here
# touches this repo's own index, and no commit or push is ever created.
#
# What it does *not* do is run the real shellcheck, swiftlint or build: the
# stubs stand in for them, so a passing run says the hooks route files and
# exit codes correctly — not that the linters agree with .swiftlint.yml, nor
# that scripts/build.sh itself works.
#
# Not wired into scripts/build.sh: that script builds and signs the app and
# runs no checks of its own.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort the
# run. The hooks themselves run under their own `set -euo pipefail`.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-githooks-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# --- fixtures -------------------------------------------------------------

# $STUB goes first on PATH, so a stub shadows a linter that really is
# installed on this machine.
STUB="$WORK/stub"
mkdir -p "$STUB"

# stub <name> <exit-code>: a fake linter that appends its arguments to
# $WORK/<name>.args and exits with the given status. The args file is removed
# first, so "was it invoked at all?" is just a file-existence check.
stub() {
  local name="$1" code="$2"
  rm -f "$WORK/$name.args"
  {
    printf '#!/bin/sh\n'
    printf 'printf "%%s\\n" "$*" >> "%s/%s.args"\n' "$WORK" "$name"
    printf 'exit %s\n' "$code"
  } > "$STUB/$name"
  chmod 0755 "$STUB/$name"
}

# A PATH that still has git but no linters, for the missing-tool branches.
# Built from symlinks to whatever the real binaries are, so it does not
# depend on where this machine keeps them.
BARE="$WORK/bare"
mkdir -p "$BARE"
for tool in git dirname xcrun sh env bash; do
  real="$(command -v "$tool" 2>/dev/null)" || continue
  [ -n "$real" ] && ln -s "$real" "$BARE/$tool"
done
if ! env PATH="$BARE" git --version >/dev/null 2>&1; then
  echo "error: git does not run under the linter-free fixture PATH ($BARE)," >&2
  echo "       so the missing-tool cases below could not tell a hook that" >&2
  echo "       skipped from a hook whose git call failed." >&2
  exit 1
fi

# A fresh repo per case, so a case can never see another's staged files.
REPO=""
SERIAL=0
new_repo() {
  SERIAL=$(( SERIAL + 1 ))
  REPO="$WORK/repo-$SERIAL"
  mkdir -p "$REPO/githooks" "$REPO/scripts/lib" "$REPO/Sources"
  cp "$ROOT/githooks/pre-commit" "$ROOT/githooks/pre-push" "$REPO/githooks/"
  git init -q "$REPO" >/dev/null 2>&1
}

stage() { git -C "$REPO" add -f -- "$@"; }

# Leaves the hook's combined output in OUT and its status in RC. $1 is the
# PATH to run it under; any further arguments are NAME=VALUE overrides.
OUT=""
RC=0
run_pre_commit() {
  local path="$1"
  shift
  OUT=""
  RC=0
  OUT="$(cd "$REPO" && env PATH="$path" "$@" bash githooks/pre-commit 2>&1)" || RC=$?
}

# --- SKIP_HOOKS -----------------------------------------------------------

new_repo
printf 'this is not valid shell (\n' > "$REPO/scripts/broken.sh"
stage scripts/broken.sh
stub shellcheck 1
run_pre_commit "$STUB:$PATH" SKIP_HOOKS=1
if [ "$RC" -eq 0 ] \
   && [[ "$OUT" == *"skipped (SKIP_HOOKS=1)"* ]] \
   && [ ! -e "$WORK/shellcheck.args" ]; then
  pass "SKIP_HOOKS=1 exits 0 without invoking any linter"
else
  fail "SKIP_HOOKS=1 bypasses the hook" "rc=$RC out=$OUT"
fi

# The bypass is an inequality against "0", so the documented default value
# must *not* read as "skip" — otherwise `SKIP_HOOKS=0 git commit` would
# silently commit unlinted code.
new_repo
printf 'echo ok\n' > "$REPO/scripts/clean.sh"
stage scripts/clean.sh
stub shellcheck 0
run_pre_commit "$STUB:$PATH" SKIP_HOOKS=0
if [ "$RC" -eq 0 ] \
   && [[ "$OUT" != *"skipped"* ]] \
   && [ -s "$WORK/shellcheck.args" ]; then
  pass "SKIP_HOOKS=0 is not a bypass — the linters still run"
else
  fail "SKIP_HOOKS=0 is not a bypass" "rc=$RC out=$OUT"
fi

# --- nothing staged -------------------------------------------------------

new_repo
stub shellcheck 1
stub swiftlint 1
run_pre_commit "$STUB:$PATH"
if [ "$RC" -eq 0 ] \
   && [[ "$OUT" == *"no staged shell scripts"* ]] \
   && [[ "$OUT" == *"no staged Swift sources"* ]] \
   && [ ! -e "$WORK/shellcheck.args" ] \
   && [ ! -e "$WORK/swiftlint.args" ]; then
  pass "an empty staged set reports both skips and exits 0"
else
  fail "empty staged set" "rc=$RC out=$OUT"
fi

# --- which files reach shellcheck ----------------------------------------
# The pathspec has to cross directory boundaries: scripts/lib/*.sh is real
# code in this repo, and letting it through unchecked defeats the hook.

new_repo
printf 'echo top\n' > "$REPO/scripts/top.sh"
printf 'echo nested\n' > "$REPO/scripts/lib/nested.sh"
stage scripts/top.sh scripts/lib/nested.sh
stub shellcheck 0
run_pre_commit "$STUB:$PATH"
if [ "$RC" -eq 0 ] \
   && [[ "$(cat "$WORK/shellcheck.args" 2>/dev/null)" == *"scripts/lib/nested.sh"* ]] \
   && [[ "$(cat "$WORK/shellcheck.args" 2>/dev/null)" == *"scripts/top.sh"* ]]; then
  pass "a shell script in a scripts/ subdirectory is shellchecked too"
else
  fail "nested shell scripts are shellchecked" \
    "rc=$RC args=$(cat "$WORK/shellcheck.args" 2>/dev/null)"
fi

# Files the hook does not claim to cover must not be handed to shellcheck.
new_repo
printf 'echo elsewhere\n' > "$REPO/elsewhere.sh"
stage elsewhere.sh
stub shellcheck 1
run_pre_commit "$STUB:$PATH"
if [ "$RC" -eq 0 ] && [ ! -e "$WORK/shellcheck.args" ]; then
  pass "a shell script outside scripts/ and githooks/ is left alone"
else
  fail "only scripts/ and the hooks are shellchecked" "rc=$RC out=$OUT"
fi

# --- failures and aggregation --------------------------------------------

new_repo
printf 'echo shell\n' > "$REPO/scripts/bad.sh"
printf 'let x = 1\n' > "$REPO/Sources/Bad.swift"
printf 'disabled_rules: []\n' > "$REPO/.swiftlint.yml"
stage scripts/bad.sh Sources/Bad.swift .swiftlint.yml
stub shellcheck 1
stub swiftlint 0
run_pre_commit "$STUB:$PATH"
if [ "$RC" -eq 1 ] \
   && [[ "$OUT" == *"checks failed"* ]] \
   && [ -s "$WORK/swiftlint.args" ]; then
  pass "a shellcheck failure fails the commit but still runs SwiftLint"
else
  fail "both linters always run" "rc=$RC out=$OUT"
fi

new_repo
printf 'let x = 1\n' > "$REPO/Sources/Bad.swift"
printf 'disabled_rules: []\n' > "$REPO/.swiftlint.yml"
stage Sources/Bad.swift .swiftlint.yml
stub swiftlint 1
run_pre_commit "$STUB:$PATH"
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"checks failed"* ]]; then
  pass "a SwiftLint failure fails the commit"
else
  fail "a SwiftLint failure fails the commit" "rc=$RC out=$OUT"
fi

# --- missing tools --------------------------------------------------------

new_repo
printf 'echo ok\n' > "$REPO/scripts/clean.sh"
stage scripts/clean.sh
run_pre_commit "$BARE"
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"shellcheck not found"* ]]; then
  pass "staged shell scripts with no shellcheck installed fail with a hint"
else
  fail "missing shellcheck is reported" "rc=$RC out=$OUT"
fi

new_repo
printf 'let x = 1\n' > "$REPO/Sources/Ok.swift"
printf 'disabled_rules: []\n' > "$REPO/.swiftlint.yml"
stage Sources/Ok.swift .swiftlint.yml
run_pre_commit "$BARE"
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"swiftlint not found"* ]]; then
  pass "staged Swift sources with no swiftlint installed fail with a hint"
else
  fail "missing swiftlint is reported" "rc=$RC out=$OUT"
fi

# --- config not present yet ----------------------------------------------
# The hook checks for .swiftlint.yml before it checks for swiftlint, so a
# clone that has not got a config yet is skipped rather than told to install
# a linter it has nothing to feed.

new_repo
printf 'let x = 1\n' > "$REPO/Sources/Ok.swift"
stage Sources/Ok.swift
run_pre_commit "$BARE"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"config not present yet"* ]]; then
  pass "no .swiftlint.yml skips the Swift half instead of demanding swiftlint"
else
  fail "missing .swiftlint.yml is a skip, not a failure" "rc=$RC out=$OUT"
fi

# --- pre-push -------------------------------------------------------------
# The build the real hook runs is far too slow to run here, so the fixture
# repo gets a scripts/build.sh that only records that it was invoked. Git
# always hands a pre-push hook its ref lines on stdin, so every case below
# supplies some — running with stdin left on a terminal would just hang.

REF_LINES="refs/heads/main $(printf '%040d' 1) refs/heads/main $(printf '%040d' 2)"

# Leaves the hook's combined output in OUT and its status in RC. $1 is the
# PATH to run it under; any further arguments are NAME=VALUE overrides.
run_pre_push() {
  local path="$1"
  shift
  OUT=""
  RC=0
  OUT="$(cd "$REPO" && printf '%s\n' "$REF_LINES" \
         | env PATH="$path" "$@" bash githooks/pre-push 2>&1)" || RC=$?
}

# build.sh <exit-code>: a fake build that records its invocation in
# $WORK/build.invoked and exits with the given status.
fake_build() {
  rm -f "$WORK/build.invoked"
  {
    printf '#!/bin/sh\n'
    printf 'printf "invoked\\n" >> "%s/build.invoked"\n' "$WORK"
    printf 'exit %s\n' "$1"
  } > "$REPO/scripts/build.sh"
  chmod 0755 "$REPO/scripts/build.sh"
}

new_repo
fake_build 1
stub xcodebuild 1
run_pre_push "$STUB:$PATH" SKIP_HOOKS=1
if [ "$RC" -eq 0 ] \
   && [[ "$OUT" == *"skipped (SKIP_HOOKS=1)"* ]] \
   && [ ! -e "$WORK/build.invoked" ]; then
  pass "pre-push SKIP_HOOKS=1 exits 0 without running the build"
else
  fail "pre-push SKIP_HOOKS=1 bypasses the build" "rc=$RC out=$OUT"
fi

new_repo
fake_build 0
stub xcodebuild 0
run_pre_push "$STUB:$PATH"
if [ "$RC" -eq 0 ] && [ -s "$WORK/build.invoked" ]; then
  pass "pre-push runs scripts/build.sh on the default path"
else
  fail "pre-push runs the build by default" "rc=$RC out=$OUT"
fi

new_repo
fake_build 1
stub xcodebuild 0
run_pre_push "$STUB:$PATH"
if [ "$RC" -ne 0 ] && [ -s "$WORK/build.invoked" ]; then
  pass "pre-push fails the push when the build fails"
else
  fail "a failing build fails the push" "rc=$RC out=$OUT"
fi

# The hook must read its ref lines. The 3000 lines below are a few hundred
# KB, well past any pipe buffer, so a hook that exits without draining them
# kills the writer with
# SIGPIPE — which `pipefail` surfaces as the pipeline's status even though
# the hook itself exited 0. That non-zero status *is* the spurious push
# failure this guards against.
new_repo
fake_build 0
stub xcodebuild 0
many_refs() {
  local i=0
  while [ "$i" -lt 3000 ]; do
    printf 'refs/heads/b%s %040d refs/heads/b%s %040d\n' "$i" 1 "$i" 2
    i=$(( i + 1 ))
  done
}
OUT=""
RC=0
OUT="$(cd "$REPO" && many_refs | env PATH="$STUB:$PATH" bash githooks/pre-push 2>&1)" || RC=$?
if [ "$RC" -eq 0 ] && [ -s "$WORK/build.invoked" ]; then
  pass "pre-push drains far more ref lines than a pipe buffer holds"
else
  fail "pre-push drains its stdin" "rc=$RC out=$OUT"
fi

# --- summary --------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
