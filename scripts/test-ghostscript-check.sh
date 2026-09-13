#!/usr/bin/env bash
# Pins scripts/lib/ghostscript-check.sh against fake `gs` binaries, so the
# installer's idea of a usable Ghostscript keeps behaving the way
# Sources/Shared/GhostscriptLocator.swift does. Plain bash — no bats, no
# other dependency — so it runs on a clean checkout:
#
#   bash scripts/test-ghostscript-check.sh
#
# What it does *not* do is read the Swift side. Every case below is the shell
# library against hand-written fixtures, so a passing run says the library is
# consistent with its own EPS_GS_MINIMUM_MAJOR/MINOR and candidate list — not
# that those still match GhostscriptLocator's `minimumSystemVersion`,
# `systemCandidates` or `versionProbeTimeout`. Parity of the actual values is
# maintained by hand: change one side and you must read the other.
#
# Not wired into scripts/build.sh: that script builds and signs the app and
# runs no checks of its own.
#
# One rule is deliberately not covered: rejecting a `gs` owned by a *third*
# user. Creating a file owned by somebody else needs root, and a test that has
# to be run as root is a test that stops being run. The same code path is
# exercised by the mode checks below (both share _eps_gs_writable_only_by_owner).
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort the
# run. The library itself is exercised under `set -e` in its own case below.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/ghostscript-check.sh disable=SC1091
. "$ROOT/scripts/lib/ghostscript-check.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-gs-test.XXXXXX")"
STDERR_FILE="$WORK/stderr"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# Builds an executable fake `gs` at $WORK/<name>/gs and prints its path.
# $2 is the script body; $3 the mode of the binary, $4 the mode of its parent.
make_fake() {
  local name="$1" body="$2" mode="${3:-0755}" dir_mode="${4:-0755}"
  local dir="$WORK/$name"
  mkdir -p "$dir"
  printf '#!/bin/sh\n%s\n' "$body" > "$dir/gs"
  chmod "$mode" "$dir/gs"
  chmod "$dir_mode" "$dir"
  printf '%s\n' "$dir/gs"
}

# Runs eps_gs_find over $1 (a space-separated candidate list, possibly empty)
# and leaves the result in FIND_OUT / FIND_RC, the rejection reasons in
# $STDERR_FILE.
FIND_OUT=""
FIND_RC=0
run_find() {
  FIND_OUT=""
  FIND_RC=0
  FIND_OUT="$(EPS_GS_CANDIDATES="$1" eps_gs_find 2>"$STDERR_FILE")" || FIND_RC=$?
}

# --- accepted -------------------------------------------------------------

GOOD="$(make_fake good 'echo 10.02.1')"
run_find "$GOOD"
if [ "$FIND_RC" -eq 0 ] && [ "$FIND_OUT" = "$GOOD" ]; then
  pass "accepts an executable gs in a sane directory that prints 10.02.1"
else
  fail "accepts 10.02.1" "rc=$FIND_RC out=$FIND_OUT"
fi

FLOOR="$(make_fake floor 'echo 9.50')"
run_find "$FLOOR"
if [ "$FIND_RC" -eq 0 ] && [ "$FIND_OUT" = "$FLOOR" ]; then
  pass "accepts exactly the 9.50 floor"
else
  fail "accepts 9.50" "rc=$FIND_RC out=$FIND_OUT"
fi

# --- candidate order ------------------------------------------------------

run_find "$GOOD $FLOOR"
if [ "$FIND_OUT" = "$GOOD" ]; then
  pass "first acceptable candidate wins"
else
  fail "first acceptable candidate wins" "expected $GOOD, got $FIND_OUT"
fi

run_find "$FLOOR $GOOD"
if [ "$FIND_OUT" = "$FLOOR" ]; then
  pass "candidate order is the list order, not a preferred path"
else
  fail "candidate order is the list order" "expected $FLOOR, got $FIND_OUT"
fi

run_find "$WORK/does-not-exist/gs $GOOD"
if [ "$FIND_RC" -eq 0 ] && [ "$FIND_OUT" = "$GOOD" ] && [ ! -s "$STDERR_FILE" ]; then
  pass "a missing candidate is skipped without a complaint"
else
  fail "a missing candidate is skipped silently" \
    "rc=$FIND_RC out=$FIND_OUT reasons=$(cat "$STDERR_FILE")"
fi

# --- version parsing ------------------------------------------------------
# Mirrors GhostscriptLocator.versionString(_:meetsMinimum:): "9.5" is minor 5
# and therefore below 9.50, and anything that does not read as
# <major>.<minor> is refused rather than guessed at.

