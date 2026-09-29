#!/usr/bin/env bash
# Pins scripts/lib/release-checks.sh — the guards package-release.sh runs
# before building, the CHANGELOG.md stamp/restore it wraps the build in, the
# checksum file it writes and the next-step commands it prints — by calling
# each helper directly against throwaway git repos and files. Plain bash plus
# git; nothing is built. scripts/test-package-release.sh covers the same
# guards through package-release.sh itself.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-release-checks-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# shellcheck source=lib/release-checks.sh disable=SC1091
. "$ROOT/scripts/lib/release-checks.sh"

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# Runs "$@" in a subshell from $REPO, leaving combined output in OUT and the
# status in RC.
OUT=""
RC=0
run_in_repo() {
  OUT=""
  RC=0
  OUT="$(cd "$REPO" && "$@" 2>&1)" || RC=$?
}

CHANGELOG_WITH_ENTRY='# Changelog

## [Unreleased]

### Fixed

- Something.

## [1.0.0] - 2026-06-26

- First release.
'

# A fresh committed repo per case whose CHANGELOG.md is $1.
REPO=""
SERIAL=0
new_repo() {
  SERIAL=$(( SERIAL + 1 ))
  REPO="$WORK/repo-$SERIAL"
  mkdir -p "$REPO"
  git init -q "$REPO"
  printf '%s' "$1" > "$REPO/CHANGELOG.md"
  git -C "$REPO" add CHANGELOG.md
  # A global gpgsign or commit hook must not leave the fixture without a
  # commit, which would make later dirty-tree and tag cases fail misleadingly.
  git -C "$REPO" -c user.name=t -c user.email=t@example.invalid \
    -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm init \
    || { echo "fixture commit failed" >&2; exit 2; }
}

# --- release_version_valid: boundaries ------------------------------------

for version in 0.0.0 1.0.0 12.34.567; do
  if release_version_valid "$version" >/dev/null; then
    pass "release_version_valid accepts '$version'"
  else
    fail "release_version_valid accepts '$version'" "rejected"
  fi
done
# breaks-if: the version regex loses its ^/$ anchors or allows a prefix/suffix
for version in '' 1.0 1.0.0.0 v1.0.0 1.0.0-rc1 ' 1.0.0' '1.0.0 ' 1.a.0; do
  OUT="$(release_version_valid "$version")"; RC=$?
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"MAJOR.MINOR.PATCH (got '$version')"* ]]; then
    pass "release_version_valid rejects '$version'"
  else
    fail "release_version_valid rejects '$version'" "rc=$RC out=$OUT"
  fi
done

# --- release_preflight ----------------------------------------------------

new_repo "$CHANGELOG_WITH_ENTRY"
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "release_preflight passes a clean repo with a new version and an Unreleased entry"
else
  fail "release_preflight passes the happy path" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight drops the CHANGELOG.md existence check
new_repo "$CHANGELOG_WITH_ENTRY"
run_in_repo release_preflight 1.1.0 MISSING.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"MISSING.md not found"* ]]; then
  pass "release_preflight refuses a missing changelog"
else
  fail "release_preflight refuses a missing changelog" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight drops the '## [Unreleased]' heading check
new_repo '# Changelog

## [1.0.0] - 2026-06-26

- First release.
'
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"no '## [Unreleased]' heading"* ]]; then
  pass "release_preflight refuses a changelog without an Unreleased heading"
else
  fail "release_preflight refuses a changelog without an Unreleased heading" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight stops checking `git status --porcelain`
new_repo "$CHANGELOG_WITH_ENTRY"
printf 'x\n' > "$REPO/untracked.txt"
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"working tree is not clean"* ]] && [[ "$OUT" == *"untracked.txt"* ]]; then
  pass "release_preflight refuses an untracked file and names it"
else
  fail "release_preflight refuses an untracked file" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight only looks at untracked files, not modified ones
new_repo "$CHANGELOG_WITH_ENTRY"
printf -- '- Another.\n' >> "$REPO/CHANGELOG.md"
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"working tree is not clean"* ]] && [[ "$OUT" == *"CHANGELOG.md"* ]]; then
  pass "release_preflight refuses a modified tracked file"
else
  fail "release_preflight refuses a modified tracked file" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight treats a failing `git status` (not a repo) as clean
REPO="$WORK/not-a-repo"
mkdir -p "$REPO"
printf '%s' "$CHANGELOG_WITH_ENTRY" > "$REPO/CHANGELOG.md"
run_in_repo env GIT_CEILING_DIRECTORIES="$WORK" bash -c \
  ". '$ROOT/scripts/lib/release-checks.sh'; release_preflight 1.1.0 CHANGELOG.md"
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"git status failed"* ]]; then
  pass "release_preflight refuses to run outside a git working tree"
