#!/usr/bin/env bash
# Pins scripts/lib/ghostscript-thirdparty.sh — the formula/version parsing,
# bundled-file-to-formula attribution and metadata lookup, license-file
# discovery, Markdown table rendering and NOTICE.md
# generated-block replacement that scripts/bundle-ghostscript.sh uses to keep
# NOTICE.md's third-party manifest generated from the actual bundled closure
# instead of hand-maintained. Plain bash — no bats, no other dependency:
#
#   bash scripts/test-ghostscript-thirdparty.sh
#
# What it does *not* cover is bundle-ghostscript.sh's own glue (resolving
# formulae from the real Homebrew Cellar, calling `brew info --json=v2`,
# copying license files into the output tree): that needs a real Homebrew
# machine to exercise, so only the pure text-processing half is testable here
# — same split as scripts/test-ghostscript-manifest.sh.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib/ghostscript-thirdparty.sh disable=SC1091
. "$ROOT/scripts/lib/ghostscript-thirdparty.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-gs-thirdparty-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

TAB="$(printf '\t')"

# --- eps_formula_from_cellar_path / eps_formula_version_from_cellar_path --

out="$(eps_formula_from_cellar_path "/opt/homebrew/Cellar/freetype/2.14.3/lib/libfreetype.6.dylib")"
if [ "$out" = "freetype" ]; then
  pass "formula name extracted from a resolved Cellar path"
else
  fail "formula name extracted" "got '$out'"
fi

out="$(eps_formula_version_from_cellar_path "/opt/homebrew/Cellar/freetype/2.14.3/lib/libfreetype.6.dylib")"
if [ "$out" = "2.14.3" ]; then
  pass "version extracted from a resolved Cellar path"
else
  fail "version extracted" "got '$out'"
fi

out="$(eps_formula_version_from_cellar_path "/opt/homebrew/Cellar/zstd/1.5.7_1/lib/libzstd.1.dylib")"
if [ "$out" = "1.5.7_1" ]; then
  pass "a revisioned version directory (name_N) is kept whole"
else
  fail "revisioned version kept whole" "got '$out'"
fi

if eps_formula_from_cellar_path "/opt/homebrew/opt/freetype/lib/libfreetype.6.dylib" >"$WORK/unused" 2>/dev/null; then
  fail "an unresolved opt/ symlink path is rejected" "expected failure, got success"
else
  pass "an unresolved opt/ symlink path is rejected (callers must realpath first)"
fi

if out="$(eps_formula_from_cellar_path "/usr/lib/libSystem.dylib")"; then
  fail "a non-Cellar path is rejected" "got '$out'"
else
  pass "a non-Cellar path is rejected"
fi

if out="$(eps_formula_version_from_cellar_path "/usr/lib/libSystem.dylib")"; then
  fail "a non-Cellar path is rejected (version)" "got '$out'"
else
  pass "a non-Cellar path is rejected (version)"
fi

# --- eps_formula_path_from_sources / eps_bundled_basenames_for_keg ---------

SOURCES="$WORK/sources.tsv"
{
  printf 'converter\t/opt/homebrew/Cellar/ghostscript/10.05.1/bin/gs\n'
  printf 'libpng16.16.dylib\t/opt/homebrew/Cellar/libpng/1.6.50/lib/libpng16.16.dylib\n'
  printf 'libpng12.0.dylib\t/opt/homebrew/Cellar/libpng12/1.2.59/lib/libpng12.0.dylib\n'
  printf 'libwebp.7.dylib\t/opt/homebrew/Cellar/webp/1.6.0/lib/libwebp.7.dylib\n'
  printf 'libwebpmux.3.dylib\t/opt/homebrew/Cellar/webp/1.6.0/lib/libwebpmux.3.dylib\n'
  printf 'libfoo.1.dylib\t/opt/homebrew/Cellar/foo/1.0_1/lib/libfoo.1.dylib\n'
  printf 'libSystem.B.dylib\t/usr/lib/libSystem.B.dylib\n'
} > "$SOURCES"

out="$(eps_formula_path_from_sources "$SOURCES" "libpng")"
if [ "$out" = "/opt/homebrew/Cellar/libpng/1.6.50/lib/libpng16.16.dylib" ]; then
  pass "a formula's source path is found, not a prefix-sharing formula's"
else
  fail "formula source path lookup" "got '$out'"
fi

out="$(eps_formula_path_from_sources "$SOURCES" "webp")"
if [ "$out" = "/opt/homebrew/Cellar/webp/1.6.0/lib/libwebp.7.dylib" ]; then
  pass "only the first source path of a multi-file formula is printed"
else
  fail "first source path of a multi-file formula" "got '$out'"
fi

