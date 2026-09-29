# shellcheck shell=bash
# Version, git and CHANGELOG.md helpers for scripts/package-release.sh, kept
# apart from it so the guards and the changelog stamping can be tested against
# throwaway git repos without running a real build.
#
# Sourced, never executed — hence no shebang and no executable bit.
#
# Unlike scripts/lib/signature-checks.sh, every helper here *returns* 1 (with
# an `error:` line) instead of exiting, so a test can call it directly; the
# release script adds its own `|| exit 1`.
#
#   . "$ROOT/scripts/lib/release-checks.sh"
#   release_version_valid "$VERSION" || exit 1
#   release_preflight "$VERSION" CHANGELOG.md || exit 1
#   release_stamp_changelog "$VERSION" "$(date +%Y-%m-%d)" CHANGELOG.md || exit 1

# The same MAJOR.MINOR.PATCH rule scripts/build.sh applies to
# EPS_MARKETING_VERSION: no `v` prefix, no pre-release or build suffix.
#
# Usage: release_version_valid <version>
release_version_valid() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: version must be MAJOR.MINOR.PATCH (got '$1')"
    return 1; }
}

# Prints the body of CHANGELOG.md's `## [Unreleased]` section: every line after
# that heading up to (not including) the next `## [` heading.
#
# Usage: release_unreleased_body <changelog>
release_unreleased_body() {
  awk '
    /^## \[Unreleased\][[:space:]]*$/ { inside = 1; next }
    /^## \[/                          { inside = 0 }
    inside
  ' "$1"
}

# awk program printing the body of the `## [<v>]` section (heading excluded),
# up to the next `## [` heading. A variable rather than only a function
# because package-release.sh also prints it inside the suggested
# `gh release create --notes-file` command; one definition keeps the two from
# drifting. index() rather than a regex, so the dots in the version are not
# wildcards. Contains no single quote, so it can be pasted inside one.
# shellcheck disable=SC2016 # awk variables, not shell ones
RELEASE_SECTION_AWK='index($0, "## [" v "]") == 1 { inside = 1; next } /^## \[/ { inside = 0 } inside'

# Usage: release_changelog_section <version> <changelog>
release_changelog_section() {
  awk -v v="$1" "$RELEASE_SECTION_AWK" "$2"
}

# Everything that must hold before package-release.sh changes a single file or
# starts the (slow) build. Run from the repository root.
#
#   - CHANGELOG.md exists (and has an `## [Unreleased]` heading), so there is
#     something to stamp and to publish as release notes;
#   - the working tree is clean, so the release commit contains exactly the
#     stamped CHANGELOG.md (plus whatever the build itself regenerates) and
#     the DMG is built from committed sources;
#   - tag v<version> does not exist yet (checked locally only — no network);
#   - CHANGELOG.md has no `## [<version>]` section yet (a hand-stamped file, or
#     a release that failed after its commit but before its tag);
#   - `## [Unreleased]` has content. Blank lines and bare `###` subheadings
#     (an empty `### Added`) do not count: they would publish empty notes.
#
# Usage: release_preflight <version> <changelog>
release_preflight() {
  local version="$1" changelog="$2" dirty
  [ -f "$changelog" ] || {
    echo "error: $changelog not found — the release notes come from it."
    return 1; }
  grep -Eq '^## \[Unreleased\][[:space:]]*$' "$changelog" || {
    echo "error: $changelog has no '## [Unreleased]' heading to stamp."
    return 1; }
  dirty="$(git status --porcelain)" || {
    echo "error: git status failed — run this from the repository's working tree."
    return 1; }
  [ -z "$dirty" ] || {
    echo "error: working tree is not clean; commit or stash these first:"
    printf '%s\n' "$dirty" | sed 's/^/         /'
    return 1; }
  if git rev-parse -q --verify "refs/tags/v$version" >/dev/null; then
    echo "error: tag v$version already exists — pick a new version."
    return 1
  fi
  # Anchored the same way as RELEASE_SECTION_AWK (index() == 1, dots literal),
  # since a second `## [<version>]` heading would make it concatenate both.
  if awk -v v="$version" 'index($0, "## [" v "]") == 1 { found = 1; exit } END { exit !found }' "$changelog"; then
    echo "error: $changelog already has a '## [$version]' section — pick a new version."
    return 1
  fi
  release_unreleased_body "$changelog" | grep -Eqv '^[[:space:]]*(###.*)?$' || {
    echo "error: the '## [Unreleased]' section of $changelog is empty."
    echo "       Add what changed under it before releasing."
    return 1; }
}

# Turns the `## [Unreleased]` heading into a fresh, empty `## [Unreleased]`
# followed by `## [<version>] - <date>`, so the entries collected so far become
# the new version's section. Only the first such heading is touched. Rewrites
# the file in place (same inode and mode) via a temp file.
#
# Usage: release_stamp_changelog <version> <YYYY-MM-DD> <changelog>
release_stamp_changelog() {
  local version="$1" date="$2" changelog="$3" tmp
  tmp="$(mktemp)" || return 1
  if awk -v heading="## [$version] - $date" '
       !done && /^## \[Unreleased\][[:space:]]*$/ {
         print "## [Unreleased]"; print ""; print heading; done = 1; next }
       { print }
     ' "$changelog" > "$tmp" && cat "$tmp" > "$changelog"; then
    rm -f "$tmp"
  else
    rm -f "$tmp"
    echo "error: could not stamp $changelog"
    return 1
  fi
}

# Puts <changelog> back byte for byte from <backup>, the copy taken before
# release_stamp_changelog ran. package-release.sh calls this from its EXIT
# trap on any failure after the stamp, so a failed release leaves the file
# exactly as it found it and the next attempt stamps it afresh.
#
# Usage: release_restore_changelog <backup> <changelog>
release_restore_changelog() {
  cat "$1" > "$2" || {
    echo "error: could not restore $2 from $1 — restore it by hand: git checkout -- $2" >&2
    return 1; }
}

# Writes <dmg>.sha256 next to <dmg> in `shasum -a 256` format, naming the
# image by its bare file name so `shasum -a 256 -c <name>.sha256` works from
# the directory both are downloaded into. Prints the checksum line.
#
# Usage: release_write_checksum <dmg>
release_write_checksum() {
  local dir name
  dir="$(dirname "$1")"; name="$(basename "$1")"
  ( cd "$dir" && shasum -a 256 "$name" > "$name.sha256" && cat "$name.sha256" ) || {
    echo "error: could not write $1.sha256"
    return 1; }
}

# Prints the commands that finish the release. Printed, never run: pushing and
# publishing stay a deliberate human step. `gh release create` creates the
# v<version> tag on the pushed commit, so no separate `git tag` is needed.
#
# Usage: release_print_next_steps <version> <dmg> <changed-path>…
release_print_next_steps() {
  local version="$1" dmg="$2"; shift 2
  echo "Next steps (not run for you):"
  echo
  echo "  git add $* && git commit -m 'Release $version' && git push"
  echo "  gh release create v$version $dmg $dmg.sha256 --title \"EPS Preview $version\" --notes-file <(awk -v v=$version '$RELEASE_SECTION_AWK' CHANGELOG.md)"
  echo
  echo "The app is ad-hoc signed, not notarized: users approve it once under"
  echo "System Settings → Privacy & Security (\"Open Anyway\")."
}