for spec in "9.49:below the floor" \
            "9.5:not 9.50 — the minor field counts as printed" \
            "abc:unparseable" \
            "10:a bare major with no minor"; do
  version="${spec%%:*}"
  why="${spec#*:}"
  fake="$(make_fake "v${version//[^0-9a-z]/_}" "echo $version")"
  run_find "$fake"
  if [ "$FIND_RC" -ne 0 ] && [ -z "$FIND_OUT" ] && [ -s "$STDERR_FILE" ]; then
    pass "rejects \"$version\" ($why) and says why"
  else
    fail "rejects \"$version\"" "rc=$FIND_RC out=$FIND_OUT reasons=$(cat "$STDERR_FILE")"
  fi
done

# --- ownership / permissions ---------------------------------------------

LOOSE_BIN="$(make_fake loose-bin 'echo 10.02.1' 0777)"
run_find "$LOOSE_BIN"
if [ "$FIND_RC" -ne 0 ] && [ -z "$FIND_OUT" ]; then
  pass "rejects a group/world-writable binary"
else
  fail "rejects a 0777 binary" "rc=$FIND_RC out=$FIND_OUT"
fi

LOOSE_DIR="$(make_fake loose-dir 'echo 10.02.1' 0755 0777)"
run_find "$LOOSE_DIR"
if [ "$FIND_RC" -ne 0 ] && [ -z "$FIND_OUT" ]; then
  pass "rejects a binary whose parent directory is group/world-writable"
else
  fail "rejects a 0777 parent directory" "rc=$FIND_RC out=$FIND_OUT"
fi

# The symlink itself is harmless; what matters is that vetting follows it to
# the file that would actually be executed.
TARGET="$(make_fake symlink-target 'echo 10.02.1' 0777)"
mkdir -p "$WORK/symlink"
ln -s "$TARGET" "$WORK/symlink/gs"
run_find "$WORK/symlink/gs"
if [ "$FIND_RC" -ne 0 ] && [ -z "$FIND_OUT" ]; then
  pass "rejects a symlink to a world-writable binary (vetting resolves it)"
else
  fail "rejects a symlink to a 0777 target" "rc=$FIND_RC out=$FIND_OUT"
fi

# --- probe bound ----------------------------------------------------------

PIDFILE="$WORK/hang.pid"
# `exec` so the pid the fake records is the pid the probe will have to kill:
# if the library killed only a wrapper shell, the sleeper would survive.
HANG="$(make_fake hang "echo \$\$ > '$PIDFILE'
exec /bin/sleep 30")"
START="$SECONDS"
EPS_GS_PROBE_TIMEOUT=1
run_find "$HANG"
unset EPS_GS_PROBE_TIMEOUT
ELAPSED=$(( SECONDS - START ))
if [ "$FIND_RC" -ne 0 ] && [ -z "$FIND_OUT" ] && [ "$ELAPSED" -le 5 ]; then
  pass "rejects a gs that never answers --version, within the probe timeout (${ELAPSED}s)"
else
  fail "bounds a hanging gs" "rc=$FIND_RC out=$FIND_OUT elapsed=${ELAPSED}s"
fi
if [ ! -s "$PIDFILE" ]; then
  fail "the hanging gs is not left running" "the fake never recorded its pid"
elif kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  fail "the hanging gs is not left running" "pid $(cat "$PIDFILE") is still alive"
  kill -KILL "$(cat "$PIDFILE")" 2>/dev/null
else
  pass "the hanging gs is killed, not orphaned"
fi

# --- exit status ----------------------------------------------------------

BAD_STATUS="$(make_fake bad-status 'echo 10.02.1
exit 3')"
run_find "$BAD_STATUS"
if [ "$FIND_RC" -ne 0 ] && [ -z "$FIND_OUT" ]; then
  pass "rejects a gs that exits non-zero even with a valid version line"
else
  fail "rejects a non-zero exit status" "rc=$FIND_RC out=$FIND_OUT"
fi

# --- nothing found --------------------------------------------------------

run_find ""
if [ "$FIND_RC" -eq 1 ] && [ -z "$FIND_OUT" ] && [ ! -s "$STDERR_FILE" ]; then
  pass "an empty candidate list returns 1 and prints nothing"
else
  fail "empty candidate list" "rc=$FIND_RC out=$FIND_OUT reasons=$(cat "$STDERR_FILE")"
fi

# --- sourceable from a strict script -------------------------------------
# install.sh runs under `set -euo pipefail`; a stray non-zero status anywhere
# in the library would abort the install instead of reporting a verdict.

if ( set -euo pipefail
     . "$ROOT/scripts/lib/ghostscript-check.sh"
     EPS_GS_CANDIDATES="$WORK/does-not-exist/gs $GOOD" eps_gs_find >/dev/null
     EPS_GS_CANDIDATES="" eps_gs_find >/dev/null 2>&1 || true ) 2>/dev/null; then
  pass "survives being sourced into a set -euo pipefail script"
else
  fail "survives set -euo pipefail" "the library aborted a strict shell"
fi

# --- summary --------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
