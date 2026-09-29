#!/usr/bin/env bash
# Pins scripts/lib/replace-bundle.sh — install.sh's swap of the old
# /Applications bundle for the verified staging copy — against throwaway
# directories. The undeletable-bundle case stands in for a root-owned
# /Applications/EPSPreview.app left by an earlier sudo run: a subdirectory
# without write permission makes `rm -rf` fail the same way (Permission
# denied, part of the tree already gone), without needing root to set up.
# That case is skipped when run as root, which ignores the permission bits.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-replace-bundle-test.XXXXXX")"
# Give write permission back first, or the cleanup itself fails.
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM
# shellcheck source=lib/replace-bundle.sh disable=SC1091
. "$ROOT/scripts/lib/replace-bundle.sh"

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# make_bundle <path> <marker>: a minimal fake .app tree.
make_bundle() {
  mkdir -p "$1/Contents/MacOS"
  printf '%s\n' "$2" > "$1/Contents/marker"
}

OUT=""
RC=0

# --- happy path: an existing bundle is replaced, not merged ---------------
DEST="$WORK/ok/EPSPreview.app"
make_bundle "$DEST" old
printf 'stale\n' > "$DEST/Contents/only-in-old"
make_bundle "$DEST.installing" new
OUT="$(replace_bundle "$DEST.installing" "$DEST" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$DEST/Contents/marker")" = new ] \
   && [ ! -e "$DEST/Contents/only-in-old" ] && [ ! -e "$DEST.installing" ]; then
  pass "replace_bundle swaps the staged bundle in and drops the old one entirely"
else
  fail "replace_bundle happy path" "rc=$RC out=$OUT"
fi

# --- first install: no existing bundle ------------------------------------
DEST="$WORK/fresh/EPSPreview.app"
mkdir -p "$WORK/fresh"
make_bundle "$DEST.installing" new
OUT="$(replace_bundle "$DEST.installing" "$DEST" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ] && [ "$(cat "$DEST/Contents/marker")" = new ]; then
  pass "replace_bundle installs when there is no previous bundle"
else
  fail "replace_bundle first install" "rc=$RC out=$OUT"
fi

# --- an undeletable previous bundle ---------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP  undeletable-bundle cases (root ignores permission bits)\n'
else
  DEST="$WORK/locked/EPSPreview.app"
  make_bundle "$DEST" old
  printf 'x\n' > "$DEST/Contents/MacOS/EPSPreview"
  chmod 0555 "$DEST/Contents/MacOS"
  make_bundle "$DEST.installing" new
  # breaks-if: replace_bundle ignores a failing `rm -rf "$dest"`
  OUT="$(replace_bundle "$DEST.installing" "$DEST" 2>&1)"; RC=$?
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"could not remove the existing $DEST"* ]] \
     && [[ "$OUT" == *"sudo rm -rf $DEST"* ]] && [[ "$OUT" == *"without sudo"* ]]; then
    pass "replace_bundle fails with the one-time sudo rm instruction when the old bundle won't go"
  else
    fail "replace_bundle fails on an undeletable old bundle" "rc=$RC out=$OUT"
  fi
  # A `mv` onto the surviving directory would have nested the new bundle
  # inside the old one — the half-installed state this guard exists for.
  if [ ! -e "$DEST/EPSPreview.app.installing" ] && [ ! -e "$DEST/Contents/marker.new" ] \
     && [ -e "$DEST/Contents/MacOS/EPSPreview" ]; then
    pass "replace_bundle does not move the staged bundle into the surviving old one"
  else
    fail "replace_bundle does not move the staged bundle into the surviving old one" \
      "$(find "$DEST" | sed "s|$WORK/||" | tr '\n' ' ')"
  fi
  # breaks-if: replace_bundle's failure path stops removing the staging copy
  if [ ! -e "$DEST.installing" ]; then
    pass "replace_bundle removes the staging copy on failure"
  else
    fail "replace_bundle removes the staging copy on failure" "$DEST.installing still exists"
  fi
fi

# --- install.sh actually uses it ------------------------------------------
# breaks-if: install.sh goes back to a bare `rm -rf "$DEST"; mv` instead of replace_bundle
# shellcheck disable=SC2016 # literal $ in the patterns
if grep -Eq '^replace_bundle "\$TMP_DEST" "\$DEST" \|\| exit 1$' "$ROOT/scripts/install.sh" \
   && ! grep -Eq '^rm -rf "\$DEST"$' "$ROOT/scripts/install.sh"; then
  pass "install.sh swaps the bundle through replace_bundle and exits on its failure"
else
  fail "install.sh swaps the bundle through replace_bundle" "call site not found"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
