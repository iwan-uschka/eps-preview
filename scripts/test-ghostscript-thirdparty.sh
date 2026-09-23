#!/usr/bin/env bash
# Pins scripts/lib/ghostscript-thirdparty.sh — the formula/version parsing,
# license-file discovery, Markdown table rendering and NOTICE.md
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

# --- eps_license_files_in -------------------------------------------------

KEG="$WORK/keg"
mkdir -p "$KEG/lib" "$KEG/LICENSES"
: > "$KEG/LICENSE"
: > "$KEG/COPYING.LGPLv2.1"
: > "$KEG/COPYING.GPLv3"
: > "$KEG/License.TXT"
: > "$KEG/NOTICE"
: > "$KEG/README.md"
: > "$KEG/lib/libfoo.dylib"
: > "$KEG/LICENSES/bundled-inside-a-dir-does-not-count"

out="$(eps_license_files_in "$KEG" | sort)"
expected="$(printf '%s\n' "COPYING.GPLv3" "COPYING.LGPLv2.1" "License.TXT" "LICENSE" "NOTICE" | sort)"
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

# --- survives being sourced into a set -euo pipefail script ---------------

if ( set -euo pipefail
     unset _EPS_GS_THIRDPARTY_SH
     . "$ROOT/scripts/lib/ghostscript-thirdparty.sh"
     eps_formula_from_cellar_path "/opt/homebrew/Cellar/freetype/2.14.3/lib/x" >/dev/null
     eps_license_files_in "$WORK/does-not-exist" >/dev/null ) 2>/dev/null; then
  pass "survives being sourced into a set -euo pipefail script"
else
  fail "survives set -euo pipefail" "the library aborted a strict shell"
fi

# --- summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
