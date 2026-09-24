#!/usr/bin/env bash
# Build a self-contained Ghostscript tree into <output-dir>:
#
#   converter           the gs executable (dependent libs rewritten to @rpath)
#   lib/*.dylib         every non-system library it transitively needs
#   share/Resource/…    gs init / font / resource files
#   share/lib/…
#   share/iccprofiles/… default colour-space ICC profiles (gs_lev2.ps needs them)
#
# This lets the app render EPS on machines without Homebrew. Ghostscript is
# built from its own upstream source (AGPL-3.0 — the produced binary is
# AGPL; see NOTICE.md), *not* installed from Homebrew's bottle: Homebrew's
# `ghostscript` formula links tesseract/leptonica/libarchive in for an OCR
# device this EPS→PDF converter never invokes, which used to drag ~7 unused
# libraries (and their license/CVE surface) into every release. Building
# with `--without-tesseract` drops that whole OCR closure; the remaining
# dependencies (fontconfig, freetype, jbig2dec, jpeg-turbo, libpng, libtiff,
# little-cms2, openjpeg, libidn) are still sourced from Homebrew, same as
# before.
set -euo pipefail

# Pinned Ghostscript release, built from upstream source rather than
# whatever bottle Homebrew currently has on tap — that way the exact
# interpreter, and its CVE exposure, only change when this pin is bumped.
# Bump both of these deliberately (after checking the Ghostscript
# changelog/CVEs) when upgrading:
#   - EXPECTED_GHOSTSCRIPT_VERSION drives the download URL.
#   - GHOSTSCRIPT_SOURCE_SHA256 is the sha256 of that exact tarball, from
#     https://github.com/ArtifexSoftware/ghostpdl-downloads/releases — copy
#     it from there, don't compute it locally, so a compromised download
#     mirror can't also supply a matching hash.
EXPECTED_GHOSTSCRIPT_VERSION="10.07.1"
# The GitHub release tag has no delimiters: 10.07.1 -> gs10071.
GHOSTSCRIPT_RELEASE_TAG="gs10071"
GHOSTSCRIPT_SOURCE_SHA256="56f6a82907c3a73bba95de1319e029adf16477e34df2dea180d390e71e7c4053"
GHOSTSCRIPT_SOURCE_URL="https://github.com/ArtifexSoftware/ghostpdl-downloads/releases/download/${GHOSTSCRIPT_RELEASE_TAG}/ghostpdl-${EXPECTED_GHOSTSCRIPT_VERSION}.tar.xz"

# Homebrew resolves the runtime libs gs links against live, so two builds of
# the same pinned Ghostscript source can still ship different libtiff /
# freetype / openjpeg revisions — the parsers untrusted EPS data actually
# reaches. This manifest pins that closure by hash the way
# EXPECTED_GHOSTSCRIPT_VERSION pins gs.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPENDENCY_MANIFEST="$ROOT/scripts/ghostscript-dependencies.txt"
# shellcheck source=lib/ghostscript-manifest.sh disable=SC1091
. "$ROOT/scripts/lib/ghostscript-manifest.sh"

OUT="${1:?usage: bundle-ghostscript.sh <output-dir>}"

command -v brew >/dev/null 2>&1 || { echo "error: Homebrew is required to source Ghostscript's dependencies."; exit 1; }
command -v make >/dev/null 2>&1 || { echo "error: make is required to build Ghostscript (install Xcode Command Line Tools)."; exit 1; }
command -v cc >/dev/null 2>&1 || { echo "error: a C compiler is required to build Ghostscript (install Xcode Command Line Tools)."; exit 1; }

realpath_py() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
PREFIX="$(brew --prefix)"

# The libraries Ghostscript itself needs once OCR is out of the picture —
# NOT leptonica/libarchive/tesseract, which is the whole point of building
# from source instead of using Homebrew's bottle.
GS_RUNTIME_DEPS="fontconfig freetype jbig2dec jpeg-turbo libpng libtiff little-cms2 openjpeg libidn"
GS_BUILD_ONLY_DEPS="pkgconf"

echo "→ ensuring Ghostscript's (non-OCR) build dependencies are installed…"
for formula in $GS_RUNTIME_DEPS $GS_BUILD_ONLY_DEPS; do
  brew list "$formula" >/dev/null 2>&1 || brew install "$formula"