else
  fail "release_preflight refuses to run outside a git working tree" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight drops the existing-tag check
new_repo "$CHANGELOG_WITH_ENTRY"
git -C "$REPO" tag v1.1.0
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"tag v1.1.0 already exists"* ]]; then
  pass "release_preflight refuses a version whose tag exists"
else
  fail "release_preflight refuses a version whose tag exists" "rc=$RC out=$OUT"
fi
# The tag lookup is exact: an existing v1.1.10 must not block 1.1.1, the case
# a glob or prefix match would get wrong.
# breaks-if: release_preflight looks tags up by prefix or glob instead of exact name
git -C "$REPO" tag v1.1.10
run_in_repo release_preflight 1.1.1 CHANGELOG.md
if [ "$RC" -eq 0 ]; then
  pass "release_preflight's tag check matches the exact tag only"
else
  fail "release_preflight's tag check matches the exact tag only" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight drops the existing-changelog-section check
new_repo "$CHANGELOG_WITH_ENTRY"
run_in_repo release_preflight 1.0.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"already has a '## [1.0.0]' section"* ]]; then
  pass "release_preflight refuses a version whose changelog section exists without a tag"
else
  fail "release_preflight refuses a version whose changelog section exists without a tag" "rc=$RC out=$OUT"
fi

# breaks-if: the existing-section check matches `## [<version>]` anywhere in a line, or treats the dots as wildcards
new_repo '# Changelog

## [Unreleased]

- Mentions `## [1.1.0]` mid-line, which is not a heading.

## [1x1x0] - 2026-01-01

- Decoy.
'
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 0 ]; then
  pass "release_preflight's changelog-section check matches only a line-start heading with literal dots"
else
  fail "release_preflight's changelog-section check matches only a line-start heading with literal dots" "rc=$RC out=$OUT"
fi

# breaks-if: release_preflight drops the empty-Unreleased check
new_repo '# Changelog

## [Unreleased]

## [1.0.0] - 2026-06-26

- First release.
'
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"section of CHANGELOG.md is empty"* ]]; then
  pass "release_preflight refuses a blank Unreleased section"
else
  fail "release_preflight refuses a blank Unreleased section" "rc=$RC out=$OUT"
fi

# breaks-if: the emptiness check counts a bare `### Added` subheading as content
new_repo '# Changelog

## [Unreleased]

### Added

## [1.0.0] - 2026-06-26

- First release.
'
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"is empty"* ]]; then
  pass "release_preflight refuses an Unreleased section with only an empty subheading"
else
  fail "release_preflight refuses an Unreleased section with only an empty subheading" "rc=$RC out=$OUT"
fi

# breaks-if: the Unreleased body runs past the next `## [` heading
new_repo '# Changelog

## [Unreleased]

## [1.0.0] - 2026-06-26

- Only an older entry has content.
'
run_in_repo release_preflight 1.1.0 CHANGELOG.md
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"is empty"* ]]; then
  pass "release_preflight does not count an older section's entries as Unreleased"
else
  fail "release_preflight does not count an older section's entries as Unreleased" "rc=$RC out=$OUT"
fi

# Unreleased as the last section (no older version below it) still counts.
new_repo '# Changelog

## [Unreleased]

- First entry ever.
'
run_in_repo release_preflight 0.1.0 CHANGELOG.md
if [ "$RC" -eq 0 ]; then
  pass "release_preflight accepts an Unreleased section that runs to end of file"
else
  fail "release_preflight accepts an Unreleased section that runs to end of file" "rc=$RC out=$OUT"
fi

# --- release_stamp_changelog / release_changelog_section -----------------

F="$WORK/stamp.md"
printf '%s' "$CHANGELOG_WITH_ENTRY" > "$F"
release_stamp_changelog 1.1.0 2026-09-29 "$F"
EXPECTED='# Changelog

## [Unreleased]

## [1.1.0] - 2026-09-29

### Fixed

- Something.

## [1.0.0] - 2026-06-26

- First release.
'
if cmp -s "$F" <(printf '%s' "$EXPECTED"); then
  pass "release_stamp_changelog opens a fresh Unreleased above the new version heading"
else
  fail "release_stamp_changelog output" "$(diff <(printf '%s' "$EXPECTED") "$F")"
fi

