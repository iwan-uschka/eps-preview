#!/usr/bin/env bash
# Build a self-contained, drag-to-install release:
#   - checks the release can go ahead (clean tree, new tag, no existing
#     `## [<version>]` and a non-empty `## [Unreleased]` in CHANGELOG.md)
#     before touching anything
#   - stamps CHANGELOG.md: `## [Unreleased]` becomes `## [<version>] - <date>`
#     under a fresh, empty `## [Unreleased]`
#   - builds EPSPreview.app
#   - embeds a self-contained Ghostscript (no Homebrew needed at runtime)
#   - re-signs (ad-hoc) and produces dist/EPSPreview-<version>.dmg plus its
#     dist/EPSPreview-<version>.dmg.sha256
#   - prints (never runs) the commit/push and `gh release create` commands
#     that publish it
#
# Any failure after the stamp restores CHANGELOG.md byte for byte. NOTICE.md is
# not restored: if step 3 (bundle-ghostscript.sh) already regenerated its
# third-party table, run `git checkout NOTICE.md` before re-running, or the
# clean-tree check refuses.
#
# The .dmg is ad-hoc signed (no Apple Developer Program), so first launch
# still needs the user to approve it once in System Settings → Privacy &
# Security. See the bundled INSTALL.txt file.
#
# Usage: bash scripts/package-release.sh <version>   (or: bash make_release.sh <version>)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=lib/release-checks.sh disable=SC1091
. "$ROOT/scripts/lib/release-checks.sh"

usage() { echo "       usage: bash scripts/package-release.sh <version>   (e.g. 1.2.0)"; }
# No default: a forgotten argument must not silently re-release some fixed
# version.
VERSION="${1:-}"
[ -n "$VERSION" ] || {
  echo "error: version argument required (MAJOR.MINOR.PATCH)"
  usage; exit 1; }
release_version_valid "$VERSION" || { usage; exit 1; }

CHANGELOG="CHANGELOG.md"
release_preflight "$VERSION" "$CHANGELOG" || exit 1

APP="build/Build/Products/Release/EPSPreview.app"
DMG="dist/EPSPreview-$VERSION.dmg"
# Built and verified under a hidden temp name, then moved to $DMG only once
# every check in the verify step has passed — so a failed run never leaves an
# image under the release name. The temp name must itself end in .dmg, or
# `hdiutil create` appends one.
PARTIAL="dist/.EPSPreview-$VERSION.partial.dmg"

# One EXIT trap for every piece of cleanup, driven by state variables, so no
# later step replaces an earlier step's cleanup by installing its own trap.
CHANGELOG_BACKUP=""
BACKED_UP=0
DMG_PLACED=0
RELEASED=0
MOUNT=""
MOUNTED=0
cleanup_mount() {
  # Nothing to detach when the attach itself failed; only the mountpoint dir remains.
  if [ "$MOUNTED" = 1 ]; then
    hdiutil detach "$MOUNT" -quiet >/dev/null 2>&1 \
      || hdiutil detach "$MOUNT" -force -quiet >/dev/null 2>&1 \
      || echo "warning: could not detach $MOUNT; run: hdiutil detach '$MOUNT' -force" >&2
  fi
  rmdir "$MOUNT" 2>/dev/null || true
  MOUNT=""
  MOUNTED=0
}
on_exit() {
  if [ -n "$MOUNT" ]; then cleanup_mount; fi
  rm -f "$PARTIAL"
  if [ "$RELEASED" != 1 ]; then
    if [ "$DMG_PLACED" = 1 ]; then rm -f "$DMG" "$DMG.sha256"; fi
    if [ "$BACKED_UP" = 1 ] && release_restore_changelog "$CHANGELOG_BACKUP" "$CHANGELOG"; then
      echo "  release failed — $CHANGELOG restored to its pre-release state" >&2
    fi
  fi
  if [ -n "$CHANGELOG_BACKUP" ]; then rm -f "$CHANGELOG_BACKUP"; fi
}
trap on_exit EXIT

echo "════ 1/6  Stamp $CHANGELOG ════"
# Stamped before the build, so the tree the DMG is built from already carries
# its own release entry. The preflight's clean-tree check ran first, so after
# this the only uncommitted changes are the release's own.
CHANGELOG_BACKUP="$(mktemp)"
cp "$CHANGELOG" "$CHANGELOG_BACKUP"
BACKED_UP=1
RELEASE_DATE="$(date +%Y-%m-%d)"
release_stamp_changelog "$VERSION" "$RELEASE_DATE" "$CHANGELOG" || exit 1
echo "  ✓ ## [Unreleased] → ## [$VERSION] - $RELEASE_DATE"

echo
echo "════ 2/6  Build app ════"
# build.sh stamps $VERSION into every bundle's CFBundleShortVersionString
# before it signs; doing it here would break the nested seals it just made.
EPS_MARKETING_VERSION="$VERSION" bash scripts/build.sh

echo
echo "════ 3/6  Embed self-contained Ghostscript ════"
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
echo "════ 4/6  Re-seal the app (added Contents/Helpers) ════"
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
# shellcheck source=lib/signature-checks.sh disable=SC1091
. "$ROOT/scripts/lib/signature-checks.sh"
assert_sandbox_state true   "$APP"
assert_sandbox_state true   "$APP/Contents/PlugIns/EPSQuickLook.appex"
assert_sandbox_state true   "$APP/Contents/PlugIns/EPSThumbnail.appex"
assert_sandbox_state absent "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"
assert_sandbox_state absent "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc"
# The host no longer embeds the render service; check the path is gone rather
# than asserting `absent` on it, which assert_sandbox_state's missing-bundle
# guard would reject.
[ ! -e "$APP/Contents/XPCServices/RenderService.xpc" ] || {
  echo "error: host app still embeds Contents/XPCServices/RenderService.xpc"; exit 1; }
echo "  ✓ entitlements as expected"

# The re-seal above must not drop the hardened runtime build.sh signed with;
# the render service's peer check depends on it.
assert_hardened_runtime "$APP"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSQuickLook.appex"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSThumbnail.appex"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"
assert_hardened_runtime "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc"
echo "  ✓ hardened runtime on every signed bundle"

echo
echo "════ 5/6  Build DMG ════"
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
rm -f "$DMG" "$DMG.sha256" "$PARTIAL"
hdiutil create -volname "EPS Preview" -srcfolder "$STAGE" \
  -ov -format UDZO "$PARTIAL" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo
echo "════ 6/6  Verify DMG ════"
hdiutil verify "$PARTIAL" >/dev/null || {
  echo "error: image for $DMG failed hdiutil verify"; exit 1; }
echo "  ✓ image checksum valid"
MOUNT="$(mktemp -d)"
hdiutil attach "$PARTIAL" -nobrowse -readonly -mountpoint "$MOUNT" >/dev/null
MOUNTED=1
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
mv "$PARTIAL" "$DMG"
DMG_PLACED=1
release_write_checksum "$DMG" || exit 1
RELEASED=1

echo
echo "✓ Release built: $DMG ($(du -h "$DMG" | cut -f1)), checksum in $DMG.sha256"
echo
# The tree was clean before the stamp, so everything modified now is the
# release's own doing: CHANGELOG.md, plus NOTICE.md if bundle-ghostscript.sh
# regenerated its third-party table.
CHANGED="$(git status --porcelain | cut -c4- | tr '\n' ' ')"
# shellcheck disable=SC2086 # one path per word, none contain spaces
release_print_next_steps "$VERSION" "$DMG" ${CHANGED:-$CHANGELOG}
