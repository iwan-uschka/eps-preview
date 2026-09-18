#!/usr/bin/env bash
# Pins scripts/lib/ghostscript-manifest.sh against fake manifests and fake
# bundled-library lists, so the release gate in
# scripts/bundle-ghostscript.sh keeps distinguishing "first run", "closure
# unchanged" and "closure changed" without needing a Homebrew machine and a
# real bundling run to find out. Plain bash — no bats, no other dependency:
#
#   bash scripts/test-ghostscript-manifest.sh
#
# What it does *not* cover is bundle-ghostscript.sh's own handling of the three
# verdicts (recording a first manifest, the
# ALLOW_DEPENDENCY_MANIFEST_MISMATCH override, the wording of the error): the
# library decides, the caller reacts, and only the deciding half is testable
# without running a real bundle.
#
# Not wired into scripts/build.sh: that script builds and signs the app and
# runs no checks of its own.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort the
# run. The library itself is exercised under `set -e` in its own case below.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/ghostscript-manifest.sh disable=SC1091
. "$ROOT/scripts/lib/ghostscript-manifest.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-gs-manifest-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# Two libraries and their hashes, in the shape bundle-ghostscript.sh strips out
# of GHOSTSCRIPT_PROVENANCE.txt: "<basename> <sha256>".
RECORDED="libfreetype.6.dylib aaaa1111
libtiff.6.dylib bbbb2222"

# write_manifest <text>: a manifest file at $MANIFEST holding <text>.
MANIFEST="$WORK/manifest.txt"
write_manifest() { printf '%s\n' "$1" > "$MANIFEST"; }

# Leaves the printed diff in CHECK_OUT and the verdict in CHECK_RC. $1 is the
# bundled library list; the manifest is whatever $MANIFEST currently is.
CHECK_OUT=""
CHECK_RC=0
run_check() {
  CHECK_OUT=""
  CHECK_RC=0
  CHECK_OUT="$(printf '%s\n' "$1" | eps_manifest_check "$MANIFEST")" || CHECK_RC=$?
}

# --- no manifest yet ------------------------------------------------------

rm -f "$MANIFEST"
run_check "$RECORDED"
if [ "$CHECK_RC" -eq 2 ] && [ -z "$CHECK_OUT" ]; then
  pass "a missing manifest is its own verdict (2), not a mismatch"
else
  fail "missing manifest returns 2" "rc=$CHECK_RC out=$CHECK_OUT"
fi

# The library must not write the manifest itself — recording it is the
# caller's job, and a library that wrote it would turn every mismatch into a
# silent re-pin.
if [ ! -e "$MANIFEST" ]; then
  pass "the check never creates the manifest it found missing"
else
  fail "the check does not write the manifest" "$MANIFEST was created"
fi

# --- unchanged closure ----------------------------------------------------

write_manifest "$RECORDED"
run_check "$RECORDED"
if [ "$CHECK_RC" -eq 0 ] && [ -z "$CHECK_OUT" ]; then
  pass "an identical closure passes silently"
else
  fail "identical closure passes" "rc=$CHECK_RC out=$CHECK_OUT"
fi

# The bundled list comes out of a `lib/*.dylib` glob, so its order follows the
# builder's LC_COLLATE. A contributor with a different locale must not see a
# pure reordering reported as a changed closure.
write_manifest "$RECORDED"
run_check "libtiff.6.dylib bbbb2222
libfreetype.6.dylib aaaa1111"
if [ "$CHECK_RC" -eq 0 ] && [ -z "$CHECK_OUT" ]; then
  pass "the same libraries in a different order still pass"
else
  fail "line order does not affect the verdict" "rc=$CHECK_RC out=$CHECK_OUT"
fi

# --- changed closure ------------------------------------------------------

write_manifest "$RECORDED"
run_check "libfreetype.6.dylib aaaa1111
libtiff.6.dylib cccc3333"
if [ "$CHECK_RC" -eq 1 ] \
   && [[ "$CHECK_OUT" == *"-libtiff.6.dylib bbbb2222"* ]] \
   && [[ "$CHECK_OUT" == *"+libtiff.6.dylib cccc3333"* ]]; then
  pass "a rebuilt library with a new hash is reported as a change"