# The stamped file must pass straight back through the empty-Unreleased
# guard as empty — the next release starts from nothing.
# breaks-if: release_stamp_changelog leaves entries under the fresh '## [Unreleased]' heading
if ! release_unreleased_body "$F" | grep -Eqv '^[[:space:]]*(###.*)?$'; then
  pass "a freshly stamped changelog has an empty Unreleased section"
else
  fail "a freshly stamped changelog has an empty Unreleased section" "$(release_unreleased_body "$F")"
fi

NOTES="$(release_changelog_section 1.1.0 "$F")"
if [[ "$NOTES" == *"- Something."* ]] && [[ "$NOTES" != *"First release"* ]] \
   && [[ "$NOTES" != *"## [1.1.0]"* ]]; then
  pass "release_changelog_section extracts exactly the new version's entries"
else
  fail "release_changelog_section extraction" "$NOTES"
fi

# breaks-if: release_changelog_section matches the version as a regex (1.1.0 ≈ 1x1x0)
printf '## [1x1x0] - 2026-01-01\n\n- Decoy.\n\n## [1.1.0] - 2026-09-29\n\n- Real.\n' > "$WORK/decoy.md"
NOTES="$(release_changelog_section 1.1.0 "$WORK/decoy.md")"
if [[ "$NOTES" == *"- Real."* ]] && [[ "$NOTES" != *"Decoy"* ]]; then
  pass "release_changelog_section treats the version's dots literally"
else
  fail "release_changelog_section treats the version's dots literally" "$NOTES"
fi

# breaks-if: release_changelog_section matches a heading prefix (1.1.0 inside 1.1.0.x / 11.1.0)
printf '## [11.1.0] - 2026-01-01\n\n- Other.\n' > "$WORK/prefix.md"
NOTES="$(release_changelog_section 1.1.0 "$WORK/prefix.md")"
if [ -z "$NOTES" ]; then
  pass "release_changelog_section does not match a different version sharing a suffix"
else
  fail "release_changelog_section does not match a different version sharing a suffix" "$NOTES"
fi

# breaks-if: release_stamp_changelog rewrites every Unreleased heading, not just the first
printf '## [Unreleased]\n\n- A.\n\n## [Unreleased]\n' > "$F"
release_stamp_changelog 2.0.0 2026-09-29 "$F"
if [ "$(grep -c '^## \[2.0.0\]' "$F")" -eq 1 ] && [ "$(grep -c '^## \[Unreleased\]' "$F")" -eq 2 ]; then
  pass "release_stamp_changelog stamps only the first Unreleased heading"
else
  fail "release_stamp_changelog stamps only the first Unreleased heading" "$(cat "$F")"
fi

# breaks-if: release_stamp_changelog ignores awk/cat failing (else branch removed)
OUT="$(release_stamp_changelog 1.1.0 2026-09-29 "$WORK/no-such.md" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"could not stamp $WORK/no-such.md"* ]] && [ ! -e "$WORK/no-such.md" ]; then
  pass "release_stamp_changelog fails for a missing changelog without creating it"
else
  fail "release_stamp_changelog fails for a missing changelog without creating it" "rc=$RC out=$OUT"
fi

# --- release_restore_changelog: the failed-run idempotency ----------------
# Mirrors package-release.sh's sequence (back up, stamp, fail, EXIT trap
# restores) in a subshell with its own EXIT trap, then checks the file is
# byte-identical and stamps the same way on a second attempt.
F="$WORK/restore.md"
printf '%s' "$CHANGELOG_WITH_ENTRY" > "$F"
cp "$F" "$WORK/restore.orig"
# breaks-if: package-release.sh's EXIT trap stops restoring CHANGELOG.md after a failed build
(
  BACKUP="$(mktemp)"
  cp "$F" "$BACKUP"
  trap 'release_restore_changelog "$BACKUP" "$F"; rm -f "$BACKUP"' EXIT
  release_stamp_changelog 1.1.0 2026-09-29 "$F"
  grep -q '^## \[1.1.0\]' "$F" || exit 3   # the stamp really happened
  exit 42                                   # the "build" fails
)
RC=$?
if [ "$RC" -eq 42 ] && cmp -s "$F" "$WORK/restore.orig"; then
  pass "a failure after the stamp restores the changelog byte for byte"
else
  fail "a failure after the stamp restores the changelog byte for byte" \
    "rc=$RC diff=$(diff "$WORK/restore.orig" "$F")"
fi
release_stamp_changelog 1.1.0 2026-09-29 "$F"
if [ "$(grep -c '^## \[1.1.0\]' "$F")" -eq 1 ]; then
  pass "a retry after a restored failure stamps the version exactly once"
