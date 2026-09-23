# shellcheck shell=bash
# Turns the Homebrew kegs bundle-ghostscript.sh actually resolved into a
# per-project license manifest, so NOTICE.md's third-party table is generated
# from what a build bundled instead of hand-maintained prose that can drift
# from reality as dependency versions change.
#
# Sourced, never executed — hence no shebang and no executable bit.
#
# Pulled out of bundle-ghostscript.sh for the same reason
# scripts/lib/ghostscript-manifest.sh was: the text-processing pieces need to
# be exercisable against fake paths, fake kegs and a fake NOTICE.md, not only
# on a real Homebrew machine mid-build. scripts/test-ghostscript-thirdparty.sh
# pins it.
#
# Written for the bash 3.2 that macOS ships — no associative arrays, no
# `mapfile`, no `${x,,}`.
#
# Sourceable from a `set -euo pipefail` script:
#
#   . "$ROOT/scripts/lib/ghostscript-thirdparty.sh"
#   formula="$(eps_formula_from_cellar_path "$resolved_path")"
#   version="$(eps_formula_version_from_cellar_path "$resolved_path")"
#   path="$(eps_formula_path_from_sources sources.tsv "$formula")"
#   bundled="$(eps_bundled_basenames_for_keg sources.tsv "$keg_dir")"
#   meta="$(eps_meta_line_for_formula "$formula" < meta.tsv)"
#   eps_license_files_in "$keg_dir"
#   eps_render_thirdparty_table < rows.tsv > table.md
#   eps_replace_generated_block NOTICE.md "$BEGIN" "$END" table.md

if [ -n "${_EPS_GS_THIRDPARTY_SH:-}" ]; then
  return 0
fi
_EPS_GS_THIRDPARTY_SH=1

# eps_formula_from_cellar_path <path>: prints the Homebrew formula name that
# owns <path> — the path component right after "Cellar/". <path> must already
# have every symlink resolved (an /opt/homebrew/opt/<formula> or a
# .../lib/<file> symlink hop hides the formula name behind a name that need
# not match) — callers realpath(1) it first. Returns 1, printing nothing, if
# <path> is not inside a Cellar.
eps_formula_from_cellar_path() {
  case "$1" in
    */Cellar/*/*) ;;
    *) return 1 ;;
  esac
  local rest="${1#*/Cellar/}"
  printf '%s\n' "${rest%%/*}"
}

# eps_formula_version_from_cellar_path <path>: same shape as
# eps_formula_from_cellar_path, but prints the version directory (the Cellar
# path component right after the formula name) instead.
eps_formula_version_from_cellar_path() {
  case "$1" in
    */Cellar/*/*) ;;
    *) return 1 ;;
  esac
  local rest="${1#*/Cellar/}"
  rest="${rest#*/}"
  printf '%s\n' "${rest%%/*}"
}

# eps_formula_path_from_sources <sources-file> <formula>: <sources-file> holds
# "<bundled-basename><TAB><resolved-source-path>" lines. Prints the first
# source path that lives inside a Cellar keg of exactly <formula> (a formula
# whose name merely shares a prefix, e.g. "libpng" vs "libpng12", does not
# match). Prints nothing if none does.
eps_formula_path_from_sources() {
  awk -F'\t' -v f="$2" '
    { n = split($2, a, "/Cellar/"); if (n == 2) { split(a[2], b, "/"); if (b[1] == f) { print $2; exit } } }
  ' "$1"
}

# eps_bundled_basenames_for_keg <sources-file> <keg-dir>: prints, comma-joined
# on one line in <sources-file> order, the bundled basename of every entry
# whose source path lies inside <keg-dir> (a sibling keg whose path merely
# starts with the same characters, e.g. ".../1.0" vs ".../1.0_1", does not
# match). Prints nothing if none does.
eps_bundled_basenames_for_keg() {
  awk -F'\t' -v keg="${2%/}/" '
    index($2, keg) == 1 { printf "%s%s", (n++ ? "," : ""), $1 }
  ' "$1"
}

# eps_meta_line_for_formula <formula>: reads "<name><TAB><license><TAB><homepage>"
# lines on stdin and prints the first whose name is exactly <formula>, or
# nothing if none is.
eps_meta_line_for_formula() {
  awk -F'\t' -v f="$1" '$1 == f { print; exit }'
}