out="$(eps_formula_path_from_sources "$SOURCES" "absent")"
if [ -z "$out" ]; then
  pass "a formula with no bundled file yields no source path"
else
  fail "absent formula yields nothing" "got '$out'"
fi

out="$(eps_bundled_basenames_for_keg "$SOURCES" "/opt/homebrew/Cellar/webp/1.6.0")"
if [ "$out" = "libwebp.7.dylib,libwebpmux.3.dylib" ]; then
  pass "every bundled file from one keg is comma-joined in source order"
else
  fail "bundled basenames for a keg" "got '$out'"
fi

out="$(eps_bundled_basenames_for_keg "$SOURCES" "/opt/homebrew/Cellar/foo/1.0")"
if [ -z "$out" ]; then
  pass "a keg does not claim a sibling keg's files that merely share a path prefix"
else
  fail "keg prefix match is anchored at a path boundary" "got '$out'"
fi

out="$(eps_bundled_basenames_for_keg "$SOURCES" "/opt/homebrew/Cellar/foo/1.0_1/")"
if [ "$out" = "libfoo.1.dylib" ]; then
  pass "a keg directory given with a trailing slash still matches"
else
  fail "keg directory with trailing slash" "got '$out'"
fi

# --- eps_meta_line_for_formula ---------------------------------------------

META="$(printf '%s\n' \
  "libpng12${TAB}Libpng${TAB}https://example.com/png12" \
  "libpng${TAB}libpng-2.0${TAB}https://www.libpng.org/pub/png/libpng.html" \
  "webp${TAB}BSD-3-Clause${TAB}")"

out="$(printf '%s\n' "$META" | eps_meta_line_for_formula "libpng")"
if [ "$out" = "libpng${TAB}libpng-2.0${TAB}https://www.libpng.org/pub/png/libpng.html" ]; then
  pass "a formula's metadata line is matched by exact name, not prefix"
else
  fail "metadata line exact match" "got '$out'"
fi

out="$(printf '%s\n' "$META" | eps_meta_line_for_formula "absent")"
if [ -z "$out" ]; then
  pass "a formula missing from the metadata yields no line"
else
  fail "absent formula metadata" "got '$out'"
fi

# --- eps_license_files_in -------------------------------------------------

KEG="$WORK/keg"
mkdir -p "$KEG/lib" "$KEG/LICENSES"
: > "$KEG/LICENSE"
: > "$KEG/COPYING.LGPLv2.1"
: > "$KEG/COPYING.GPLv3"
: > "$KEG/License.TXT"
: > "$KEG/NOTICE"
: > "$KEG/UNLICENSE"
: > "$KEG/README.md"
: > "$KEG/lib/libfoo.dylib"
: > "$KEG/LICENSES/bundled-inside-a-dir-does-not-count"

out="$(eps_license_files_in "$KEG" | sort)"
expected="$(printf '%s\n' "COPYING.GPLv3" "COPYING.LGPLv2.1" "License.TXT" "LICENSE" "NOTICE" "UNLICENSE" | sort)"
if [ "$out" = "$expected" ]; then
  pass "license-like files are found, case-insensitively, multiple per keg"
else
  fail "license-like files found" "got: $out"
fi

if printf '%s\n' "$out" | grep -qx "README.md"; then
  fail "README.md is not mistaken for a license file" "it was included"
else
  pass "README.md is not mistaken for a license file"
fi

if printf '%s\n' "$out" | grep -qx "LICENSES"; then
  fail "a directory named like a license is not reported" "it was included"
else
  pass "a directory named like a license is not reported (files only)"
fi

out="$(eps_license_files_in "$WORK/does-not-exist")"
rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  pass "a missing keg directory yields no files, no error"
else
  fail "missing keg directory handled" "rc=$rc out=$out"
fi

# --- eps_render_thirdparty_table -------------------------------------------

ROWS="freetype${TAB}2.14.3${TAB}FTL${TAB}https://freetype.org${TAB}libfreetype.6.dylib${TAB}LICENSE.TXT"
out="$(printf '%s\n' "$ROWS" | eps_render_thirdparty_table)"
if printf '%s\n' "$out" | grep -qxF "| [freetype](https://freetype.org) | 2.14.3 | FTL | \`libfreetype.6.dylib\` | \`licenses/freetype/LICENSE.TXT\` |"; then
  pass "a single-file, single-library row renders correctly"
else
  fail "single row renders" "got: $out"
fi

if printf '%s\n' "$out" | head -1 | grep -qxF "| Project | Version | License | Bundled as | License file(s) |"; then
  pass "the table has the expected header"
else
  fail "table header" "got: $(printf '%s\n' "$out" | head -1)"
fi

