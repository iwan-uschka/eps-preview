# shellcheck shell=bash
# Decides whether a freshly bundled Ghostscript library closure still matches
# the committed manifest, for scripts/bundle-ghostscript.sh.
#
# Sourced, never executed — hence no shebang and no executable bit.
#
# Extracted from bundle-ghostscript.sh for the same reason
# scripts/lib/ghostscript-check.sh was extracted from install.sh: the decision
# is a release gate, so it needs to be exercisable against fake inputs rather
# than only on a real Homebrew machine mid-release.
# scripts/test-ghostscript-manifest.sh pins it.
#
# Written for the bash 3.2 that macOS ships — no associative arrays, no
# `mapfile`.
#
# Sourceable from a `set -euo pipefail` script:
#
#   . "$ROOT/scripts/lib/ghostscript-manifest.sh"
#   rc=0
#   diff_text="$(bundled_libs | eps_manifest_check "$manifest")" || rc=$?

if [ -n "${_EPS_GS_MANIFEST_SH:-}" ]; then
  return 0
fi
_EPS_GS_MANIFEST_SH=1

# Prints $1 as lines, and prints nothing at all when it is empty: a bare
# `printf '%s\n' ""` emits one blank line, which diff would report as a
# spurious one-line difference against an empty manifest.
_eps_manifest_print() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$1"
}

# eps_manifest_check <manifest-file>, with the bundled "<name> <sha256>" lines
# on stdin. Returns:
#
#   0  the closure matches the manifest — nothing printed
#   2  no manifest recorded yet — nothing printed, the caller records one
#   1  the closure differs — a unified diff of manifest → bundled is printed
#      on stdout with its `---`/`+++` header dropped, ready to be indented
#      into an error message
#
# Both sides are sorted under `LC_ALL=C` first, so the verdict depends on the
# set of libraries and their hashes and not on the order the caller collected
# them in: the bundled list comes out of a `lib/*.dylib` glob, whose order is
# LC_COLLATE-dependent, and a pure reordering is not a closure change.
eps_manifest_check() {
  local manifest="$1" bundled diff_out
  bundled="$(cat)"
  [ -f "$manifest" ] || return 2
  if diff_out="$(diff -u <(LC_ALL=C sort "$manifest") \
                         <(_eps_manifest_print "$bundled" | LC_ALL=C sort))"; then
    return 0
  fi
  printf '%s\n' "$diff_out" | tail -n +3
  return 1
}
