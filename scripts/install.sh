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

[ -d "$APP" ] || { echo "error: not built yet. Run: bash scripts/build.sh"; exit 1; }

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
sleep 1
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "── Registering extensions ──"
"$LSREGISTER" -f -R "$DEST"
open "$DEST"
sleep 3

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
echo "✓ Installed."
echo "  Select any .eps / .ps file in Finder and press the Space bar."
echo
echo "  If the preview doesn't appear immediately, enable it once under:"
echo "  System Settings → General → Login Items & Extensions → Quick Look."
