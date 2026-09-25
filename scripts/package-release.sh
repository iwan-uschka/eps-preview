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
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "error: version must be MAJOR.MINOR.PATCH (got '$VERSION')"
  echo "       usage: bash scripts/package-release.sh [version]"
  exit 1; }

APP="build/Build/Products/Release/EPSPreview.app"

echo "════ 1/5  Build app ════"
# build.sh stamps $VERSION into every bundle's CFBundleShortVersionString
# before it signs; doing it here would break the nested seals it just made.
EPS_MARKETING_VERSION="$VERSION" bash scripts/build.sh

echo
echo "════ 2/5  Embed self-contained Ghostscript ════"
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
rm -rf "$(dirname "$GSTMP")"

echo
echo "════ 3/5  Re-seal the app (added Contents/Helpers) ════"
# Adding Helpers/ invalidated the app's outer seal; re-sign the host app so
# the bundled gs is covered. (Nested extensions/service stay as signed.)
codesign --force --sign - --timestamp=none --options runtime \
  --entitlements Sources/Host/Host.entitlements "$APP"
codesign --verify --deep --strict "$APP" || {
  echo "error: signature invalid for $APP after re-seal"; exit 1; }
echo "  ✓ signature valid"

# --verify ignores entitlement contents, so re-assert the sandbox state the
# product depends on: host app sandboxed (it was just re-signed above),
# extensions sandboxed (or macOS won't register them),
# render service unsandboxed (or it can't exec Ghostscript).
assert_sandbox_state() {
  local want="$1" path="$2" ents state
  # A missing bundle would otherwise read as `absent` and pass vacuously.
  [ -e "$path" ] || { echo "error: no bundle at $path"; exit 1; }
  ents="$(mktemp)"
  codesign -d --entitlements :- --xml "$path" >"$ents" 2>/dev/null || true
  state="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ents" 2>/dev/null)" \
    || state="absent"
  rm -f "$ents"
  [ "$state" = "$want" ] || {
    echo "error: com.apple.security.app-sandbox is '$state' on $path (expected '$want')"
    exit 1; }
}
assert_sandbox_state true   "$APP"
assert_sandbox_state true   "$APP/Contents/PlugIns/EPSQuickLook.appex"
assert_sandbox_state true   "$APP/Contents/PlugIns/EPSThumbnail.appex"
assert_sandbox_state absent "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"
assert_sandbox_state absent "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc"
# The host no longer embeds the render service; check the path is gone rather
# than asserting `absent` on it, which the guard above would reject.
[ ! -e "$APP/Contents/XPCServices/RenderService.xpc" ] || {
  echo "error: host app still embeds Contents/XPCServices/RenderService.xpc"; exit 1; }
echo "  ✓ entitlements as expected"

# The re-seal above must not drop the hardened runtime build.sh signed with;
# the render service's peer check depends on it. Output is captured rather
# than piped into `grep -q`, which under pipefail could fail on SIGPIPE.
assert_hardened_runtime() {
  local path="$1" info
  info="$(codesign -dv "$path" 2>&1)" || {
    echo "error: cannot read code signature of $path"; exit 1; }
  [[ "$info" =~ flags=[^$'\n']*runtime ]] || {
    echo "error: hardened runtime flag missing on $path"; exit 1; }
}
assert_hardened_runtime "$APP"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSQuickLook.appex"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSThumbnail.appex"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc"
echo "  ✓ hardened runtime on every signed bundle"

echo
echo "════ 4/5  Build DMG ════"
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
echo "════ 5/5  Verify DMG ════"
hdiutil verify "$DMG" >/dev/null || {
  echo "error: $DMG failed hdiutil verify"; exit 1; }
echo "  ✓ image checksum valid"
MOUNT="$(mktemp -d)"
cleanup_mount() {
  hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 || true
  rmdir "$MOUNT" 2>/dev/null || true
}
trap cleanup_mount EXIT
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
codesign --verify --deep --strict "$MOUNT/EPSPreview.app" || {
  echo "error: app signature invalid inside $DMG"; exit 1; }
CONVERTER="$MOUNT/EPSPreview.app/Contents/Helpers/gs/converter"
[ -x "$CONVERTER" ] || {
  echo "error: bundled Ghostscript converter missing or not executable in $DMG"; exit 1; }
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$MOUNT/EPSPreview.app/Contents/Info.plist")"
[ "$INSTALLED_VERSION" = "$VERSION" ] || {
  echo "error: app in $DMG reports version $INSTALLED_VERSION, expected $VERSION"; exit 1; }
echo "  ✓ app signature valid, Ghostscript bundled, reports $INSTALLED_VERSION"
cleanup_mount
trap - EXIT

echo
echo "✓ Release built: $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
