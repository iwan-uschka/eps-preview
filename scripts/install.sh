#!/usr/bin/env bash
# Install EPS Preview.app to /Applications and register its Quick Look /
# Thumbnail extensions. Checks for a Ghostscript the render service will
# actually accept, and offers to install one via Homebrew if there is none.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The installer must apply the service's rules, not its own — see the header
# of this library.
# shellcheck source=lib/ghostscript-check.sh disable=SC1091
. "$ROOT/scripts/lib/ghostscript-check.sh"
APP="$ROOT/build/Build/Products/Release/EPSPreview.app"
DEST="/Applications/EPSPreview.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
QUICKLOOK_ID=com.zhangyanbo.EPSPreview.QuickLook
THUMBNAIL_ID=com.zhangyanbo.EPSPreview.Thumbnail

[ -d "$APP" ] || { echo "error: not built yet. Run: bash scripts/build.sh"; exit 1; }

# Each extension must carry its own copy of the render service — a sandboxed
# appex can only reach an XPC service inside its own bundle, so an extension
# without one previews nothing. `codesign --verify --deep --strict` below does
# not catch this: deep verification only checks nested code that is actually
# present, it never asserts that something ought to be there. Measured — it
# returns 0 on an app whose extensions have had XPCServices removed.
assert_embedded_service() {
  local appex="$1"
  [ -d "$APP/Contents/PlugIns/$appex/Contents/XPCServices/RenderService.xpc" ] || {
    echo "error: $appex is missing its embedded RenderService.xpc."
    echo "       This usually means \`xcodebuild ... test\` ran after \`build.sh\` and"
    echo "       silently stripped it (Xcode's test-phase rebuild only produces the"
    echo "       app; build.sh is the only thing that re-embeds). Rerun: bash scripts/build.sh"
    exit 1
  }
}
assert_embedded_service EPSQuickLook.appex
assert_embedded_service EPSThumbnail.appex

# Poll for the observable condition instead of guessing a sleep duration —
# LaunchServices/PluginKit take arbitrarily long on a loaded machine.
wait_until() {
  local timeout="$1"; shift
  local waited=0
  while ! "$@"; do
    [ "$waited" -lt "$((timeout * 4))" ] || return 1
    sleep 0.25
    waited=$((waited + 1))
  done
}
processes_gone() { ! pgrep -qx 'EPSPreview|EPSQuickLook|EPSThumbnail|RenderService'; }
extension_registered() { [ -n "$(pluginkit -m -i "$1" 2>/dev/null)" ]; }

echo "── Checking Ghostscript ──"
# Any rejected candidate explains itself on stderr, above the summary line.
if GS_PATH="$(eps_gs_find)"; then
  echo "  ✓ Ghostscript found: $GS_PATH ($(eps_gs_probe_version "$GS_PATH"))"
else
  echo "  ⚠️  No Ghostscript the render service will accept."
  if command -v brew >/dev/null 2>&1; then
    echo "  installing Ghostscript via Homebrew…"
    brew install ghostscript
    if GS_PATH="$(eps_gs_find)"; then
      echo "  ✓ Ghostscript found: $GS_PATH ($(eps_gs_probe_version "$GS_PATH"))"
    else
      echo "  ⚠️  Still nothing usable — previews will fail until this is fixed."
    fi
  else
    echo "     Install Homebrew (https://brew.sh) then: brew install ghostscript"
  fi
fi

echo "── Installing to $DEST ──"
osascript -e 'quit app "EPSPreview"' >/dev/null 2>&1 || true
killall EPSPreview EPSQuickLook EPSThumbnail RenderService >/dev/null 2>&1 || true
# Drop any stray registration of the build-tree copy so the system can't
# serve stale extension code.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
wait_until 10 processes_gone || echo "  ⚠️  EPS Preview processes still running; replacing the bundle anyway"
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
# The render service only talks to peers inside the *same* app bundle, so the
# signature has to be intact at the installed path, not just in build/.
codesign --verify --deep --strict "$DEST" || {
  echo "error: signature invalid at $DEST — rebuild with: bash scripts/build.sh"; exit 1; }
echo "  ✓ signature valid at $DEST"

echo "── Registering extensions ──"
"$LSREGISTER" -f -R "$DEST"
open "$DEST"
REGISTERED=1
for id in "$QUICKLOOK_ID" "$THUMBNAIL_ID"; do
  if wait_until 15 extension_registered "$id"; then
    echo "  ✓ $id registered"
  else
    echo "  ⚠️  $id not reported by pluginkit"
    REGISTERED=0
  fi
done

echo "── Refreshing Finder thumbnails ──"
# Reset only the thumbnail cache (NOT `qlmanage -r`, which de-registers
# third-party extensions) and restart Finder so EPS icons re-render.
# ThumbnailsAgent (the broker Finder actually asks) can keep a warm
# connection to whatever EPSThumbnail process was alive when it last talked
# to one — restarting Finder alone isn't enough to make it drop that and
# reconnect to the copy just installed above.
qlmanage -r cache >/dev/null 2>&1 || true
killall quicklookd >/dev/null 2>&1 || true
killall thumbnailservicesagent >/dev/null 2>&1 || true
killall com.apple.quicklook.ThumbnailsAgent >/dev/null 2>&1 || true
killall Finder >/dev/null 2>&1 || true

echo
if [ "$REGISTERED" -eq 1 ]; then
  echo "✓ Installed."
else
  echo "⚠️  Installed, but macOS has not registered the extensions yet."
fi
echo "  Select any .eps / .ps file in Finder and press the Space bar."
echo
echo "  If the preview doesn't appear immediately, enable it once under:"
echo "  System Settings → General → Login Items & Extensions → Quick Look."
