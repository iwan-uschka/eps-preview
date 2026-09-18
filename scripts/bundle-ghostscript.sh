#!/usr/bin/env bash
# Build a self-contained Ghostscript tree into <output-dir>:
#
#   converter           the gs executable (dependent libs rewritten to @rpath)
#   lib/*.dylib         every non-system library it transitively needs
#   share/Resource/…    gs init / font / resource files
#   share/lib/…
#
# This lets the app render EPS on machines without Homebrew. It sources
# Homebrew's Ghostscript, which is AGPL-3.0 — the produced binary is AGPL;
# see NOTICE.md.
set -euo pipefail

# Pinned Ghostscript release. `brew install ghostscript` always tracks
# whatever Homebrew currently has on tap, which silently changes the exact
# interpreter binary — and its CVE exposure — shipped in every future build.
# Bump this deliberately (after checking the Ghostscript changelog/CVEs) when
# upgrading, rather than picking up new versions unreviewed.
EXPECTED_GHOSTSCRIPT_VERSION="10.07.1"

# Homebrew resolves the ~20 dylibs gs links against live, so two builds of the
# same pinned Ghostscript can ship different libtiff / freetype / openjpeg
# revisions — the parsers untrusted EPS data actually reaches. This manifest
# pins that closure by hash the way EXPECTED_GHOSTSCRIPT_VERSION pins gs.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPENDENCY_MANIFEST="$ROOT/scripts/ghostscript-dependencies.txt"
# shellcheck source=lib/ghostscript-manifest.sh disable=SC1091
. "$ROOT/scripts/lib/ghostscript-manifest.sh"

OUT="${1:?usage: bundle-ghostscript.sh <output-dir>}"

command -v brew >/dev/null 2>&1 || { echo "error: Homebrew is required to source Ghostscript."; exit 1; }
if ! brew list ghostscript >/dev/null 2>&1; then
  AVAILABLE_VERSION="$(brew info --json=v2 ghostscript 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["formulae"][0]["versions"]["stable"])' 2>/dev/null || echo unknown)"
  if [ "$AVAILABLE_VERSION" != "$EXPECTED_GHOSTSCRIPT_VERSION" ] && [ "${ALLOW_GHOSTSCRIPT_VERSION_MISMATCH:-0}" != "1" ]; then
    echo "error: Homebrew would install Ghostscript $AVAILABLE_VERSION, this script is pinned to $EXPECTED_GHOSTSCRIPT_VERSION."
    echo "       Review the Ghostscript changelog/CVEs for the new version, then either:"
    echo "         - update EXPECTED_GHOSTSCRIPT_VERSION in this script to $AVAILABLE_VERSION, or"
    echo "         - pin Homebrew to the expected version."
    echo "       To install anyway (not recommended), re-run with ALLOW_GHOSTSCRIPT_VERSION_MISMATCH=1."
    exit 1
  fi
  brew install ghostscript
fi

realpath_py() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
GS_BIN="$(realpath_py "$(brew --prefix ghostscript)/bin/gs")"
PREFIX="$(brew --prefix)"
[ -x "$GS_BIN" ] || { echo "error: gs not found at $GS_BIN"; exit 1; }

INSTALLED_VERSION="$("$GS_BIN" --version)"
if [ "$INSTALLED_VERSION" != "$EXPECTED_GHOSTSCRIPT_VERSION" ]; then
  if [ "${ALLOW_GHOSTSCRIPT_VERSION_MISMATCH:-0}" != "1" ]; then
    echo "error: Homebrew has Ghostscript $INSTALLED_VERSION, this script is pinned to $EXPECTED_GHOSTSCRIPT_VERSION."
    echo "       Review the Ghostscript changelog/CVEs for the new version, then either:"
    echo "         - update EXPECTED_GHOSTSCRIPT_VERSION in this script to $INSTALLED_VERSION, or"
    echo "         - pin Homebrew to the expected version."
    echo "       To bundle anyway (not recommended), re-run with ALLOW_GHOSTSCRIPT_VERSION_MISMATCH=1."
    exit 1
  fi
  echo "warning: bundling unpinned Ghostscript $INSTALLED_VERSION (expected $EXPECTED_GHOSTSCRIPT_VERSION)"
fi

rm -rf "$OUT"; mkdir -p "$OUT/lib"
cp -f "$GS_BIN" "$OUT/converter"; chmod u+w "$OUT/converter"