else
  fail "a retry after a restored failure stamps the version exactly once" "$(cat "$F")"
fi

# breaks-if: release_restore_changelog ignores a failed copy-back
OUT="$(release_restore_changelog "$WORK/no-such-backup" "$WORK/restore.md" 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"restore it by hand"* ]]; then
  pass "release_restore_changelog reports a failed restore"
else
  fail "release_restore_changelog reports a failed restore" "rc=$RC out=$OUT"
fi

# --- release_write_checksum ----------------------------------------------

mkdir -p "$WORK/dist"
printf 'not really a dmg\n' > "$WORK/dist/EPSPreview-1.1.0.dmg"
OUT="$(cd "$WORK" && release_write_checksum dist/EPSPreview-1.1.0.dmg)"; RC=$?
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"  EPSPreview-1.1.0.dmg" ]] \
   && [ "$(cat "$WORK/dist/EPSPreview-1.1.0.dmg.sha256")" = "$OUT" ] \
   && (cd "$WORK/dist" && shasum -a 256 -c EPSPreview-1.1.0.dmg.sha256 >/dev/null); then
  pass "release_write_checksum writes a bare-name .sha256 that shasum -c accepts from dist/"
else
  fail "release_write_checksum" "rc=$RC out=$OUT"
fi
# breaks-if: the .sha256 names the image by a path relative to the repo root
printf 'tampered\n' > "$WORK/dist/EPSPreview-1.1.0.dmg"
if ! (cd "$WORK/dist" && shasum -a 256 -c EPSPreview-1.1.0.dmg.sha256 >/dev/null 2>&1); then
  pass "the written .sha256 detects a modified image"
else
  fail "the written .sha256 detects a modified image" "shasum -c still passed"
fi
# breaks-if: release_write_checksum ignores shasum failing
OUT="$(cd "$WORK" && release_write_checksum dist/missing.dmg 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"could not write dist/missing.dmg.sha256"* ]]; then
  pass "release_write_checksum fails for a missing image"
else
  fail "release_write_checksum fails for a missing image" "rc=$RC out=$OUT"
fi

# --- release_print_next_steps --------------------------------------------
# Runs the printed `gh release create` line for real against a stub `gh`
# that records its arguments and the notes file's content, so the pasted
# command — process substitution and awk quoting included — is what gets
# tested, not a look-alike.
new_repo "$CHANGELOG_WITH_ENTRY"
release_stamp_changelog 1.1.0 2026-09-29 "$REPO/CHANGELOG.md"
OUT="$(release_print_next_steps 1.1.0 dist/EPSPreview-1.1.0.dmg CHANGELOG.md NOTICE.md)"
if [[ "$OUT" == *"git add CHANGELOG.md NOTICE.md && git commit -m 'Release 1.1.0' && git push"* ]] \
   && [[ "$OUT" == *"not notarized"* ]] && [[ "$OUT" == *"Privacy & Security"* ]] \
   && [[ "$OUT" != *"git tag"* ]]; then
  pass "release_print_next_steps prints the commit/push line and the notarization note"
else
  fail "release_print_next_steps commit/push line" "$OUT"
fi
GH_LINE="$(printf '%s\n' "$OUT" | grep '^  gh release create ')"
mkdir -p "$WORK/gh-stub"
cat > "$WORK/gh-stub/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$WORK/gh.args"
while [ \$# -gt 0 ]; do
  if [ "\$1" = --notes-file ]; then cat "\$2" > "$WORK/gh.notes"; fi
  shift
done
EOF
chmod 0755 "$WORK/gh-stub/gh"
rm -f "$WORK/gh.args" "$WORK/gh.notes"
(cd "$REPO" && PATH="$WORK/gh-stub:$PATH" bash -c "$GH_LINE") ; RC=$?
ARGS="$(cat "$WORK/gh.args" 2>/dev/null)"
NOTES="$(cat "$WORK/gh.notes" 2>/dev/null)"
if [ "$RC" -eq 0 ] \
   && [ "$(printf '%s\n' "$ARGS" | sed -n 1,6p)" = "$(printf 'release\ncreate\nv1.1.0\ndist/EPSPreview-1.1.0.dmg\ndist/EPSPreview-1.1.0.dmg.sha256\n--title')" ] \
   && [[ "$ARGS" == *"EPS Preview 1.1.0"* ]] \
   && [[ "$NOTES" == *"- Something."* ]] && [[ "$NOTES" != *"First release"* ]]; then
  pass "the printed gh release command runs and passes the version's notes"
else
  fail "the printed gh release command" "rc=$RC line=$GH_LINE args=$ARGS notes=$NOTES"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