ROWS="webp${TAB}1.6.0${TAB}BSD-3-Clause${TAB}https://developers.google.com/speed/webp/${TAB}libwebp.7.dylib,libwebpmux.3.dylib${TAB}COPYING"
out="$(printf '%s\n' "$ROWS" | eps_render_thirdparty_table)"
if printf '%s\n' "$out" | grep -qF "\`libwebp.7.dylib\`, \`libwebpmux.3.dylib\`"; then
  pass "multiple bundled libraries are comma-joined and backticked"
else
  fail "multiple bundled libraries joined" "got: $out"
fi

ROWS="xz${TAB}5.6.0${TAB}0BSD${TAB}https://tukaani.org/xz/${TAB}liblzma.5.dylib${TAB}COPYING.0BSD,COPYING.GPLv2"
out="$(printf '%s\n' "$ROWS" | eps_render_thirdparty_table)"
if printf '%s\n' "$out" | grep -qF "\`licenses/xz/COPYING.0BSD\`, \`licenses/xz/COPYING.GPLv2\`"; then
  pass "multiple license files are individually prefixed with licenses/<formula>/ and comma-joined"
else
  fail "multiple license files individually prefixed" "got: $out"
fi

ROWS="nolicense${TAB}1.0${TAB}Unknown${TAB}https://example.com${TAB}libnolicense.1.dylib${TAB}"
out="$(printf '%s\n' "$ROWS" | eps_render_thirdparty_table)"
if printf '%s\n' "$out" | grep -qxF "| [nolicense](https://example.com) | 1.0 | Unknown | \`libnolicense.1.dylib\` |  |"; then
  pass "an empty license-file list renders as an empty cell, not stray backticks"
else
  fail "empty license-file list renders cleanly" "got: $out"
fi

# A formula `brew info` has no homepage for is an empty *middle* field, not a
# trailing one — bash's `read` collapses that away even with IFS set to a
# bare tab (it still treats tab as "IFS whitespace"), which used to shift
# every column after it one field to the left. This is the regression case.
ROWS="nohomepage${TAB}1.0${TAB}Unknown${TAB}${TAB}libnohomepage.1.dylib${TAB}LICENSE"
out="$(printf '%s\n' "$ROWS" | eps_render_thirdparty_table)"
if printf '%s\n' "$out" | grep -qxF "| [nohomepage]() | 1.0 | Unknown | \`libnohomepage.1.dylib\` | \`licenses/nohomepage/LICENSE\` |"; then
  pass "an empty homepage (a middle field) does not shift later columns"
else
  fail "empty middle field does not shift columns" "got: $out"
fi

# --- eps_replace_generated_block -------------------------------------------

DOC="$WORK/NOTICE.md"
cat > "$DOC" <<'EOF'
# Notices

Some hand-written prose above the table.

<!-- BEGIN GENERATED -->
stale table row 1
stale table row 2
<!-- END GENERATED -->

Some hand-written prose below the table.
EOF

CONTENT="$WORK/content.md"
printf '%s\n' "fresh row 1" "fresh row 2" "fresh row 3" > "$CONTENT"

if eps_replace_generated_block "$DOC" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$CONTENT"; then
  pass "replace succeeds when both markers are present"
else
  fail "replace succeeds" "returned non-zero"
fi

if grep -qxF "fresh row 1" "$DOC" && grep -qxF "fresh row 3" "$DOC" && ! grep -qxF "stale table row 1" "$DOC"; then
  pass "stale content between markers is replaced with fresh content"
else
  fail "stale content replaced" "$(cat "$DOC")"
fi

if grep -qxF "Some hand-written prose above the table." "$DOC" \
   && grep -qxF "Some hand-written prose below the table." "$DOC" \
   && grep -qxF "<!-- BEGIN GENERATED -->" "$DOC" \
   && grep -qxF "<!-- END GENERATED -->" "$DOC"; then
  pass "hand-written prose and the markers themselves survive untouched"
else
  fail "surrounding prose and markers survive" "$(cat "$DOC")"
fi

# Re-running against the now-updated file must replace the *previous*
# generated content, not accumulate it — this is what makes the block safe to
# regenerate on every build.
printf '%s\n' "second-run row" > "$CONTENT"
eps_replace_generated_block "$DOC" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$CONTENT"
if grep -qxF "second-run row" "$DOC" && ! grep -qxF "fresh row 1" "$DOC"; then
  pass "regenerating replaces the previous generated block instead of accumulating"
else
  fail "regeneration does not accumulate" "$(cat "$DOC")"
fi

cat > "$DOC" <<'EOF'
# Notices
No markers in this file at all.
EOF
if eps_replace_generated_block "$DOC" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$CONTENT" 2>"$WORK/err"; then
  fail "a file missing both markers is rejected" "it succeeded"
else
  pass "a file missing both markers is rejected"