# Dependent libraries, excluding OS libs and self/relative references.
list_deps() {
  otool -L "$1" 2>/dev/null | tail -n +2 | awk '{print $1}' \
    | grep -vE '^/usr/lib/|^/System/|^@executable_path/|^@loader_path/'
}
resolve_lib() { # basename -> absolute path inside Homebrew
  local b="$1"
  [ -f "$PREFIX/lib/$b" ] && { echo "$PREFIX/lib/$b"; return; }
  find "$PREFIX/Cellar" "$PREFIX/opt" -maxdepth 6 -name "$b" -type f 2>/dev/null | head -1
}

echo "→ collecting dependent libraries…"
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  for bin in "$OUT/converter" "$OUT"/lib/*.dylib; do
    [ -f "$bin" ] || continue
    while IFS= read -r dep; do
      [ -n "$dep" ] || continue
      case "$dep" in
        @rpath/*) base="${dep#@rpath/}" ;;
        *)        base="$(basename "$dep")" ;;
      esac
      [ -f "$OUT/lib/$base" ] && continue
      src=""
      [ "${dep:0:1}" = "/" ] && [ -f "$dep" ] && src="$dep"
      [ -n "$src" ] || src="$(resolve_lib "$base")"
      if [ -n "$src" ] && [ -f "$src" ]; then
        cp -f "$src" "$OUT/lib/$base"; chmod u+w "$OUT/lib/$base"; changed=1
        echo "   + $base"
      else
        echo "error: $bin needs $dep, which resolves to nothing under $PREFIX."
        echo "       Dropping it would ship a tree that dyld-errors on every machine"
        echo "       without Homebrew. Install the missing formula and re-run."
        exit 1
      fi
    done < <(list_deps "$bin")
  done
done

echo "→ rewriting install names to @rpath…"
# install_name_tool warns on every single rewrite that it has invalidated the
# code signature — everything is re-signed below, so that line is expected
# noise; only surface output when a rewrite actually fails.
rewrite_macho() {
  local out
  out="$(install_name_tool "$@" 2>&1)" || {
    echo "error: install_name_tool $* failed:"
    printf '%s\n' "$out" | sed 's/^/       /'
    return 1
  }
}
retarget() {
  local f="$1"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    rewrite_macho -change "$dep" "@rpath/$(basename "$dep")" "$f"
  done < <(list_deps "$f")
}
for dy in "$OUT"/lib/*.dylib; do
  [ -f "$dy" ] || continue
  rewrite_macho -id "@rpath/$(basename "$dy")" "$dy"
  retarget "$dy"
done
retarget "$OUT/converter"
rewrite_macho -add_rpath "@executable_path/lib" "$OUT/converter"

echo "→ copying Ghostscript resources…"
GSSHARE="$(dirname "$(dirname "$GS_BIN")")/share/ghostscript"
[ -d "$GSSHARE/Resource" ] || GSSHARE="$("$GS_BIN" -h 2>/dev/null | grep -m1 'Resource/Init' | sed 's#/Resource/Init.*##' | tr -d ' :')"
mkdir -p "$OUT/share"
cp -R "$GSSHARE/Resource" "$OUT/share/"
cp -R "$GSSHARE/lib"      "$OUT/share/"

echo "→ ad-hoc signing…"
for dy in "$OUT"/lib/*.dylib; do codesign --force --sign - "$dy"; done
codesign --force --sign - "$OUT/converter"

echo "→ recording provenance…"
{
  echo "version=$INSTALLED_VERSION"
  echo "converter_sha256=$(shasum -a 256 "$OUT/converter" | awk '{print $1}')"
  for dy in "$OUT"/lib/*.dylib; do
    [ -f "$dy" ] || continue
    echo "lib_sha256=$(basename "$dy") $(shasum -a 256 "$dy" | awk '{print $1}')"
  done
  echo "bundled_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT/GHOSTSCRIPT_PROVENANCE.txt"

echo "→ checking the bundled library closure…"
bundled_libs() { sed -n 's/^lib_sha256=//p' "$OUT/GHOSTSCRIPT_PROVENANCE.txt"; }
MANIFEST_DIFF=""
MANIFEST_RC=0
MANIFEST_DIFF="$(bundled_libs | eps_manifest_check "$DEPENDENCY_MANIFEST")" || MANIFEST_RC=$?
case "$MANIFEST_RC" in
  0) ;;
  2)
    bundled_libs > "$DEPENDENCY_MANIFEST"
    echo "   recorded $(bundled_libs | wc -l | tr -d ' ') libraries in ${DEPENDENCY_MANIFEST#"$ROOT"/}"
    echo "   — commit it so later builds are checked against this closure."
    ;;
  *)
    if [ "${ALLOW_DEPENDENCY_MANIFEST_MISMATCH:-0}" != "1" ]; then
      echo "error: the bundled library closure no longer matches ${DEPENDENCY_MANIFEST#"$ROOT"/}."
      printf '%s\n' "$MANIFEST_DIFF" | sed 's/^/       /'
      echo "       Ghostscript itself is still $EXPECTED_GHOSTSCRIPT_VERSION, but these are the"
      echo "       libraries it parses untrusted image/font data with, so their CVE exposure"
      echo "       changed. Review their changelogs/CVEs, then either:"
      echo "         - update ${DEPENDENCY_MANIFEST#"$ROOT"/} to the closure above (delete it and re-run to regenerate), or"
      echo "         - pin Homebrew to the recorded revisions."
      echo "       To bundle anyway (not recommended), re-run with ALLOW_DEPENDENCY_MANIFEST_MISMATCH=1."
      exit 1
    fi
    echo "warning: bundling a library closure that differs from ${DEPENDENCY_MANIFEST#"$ROOT"/}"
    ;;
esac

echo "→ verifying the assembled tree…"
for dir in "$OUT/share/Resource/Init" "$OUT/share/lib"; do
  [ -d "$dir" ] || { echo "error: Ghostscript resource tree incomplete, missing $dir."; exit 1; }
done

# otool prints one header line per file argument, and $OUT can itself live
# under $PREFIX — only the tab-indented dependency lines are load commands.
LEFTOVER="$(otool -L "$OUT/converter" "$OUT"/lib/*.dylib | awk '/^\t/ {print $1}' | grep -F "$PREFIX" | sort -u || true)"
if [ -n "$LEFTOVER" ]; then
  echo "error: bundled binaries still load libraries from $PREFIX:"
  printf '%s\n' "$LEFTOVER" | sed 's/^/       /'
  echo "       They would dyld-error on any machine without Homebrew."
  exit 1
fi

"$OUT/converter" --version >/dev/null

PROBE="$(mktemp -d)"
# Cleaned up from a trap, not just on the success path: the probe-render check
# below exits 1, and a script that leaks a temp directory on every failed run
# litters $TMPDIR while it is being worked on.
trap 'rm -rf "$PROBE"' EXIT INT TERM
cat > "$PROBE/probe.eps" <<'EOF'
%!PS-Adobe-3.0 EPSF-3.0
%%BoundingBox: 0 0 8 8
0.5 setgray 0 0 8 8 rectfill
showpage
EOF
# Same GS_LIB layout GhostscriptLocator.bundledGhostscript() builds, and the
# same gs flags RenderService.render() passes (minus -sstdout=%stderr, which
# only matters for keeping fd 1 empty in production — this probe merges
# stdout/stderr itself via 2>&1 below, and minus the `sh -c 'ulimit …'`
# wrapper), so this exercises the tree the way the shipped app will. A correct
# tree renders this silently; gs falls back to its compiled-in Homebrew
# resource path when the bundled one is unusable, and the only trace of that
# on a machine that has Homebrew is the warning it prints — so any output here
# is a failure, not just a non-zero exit.
PROBE_LOG="$(GS_LIB="$OUT/share/Resource/Init:$OUT/share/lib:$OUT/share/Resource/Font" \
  "$OUT/converter" -dNOPAUSE -dBATCH -dQUIET -dSAFER -dEPSCrop \
  -dAutoRotatePages=/None -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 \
  -sOutputFile="$PROBE/probe.pdf" "$PROBE/probe.eps" 2>&1)"
if [ ! -s "$PROBE/probe.pdf" ] || [ -n "$PROBE_LOG" ]; then
  echo "error: the bundled Ghostscript did not cleanly render the probe EPS."
  printf '%s\n' "$PROBE_LOG" | sed 's/^/       /'
  exit 1
fi

echo "✓ self-contained Ghostscript at $OUT ($(du -sh "$OUT" | cut -f1))"
