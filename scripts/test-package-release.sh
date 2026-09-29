#!/usr/bin/env bash
# Pins package-release.sh's guards, run through the script itself: a missing
# or non-MAJOR.MINOR.PATCH version must exit 1 with the usage text, and a
# dirty tree, an existing tag, an empty `## [Unreleased]` or a missing
# CHANGELOG.md must exit 1 — all before CHANGELOG.md is stamped or the build
# starts. Also pins that a release that gets past them stamps CHANGELOG.md
# before building, and restores it byte for byte when the build then fails
# (against a stub build.sh), plus build.sh's matching EPS_MARKETING_VERSION
# check. The guards' finer cases live in scripts/test-release-checks.sh.
# Nothing is built, signed or packaged, so the release checks that need a
# real build (the converter and version-mismatch errors, the DMG, its
# .sha256) are not covered here.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# --- version argument -----------------------------------------------------
# Rejected on the script's first lines, so these can run against the real
# checkout: nothing after the check is reached.

# breaks-if: package-release.sh regains a default version for a missing argument
for args in none empty; do
  RC=0
  if [ "$args" = none ]; then
    OUT="$(bash "$ROOT/scripts/package-release.sh" 2>&1)" || RC=$?
  else
    OUT="$(bash "$ROOT/scripts/package-release.sh" '' 2>&1)" || RC=$?
  fi
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"version argument required"* ]] \
     && [[ "$OUT" == *"usage: bash scripts/package-release.sh <version>"* ]] \
     && [[ "$OUT" != *"Stamp"* ]] && [[ "$OUT" != *"Build app"* ]]; then
    pass "package-release.sh refuses to run without a version ($args)"
  else
    fail "package-release.sh refuses to run without a version ($args)" "rc=$RC out=$OUT"
  fi
done

# breaks-if: package-release.sh stops validating the version before the preflight/stamp
for version in 1.0 v1.0.0 1.0.0-beta 1.0.0-rc1 1.0.0.0 abc; do
  RC=0
  OUT="$(bash "$ROOT/scripts/package-release.sh" "$version" 2>&1)" || RC=$?
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"MAJOR.MINOR.PATCH"* ]] \
     && [[ "$OUT" == *"usage: bash scripts/package-release.sh"* ]] \
     && [[ "$OUT" != *"Stamp"* ]] && [[ "$OUT" != *"Build app"* ]]; then
    pass "package-release.sh rejects version '$version' before building"
  else
    fail "package-release.sh rejects version '$version' before building" "rc=$RC out=$OUT"
  fi
done

# --- preflight, stamp and restore, against a fixture repo -----------------
# package-release.sh derives ROOT from its own location, so each case runs a
# copy inside a throwaway git repo, next to a stub build.sh. The stub records
# that it ran and whether CHANGELOG.md was already stamped, then exits 42 —
# the release stops there, before anything real is built.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-package-release-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CHANGELOG_WITH_ENTRY='# Changelog

## [Unreleased]

- Something new.

## [1.0.0] - 2026-06-26

- First release.
'

REPO=""
SERIAL=0
# new_repo [changelog-content]: omit the argument for a repo without one.
new_repo() {
  SERIAL=$(( SERIAL + 1 ))
  REPO="$WORK/repo-$SERIAL"
  mkdir -p "$REPO/scripts/lib"
  cp "$ROOT/scripts/package-release.sh" "$REPO/scripts/"
  cp "$ROOT/scripts/lib/release-checks.sh" "$REPO/scripts/lib/"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo BUILD-REACHED\n'
    # shellcheck disable=SC2016 # expanded by the stub, not here
    printf 'grep -q "^## \\[$EPS_MARKETING_VERSION\\] - " CHANGELOG.md && touch "%s/saw-stamp"\n' "$WORK"
    printf 'exit 42\n'
  } > "$REPO/scripts/build.sh"
  [ $# -eq 0 ] || printf '%s' "$1" > "$REPO/CHANGELOG.md"
  git init -q "$REPO"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init \
    || { echo "fixture commit failed" >&2; exit 2; }
  rm -f "$WORK/saw-stamp"
}

