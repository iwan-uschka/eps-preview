#!/usr/bin/env bash
# Build a self-contained, drag-to-install release:
#   - builds EPSPreview.app
#   - embeds a self-contained Ghostscript (no Homebrew needed at runtime)
#   - re-signs (ad-hoc) and produces dist/EPSPreview-<version>.dmg
#
# The .dmg is ad-hoc signed (no Apple Developer Program), so first launch
# still needs the user to approve it once in System Settings → Privacy &
# Security. See the bundled INSTALL.txt file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-1.0.0}"

APP="build/Build/Products/Release/EPSPreview.app"

echo "════ 1/4  Build app ════"
bash scripts/build.sh

echo
echo "════ 2/4  Embed self-contained Ghostscript ════"
GSTMP="$(mktemp -d)/gs"
bash scripts/bundle-ghostscript.sh "$GSTMP"
# Split: Mach-O (binary + libs) into Helpers/, the resource tree into
# Resources/. codesign refuses to seal a big loose data tree that sits in the
# same folder as Mach-O binaries, so they must live apart.
mkdir -p "$APP/Contents/Helpers/gs" "$APP/Contents/Resources/ghostscript"
cp -f "$GSTMP/converter" "$APP/Contents/Helpers/gs/converter"
cp -R "$GSTMP/lib" "$APP/Contents/Helpers/gs/lib"
cp -R "$GSTMP/share/." "$APP/Contents/Resources/ghostscript/"
# Carry the provenance record (gs version + binary hashes) into the shipped
# app, before the re-seal below so it is covered by the signature.
cp -f "$GSTMP/GHOSTSCRIPT_PROVENANCE.txt" "$APP/Contents/Resources/ghostscript/GHOSTSCRIPT_PROVENANCE.txt"
# Carry each bundled project's own license text alongside it, before the
# re-seal, so the shipped app discharges their redistribution obligations.
cp -R "$GSTMP/licenses" "$APP/Contents/Resources/ghostscript/licenses"
rm -rf "$(dirname "$GSTMP")"

echo
echo "════ 3/4  Re-seal the app (added Contents/Helpers) ════"
# Adding Helpers/ invalidated the app's outer seal; re-sign the host app so
# the bundled gs is covered. (Nested extensions/service stay as signed.)
codesign --force --sign - --timestamp=none \
  --entitlements Sources/Host/Host.entitlements "$APP"
codesign --verify --deep --strict "$APP" && echo "  ✓ signature valid"

echo
echo "════ 4/4  Build DMG ════"
STAGE="$(mktemp -d)/EPS Preview"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/EPSPreview.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/INSTALL.txt" <<'EOF'
EPS Preview — How to install
============================

1. Drag EPSPreview.app onto the "Applications" folder shown here.
2. Open Finder → Applications, find EPSPreview, and double-click it.
3. macOS will block it the first time (the app is not Apple-notarized).
   Open System Settings → Privacy & Security, scroll down, click
   "Open Anyway", and confirm once more. You only do this once — you will
   not be asked again.
4. After launching it once, select any .eps / .ps file in Finder and press
   Space to preview; Finder icons will show thumbnails too.

No Homebrew or Ghostscript install needed — both are bundled inside the app.
EOF

mkdir -p dist
DMG="dist/EPSPreview-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "EPS Preview" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo
echo "✓ Release built: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
