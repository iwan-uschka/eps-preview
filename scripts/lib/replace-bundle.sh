# shellcheck shell=bash
# The swap step of scripts/install.sh — old bundle out, verified staging copy
# in — kept apart from it so its failure path can be tested against a
# throwaway directory instead of /Applications.
#
# Sourced, never executed — hence no shebang and no executable bit.
#
#   . "$ROOT/scripts/lib/replace-bundle.sh"
#   replace_bundle "$TMP_DEST" "$DEST" || exit 1

# Removes <dest> and renames <staged> into its place. If <dest> cannot be
# removed — typically a root-owned copy left behind by an earlier `sudo` run,
# which `rm -rf` as the user only half-deletes — it stops with rm's own error
# and instructions, offering the one-time `sudo rm -rf` only for the
# permission case
# instead of carrying on: a `mv` onto a surviving <dest> directory would nest
# the new bundle *inside* the old one rather than replace it. The staging copy
# is removed either way, so nothing is left next to <dest>. Never escalates
# with sudo itself; that stays the user's explicit, one-time decision.
#
# Usage: replace_bundle <staged> <dest>
replace_bundle() {
  local staged="$1" dest="$2" rm_err
  if ! rm_err="$(rm -rf "$dest" 2>&1)" || [ -e "$dest" ]; then
    rm -rf "$staged"
    {
      echo "error: could not remove the existing $dest, which may now be partly deleted."
      [ -z "$rm_err" ] || printf '%s\n' "$rm_err" | sed 's/^/       /'
      echo "       If \"Permission denied\" appears above, it is root-owned, left behind by"
      echo "       an earlier sudo run. Remove it once with:"
      echo "         sudo rm -rf \"$dest\""
      echo "       then rerun this script — without sudo. For any other error, fix that"
      echo "       cause first."
    } >&2
    return 1
  fi
  mv "$staged" "$dest" || { rm -rf "$staged"; return 1; }
}