else
  fail "a changed hash is reported" "rc=$CHECK_RC out=$CHECK_OUT"
fi

write_manifest "$RECORDED"
run_check "libfreetype.6.dylib aaaa1111
libjpeg.8.dylib dddd4444
libtiff.6.dylib bbbb2222"
if [ "$CHECK_RC" -eq 1 ] && [[ "$CHECK_OUT" == *"+libjpeg.8.dylib dddd4444"* ]]; then
  pass "a newly pulled-in library is reported as a change"
else
  fail "an added library is reported" "rc=$CHECK_RC out=$CHECK_OUT"
fi

write_manifest "$RECORDED"
run_check "libfreetype.6.dylib aaaa1111"
if [ "$CHECK_RC" -eq 1 ] && [[ "$CHECK_OUT" == *"-libtiff.6.dylib bbbb2222"* ]]; then
  pass "a library that dropped out of the closure is reported as a change"
else
  fail "a removed library is reported" "rc=$CHECK_RC out=$CHECK_OUT"
fi

# --- the diff is ready to be indented into an error -----------------------
# bundle-ghostscript.sh pipes the output straight through `sed 's/^/ /'`, so
# the two `---`/`+++` filename lines (which name a temp file and would leak a
# meaningless path into the error) must already be gone.

write_manifest "$RECORDED"
run_check "libfreetype.6.dylib aaaa1111
libtiff.6.dylib cccc3333"
if [[ "$CHECK_OUT" != *"--- "* ]] && [[ "$CHECK_OUT" != *"+++ "* ]]; then
  pass "the reported diff carries no ---/+++ filename header"
else
  fail "the diff header is stripped" "out=$CHECK_OUT"
fi

# --- empty sides ----------------------------------------------------------
# A gs that suddenly links nothing, or an empty committed manifest, must not
# read as "unchanged" just because one side is blank.

write_manifest ""
run_check "$RECORDED"
if [ "$CHECK_RC" -eq 1 ]; then
  pass "an empty manifest against a real closure is a mismatch"
else
  fail "empty manifest vs real closure" "rc=$CHECK_RC out=$CHECK_OUT"
fi

write_manifest "$RECORDED"
CHECK_OUT=""
CHECK_RC=0
CHECK_OUT="$(printf '' | eps_manifest_check "$MANIFEST")" || CHECK_RC=$?
if [ "$CHECK_RC" -eq 1 ]; then
  pass "an empty closure against a real manifest is a mismatch"
else
  fail "empty closure vs real manifest" "rc=$CHECK_RC out=$CHECK_OUT"
fi

# Both sides empty is the degenerate "nothing to compare" case, and the blank
# line an unguarded `printf '%s\n' ""` would emit must not fake a difference.
: > "$MANIFEST"
CHECK_OUT=""
CHECK_RC=0
CHECK_OUT="$(printf '' | eps_manifest_check "$MANIFEST")" || CHECK_RC=$?
if [ "$CHECK_RC" -eq 0 ] && [ -z "$CHECK_OUT" ]; then
  pass "an empty manifest and an empty closure agree"
else
  fail "empty manifest vs empty closure" "rc=$CHECK_RC out=$CHECK_OUT"
fi

# --- sourceable from a strict script -------------------------------------
# bundle-ghostscript.sh runs under `set -euo pipefail`; a stray non-zero
# status anywhere in the library would abort a release build instead of
# reporting a verdict.

write_manifest "$RECORDED"
if ( set -euo pipefail
     # The include guard is already set in this shell, so drop it: otherwise
     # the source below would return immediately and prove nothing.
     unset _EPS_GS_MANIFEST_SH
     . "$ROOT/scripts/lib/ghostscript-manifest.sh"
     rc=0
     printf '%s\n' "$RECORDED" | eps_manifest_check "$MANIFEST" >/dev/null || rc=$?
     [ "$rc" -eq 0 ] ) 2>/dev/null; then
  pass "survives being sourced into a set -euo pipefail script"
else
  fail "survives set -euo pipefail" "the library aborted a strict shell"
fi

# --- summary --------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