done

PKG_CONFIG_PATH=""
CPATH=""
LIBRARY_PATH=""
for formula in $GS_RUNTIME_DEPS; do
  dep_prefix="$(brew --prefix "$formula")"
  PKG_CONFIG_PATH="$dep_prefix/lib/pkgconfig:$PKG_CONFIG_PATH"
  CPATH="$dep_prefix/include:$CPATH"
  LIBRARY_PATH="$dep_prefix/lib:$LIBRARY_PATH"
done
export PKG_CONFIG_PATH CPATH LIBRARY_PATH

CLEANUP_DIRS=()
_cleanup() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap _cleanup EXIT INT TERM

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eps-ghostscript-build.XXXXXX")"
CLEANUP_DIRS+=("$BUILD_DIR")

echo "→ downloading Ghostscript $EXPECTED_GHOSTSCRIPT_VERSION source…"
TARBALL="$BUILD_DIR/ghostpdl-$EXPECTED_GHOSTSCRIPT_VERSION.tar.xz"
curl -fsSL -o "$TARBALL" "$GHOSTSCRIPT_SOURCE_URL"
ACTUAL_SHA256="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [ "$ACTUAL_SHA256" != "$GHOSTSCRIPT_SOURCE_SHA256" ]; then
  echo "error: downloaded Ghostscript source does not match the pinned checksum."
  echo "       expected $GHOSTSCRIPT_SOURCE_SHA256"
  echo "       got      $ACTUAL_SHA256"
  echo "       Refusing to build from an unverified source tarball."
  exit 1
fi

echo "→ extracting…"
tar -xf "$TARBALL" -C "$BUILD_DIR"
SRC="$BUILD_DIR/ghostpdl-$EXPECTED_GHOSTSCRIPT_VERSION"

echo "→ configuring Ghostscript (--without-tesseract: no OCR device, so no tesseract/leptonica/libarchive/webp-mux/giflib in the link closure)…"
(
  cd "$SRC"
  # Delete the vendored copies of libraries Homebrew already provides, so
  # configure links the system copies instead — same approach Homebrew's own
  # formula takes. leptonica/tesseract are removed too: --without-tesseract
  # skips them, but dropping the source keeps the tree honest about what's
  # actually being built.
  rm -rf expat freetype jbig2dec jpeg lcms2mt libpng openjpeg tiff zlib leptonica tesseract
  ./configure \
    --disable-compile-inits \
    --disable-cups \
    --disable-gtk \
    --with-system-libtiff \
    --without-versioned-path \
    --without-x \
    --without-tesseract
)

echo "→ building…"
( cd "$SRC" && make -j"$(sysctl -n hw.ncpu)" )

GS_BIN="$(realpath_py "$SRC/bin/gs")"
[ -x "$GS_BIN" ] || { echo "error: the build did not produce a gs binary at $GS_BIN"; exit 1; }

INSTALLED_VERSION="$("$GS_BIN" --version)"
if [ "$INSTALLED_VERSION" != "$EXPECTED_GHOSTSCRIPT_VERSION" ]; then
  echo "error: the built gs reports version $INSTALLED_VERSION, expected $EXPECTED_GHOSTSCRIPT_VERSION."
  echo "       Something about the pinned source tarball or build doesn't match the pin above."
  exit 1
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
mkdir -p "$OUT/share"
cp -R "$SRC/Resource"     "$OUT/share/"
cp -R "$SRC/lib"          "$OUT/share/"
# gs_lev2.ps resolves the default color-space ICC profiles relative to
# Resource/Init's parent (i.e. a sibling `iccprofiles/`, same layout Homebrew
# ships under share/ghostscript/) — without it, setdevice fails outright
# (caught and reported as "Unable to open the initial device") on any machine
# that doesn't happen to also have Ghostscript's build-time --prefix on disk.
cp -R "$SRC/iccprofiles"  "$OUT/share/"

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
for dir in "$OUT/share/Resource/Init" "$OUT/share/lib" "$OUT/share/iccprofiles"; do
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
CLEANUP_DIRS+=("$PROBE")
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
# tree renders this silently; any output here (a warning, a fallback notice,
# anything) means the bundled resource tree isn't actually self-contained, so
# treat it as a failure even where gs itself still exits 0.
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