# eps_license_files_in <dir>: prints, one per line, the basename of every
# top-level file in <dir> that looks like a license/notice file (LICENSE*,
# COPYING*, NOTICE*, UNLICENSE*, case-insensitive) — Homebrew kegs carry the
# upstream project's own license file(s) right there, and sometimes more than
# one (dual-licensed projects ship one file per license option, e.g. xz's
# COPYING.0BSD and COPYING.GPLv2 side by side). Prints nothing, without
# error, if <dir> does not exist.
eps_license_files_in() {
  local dir="$1" f base lower
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      license*|copying*|notice*|unlicense*) printf '%s\n' "$base" ;;
    esac
  done
}

# eps_render_thirdparty_table: reads tab-separated rows on stdin — formula,
# version, license, homepage, bundled-as (comma-joined dylib/binary
# basenames), license files (comma-joined basenames, harvested into
# licenses/<formula>/ alongside the row's formula) — and prints a Markdown
# table with a header, one row per input line, in input order (callers sort
# beforehand so the table doesn't depend on filesystem/hash-map iteration
# order). Purely a text transform — no network, no filesystem access — so
# it's testable with made-up rows.
#
# Deliberately awk, not a bash `while read` loop: bash's `read` treats a tab
# as "IFS whitespace" and collapses runs of it even when IFS is set to
# nothing but a tab, so a row with an empty middle field (a formula with no
# recorded homepage, say) silently shifts every field after it left by one.
# awk's -F splitting has no such collapsing — an empty field stays a field.
eps_render_thirdparty_table() {
  printf '| Project | Version | License | Bundled as | License file(s) |\n'
  printf '|---------|---------|---------|------------|------------------|\n'
  awk -F'\t' '
    function join_backtick(list, prefix,    n, i, arr, out) {
      if (list == "") return ""
      n = split(list, arr, ",")
      for (i = 1; i <= n; i++) {
        if (arr[i] == "") continue
        out = out (out == "" ? "" : ", ") "`" prefix arr[i] "`"
      }
      return out
    }
    $1 == "" { next }
    {
      printf "| [%s](%s) | %s | %s | %s | %s |\n", $1, $4, $2, $3, \
        join_backtick($5, ""), join_backtick($6, "licenses/" $1 "/")
    }
  '
}

# eps_replace_generated_block <file> <begin-marker> <end-marker> <content-file>:
# rewrites <file> in place, replacing every line strictly between a line that
# exactly matches <begin-marker> and the next line that exactly matches
# <end-marker> with the contents of <content-file>. Both marker lines are
# preserved verbatim. Fails loudly, leaving <file> untouched, if either
# marker is missing, duplicated, or the end marker precedes the begin
# marker, or if <content-file> is unreadable — silently skipping the replacement would ship a stale
# table instead of erroring, which is worse than crashing the build.
eps_replace_generated_block() {
  local file="$1" begin="$2" end="$3" contentfile="$4" tmp
  [ -r "$contentfile" ] || {
    echo "error: content file not found or unreadable: $contentfile" >&2; return 1; }
  grep -qxF "$begin" "$file" || {
    echo "error: begin marker not found in $file: $begin" >&2; return 1; }
  grep -qxF "$end" "$file" || {
    echo "error: end marker not found in $file: $end" >&2; return 1; }
  # A reversed or duplicated marker would leave the awk below skipping every
  # line through EOF, silently truncating the file instead of failing.
  awk -v begin="$begin" -v end="$end" '
    $0 == begin { b++; if (!bl) bl = NR }
    $0 == end   { e++; if (!el) el = NR }
    END { exit !(b == 1 && e == 1 && bl < el) }
  ' "$file" || {
    echo "error: markers in $file are not a single begin-before-end pair" >&2; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/eps-notice.XXXXXX")"
  awk -v begin="$begin" -v end="$end" -v contentfile="$contentfile" '
    $0 == begin { print; while ((getline line < contentfile) > 0) print line; skipping=1; next }
    $0 == end   { skipping=0 }
    skipping    { next }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}