OUT=""
RC=0
run_release() {
  OUT=""
  RC=0
  OUT="$(bash "$REPO/scripts/package-release.sh" "$1" 2>&1)" || RC=$?
}

# CHANGELOG.md is exactly as committed (or still absent).
changelog_untouched() { git -C "$REPO" diff --quiet -- CHANGELOG.md; }

for version in 1.1.0 12.34.567; do
  new_repo "$CHANGELOG_WITH_ENTRY"
  run_release "$version"
  if [ "$RC" -eq 42 ] && [[ "$OUT" == *"BUILD-REACHED"* ]] && [[ "$OUT" != *"MAJOR.MINOR.PATCH"* ]]; then
    pass "package-release.sh accepts version '$version' and starts the build"
  else
    fail "package-release.sh accepts version '$version' and starts the build" "rc=$RC out=$OUT"
  fi
done

# The last case above: the build saw a stamped CHANGELOG.md, and the failed
# build left it byte-identical to the committed file.
if [ -e "$WORK/saw-stamp" ]; then
  pass "package-release.sh stamps CHANGELOG.md before the build starts"
else
  fail "package-release.sh stamps CHANGELOG.md before the build starts" "out=$OUT"
fi
# breaks-if: package-release.sh's EXIT trap stops restoring CHANGELOG.md on failure
if changelog_untouched && [[ "$OUT" == *"CHANGELOG.md restored"* ]] \
   && [ -z "$(git -C "$REPO" status --porcelain)" ]; then
  pass "a build failure after the stamp leaves CHANGELOG.md byte-identical"
else
  fail "a build failure after the stamp leaves CHANGELOG.md byte-identical" \
    "status=$(git -C "$REPO" status --porcelain) out=$OUT"
fi
# Idempotency: the restored tree passes the preflight again and re-stamps.
rm -f "$WORK/saw-stamp"
run_release 12.34.567
if [ "$RC" -eq 42 ] && [ -e "$WORK/saw-stamp" ] && changelog_untouched; then
  pass "a release re-run after a failed build gets past the preflight again"
else
  fail "a release re-run after a failed build gets past the preflight again" "rc=$RC out=$OUT"
fi

# Each guard: exit 1, its message, no build, CHANGELOG.md untouched.
assert_refused() {
  local name="$1" message="$2"
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"$message"* ]] \
     && [[ "$OUT" != *"BUILD-REACHED"* ]] && [[ "$OUT" != *"Stamp"* ]] \
     && changelog_untouched; then
    pass "$name"
  else
    fail "$name" "rc=$RC out=$OUT"
  fi
}

# breaks-if: package-release.sh stops calling release_preflight (or calls it after the stamp/build)
new_repo "$CHANGELOG_WITH_ENTRY"
printf 'x\n' > "$REPO/stray.txt"
run_release 1.1.0
assert_refused "package-release.sh refuses a dirty working tree before stamping" "working tree is not clean"

# breaks-if: package-release.sh stops calling release_preflight's tag check
new_repo "$CHANGELOG_WITH_ENTRY"
git -C "$REPO" tag v1.1.0
run_release 1.1.0
assert_refused "package-release.sh refuses an existing tag before stamping" "tag v1.1.0 already exists"

# breaks-if: package-release.sh stops calling release_preflight's empty-Unreleased check
new_repo '# Changelog

## [Unreleased]

## [1.0.0] - 2026-06-26

- First release.
'
run_release 1.1.0
assert_refused "package-release.sh refuses an empty Unreleased section before stamping" "is empty"

# breaks-if: package-release.sh stops calling release_preflight's changelog-exists check
new_repo
run_release 1.1.0
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"CHANGELOG.md not found"* ]] \
   && [[ "$OUT" != *"BUILD-REACHED"* ]] && [ ! -e "$REPO/CHANGELOG.md" ]; then
  pass "package-release.sh refuses a missing CHANGELOG.md before building"
else
  fail "package-release.sh refuses a missing CHANGELOG.md before building" "rc=$RC out=$OUT"
fi

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