fi
if [ -s "$WORK/err" ]; then
  pass "the missing-marker failure explains itself on stderr"
else
  fail "missing-marker failure explains itself" "stderr was empty"
fi
if grep -qxF "No markers in this file at all." "$DOC"; then
  pass "a rejected replacement leaves the file untouched"
else
  fail "rejected replacement leaves file untouched" "$(cat "$DOC")"
fi

cat > "$DOC" <<'EOF'
# Notices
<!-- BEGIN GENERATED -->
stale row
EOF
if eps_replace_generated_block "$DOC" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$CONTENT" 2>"$WORK/err2"; then
  fail "a file missing only the end marker is rejected" "it succeeded"
else
  pass "a file missing only the end marker is rejected"
fi
if [ -s "$WORK/err2" ] && grep -qF "end marker not found" "$WORK/err2"; then
  pass "the end-marker failure names which marker is missing"
else
  fail "end-marker failure explains itself" "$(cat "$WORK/err2" 2>/dev/null)"
fi

printf '%s\n' "<!-- BEGIN GENERATED -->" "stale row" "<!-- END GENERATED -->" > "$DOC"
cp "$DOC" "$WORK/nocontent.orig"
if eps_replace_generated_block "$DOC" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$WORK/no-such-content.md" 2>"$WORK/err-content"; then
  fail "a missing content file is rejected" "it succeeded"
else
  pass "a missing content file is rejected"
fi
if cmp -s "$DOC" "$WORK/nocontent.orig" && grep -qF "content file not found" "$WORK/err-content"; then
  pass "a missing content file leaves the generated block untouched and says why"
else
  fail "missing content file leaves the block untouched" "$(cat "$DOC"; cat "$WORK/err-content")"
fi

cat > "$DOC" <<'EOF'
# Notices
<!-- END GENERATED -->
prose that must survive
<!-- BEGIN GENERATED -->
prose after the begin marker that must survive too
EOF
cp "$DOC" "$WORK/reversed.orig"
if eps_replace_generated_block "$DOC" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$CONTENT" 2>"$WORK/err-order"; then
  fail "an end marker before the begin marker is rejected" "it succeeded"
else
  pass "an end marker before the begin marker is rejected"
fi
if cmp -s "$DOC" "$WORK/reversed.orig" && grep -qF "not a single begin-before-end pair" "$WORK/err-order"; then
  pass "reversed markers leave the file untouched and say why"
else
  fail "reversed markers leave the file untouched" "$(cat "$DOC"; cat "$WORK/err-order")"
fi

cat > "$DOC" <<'EOF'
<!-- BEGIN GENERATED -->
old
<!-- END GENERATED -->
<!-- BEGIN GENERATED -->
prose that must survive
EOF
cp "$DOC" "$WORK/duplicated.orig"
if eps_replace_generated_block "$DOC" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$CONTENT" 2>/dev/null; then
  fail "a duplicated begin marker is rejected" "it succeeded"
elif cmp -s "$DOC" "$WORK/duplicated.orig"; then
  pass "a duplicated begin marker is rejected, leaving the file untouched"
else
  fail "duplicated begin marker leaves the file untouched" "$(cat "$DOC")"
fi

# A failed final `mv` (here: the target's directory is read-only) must not
# leave the temp file behind.
RO="$WORK/readonly"
TMPD="$WORK/tmpdir"
mkdir -p "$RO" "$TMPD"
printf '%s\n' "<!-- BEGIN GENERATED -->" "old" "<!-- END GENERATED -->" > "$RO/NOTICE.md"
chmod a-w "$RO"
if TMPDIR="$TMPD" eps_replace_generated_block "$RO/NOTICE.md" "<!-- BEGIN GENERATED -->" "<!-- END GENERATED -->" "$CONTENT" 2>/dev/null; then
  fail "a replacement whose final move fails is reported as a failure" "it succeeded"
else
  pass "a replacement whose final move fails is reported as a failure"
fi
if [ -z "$(ls -A "$TMPD")" ]; then
  pass "a failed replacement removes its temp file"
else
  fail "failed replacement removes its temp file" "left: $(ls -A "$TMPD")"
fi
chmod u+w "$RO"

# --- survives being sourced into a set -euo pipefail script ---------------

if ( set -euo pipefail
     unset _EPS_GS_THIRDPARTY_SH
     . "$ROOT/scripts/lib/ghostscript-thirdparty.sh"
     eps_formula_from_cellar_path "/opt/homebrew/Cellar/freetype/2.14.3/lib/x" >/dev/null
     eps_license_files_in "$KEG" >/dev/null ) 2>/dev/null; then
  pass "survives being sourced into a set -euo pipefail script"
else
  fail "survives set -euo pipefail" "the library aborted a strict shell"
fi

# --- summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
