#!/usr/bin/env bash
# Pins package-release.sh's version validation: anything that is not
# MAJOR.MINOR.PATCH must exit 1 with the usage text before any build starts.
# Also pins that valid versions get past that guard (against a stub build.sh),
# and build.sh's matching EPS_MARKETING_VERSION check. Every rejection happens
# on the first lines of its script, so nothing is built, signed or packaged.
# The release checks that need a real build (the converter and
# version-mismatch errors) are not covered.
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

# Valid versions must get past the guard. package-release.sh derives ROOT
# from its own location, so run a copy next to a stub build.sh that prints a
# sentinel and exits non-zero — the release stops there, before anything real
# is built.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts"
cp "$ROOT/scripts/package-release.sh" "$TMP/scripts/"
printf '#!/usr/bin/env bash\necho BUILD-REACHED\nexit 42\n' > "$TMP/scripts/build.sh"
for version in 1.0.0 12.34.567; do
  RC=0
  OUT="$(bash "$TMP/scripts/package-release.sh" "$version" 2>&1)" || RC=$?
  if [ "$RC" -eq 42 ] && [[ "$OUT" == *"BUILD-REACHED"* ]] && [[ "$OUT" != *"MAJOR.MINOR.PATCH"* ]]; then
    pass "package-release.sh accepts version '$version' and starts the build"
  else
    fail "package-release.sh accepts version '$version' and starts the build" "rc=$RC out=$OUT"
  fi
done

# build.sh validates EPS_MARKETING_VERSION before its xcodegen/Xcode checks,
# so these cases exit before anything is generated or built, toolchain or not.
for version in 1.0 v1.0.0 1.0.0-beta 1.0.0.0 abc; do
  RC=0
  OUT="$(EPS_MARKETING_VERSION="$version" bash "$ROOT/scripts/build.sh" 2>&1)" || RC=$?
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"MAJOR.MINOR.PATCH"* ]] \
     && [[ "$OUT" != *"Generating Xcode project"* ]]; then
    pass "build.sh rejects EPS_MARKETING_VERSION '$version' before generating the project"
  else
    fail "build.sh rejects EPS_MARKETING_VERSION '$version' before generating the project" "rc=$RC out=$OUT"
  fi
done

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
