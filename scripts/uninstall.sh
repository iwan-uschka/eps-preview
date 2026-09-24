#!/usr/bin/env bash
# Remove EPS Preview.app and unregister its extensions.
set -euo pipefail

DEST="/Applications/EPSPreview.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
QUICKLOOK_ID=com.zhangyanbo.EPSPreview.QuickLook
THUMBNAIL_ID=com.zhangyanbo.EPSPreview.Thumbnail

[ -d "$DEST" ] || {
  echo "EPS Preview is not installed ($DEST not found) — nothing to remove."; exit 0; }

wait_until() {
  local timeout="$1"; shift
  local waited=0
  while ! "$@"; do
    [ "$waited" -lt "$((timeout * 4))" ] || return 1
    sleep 0.25
    waited=$((waited + 1))
  done
}
extension_gone() { [ -z "$(pluginkit -m -i "$1" 2>/dev/null)" ]; }

killall EPSPreview >/dev/null 2>&1 || true
pluginkit -r "$DEST/Contents/PlugIns/EPSQuickLook.appex" >/dev/null 2>&1 || true
pluginkit -r "$DEST/Contents/PlugIns/EPSThumbnail.appex" >/dev/null 2>&1 || true
"$LSREGISTER" -u "$DEST" >/dev/null 2>&1 || true
rm -rf "$DEST"
rm -rf "$HOME/Library/Containers/com.zhangyanbo.EPSPreview"* 2>/dev/null || true

killall com.apple.quicklook.ThumbnailsAgent >/dev/null 2>&1 || true
killall Finder >/dev/null 2>&1 || true

# PluginKit drops a removed extension asynchronously, so poll rather than
# assume the -r above took effect.
DEREGISTERED=1
for id in "$QUICKLOOK_ID" "$THUMBNAIL_ID"; do
  wait_until 10 extension_gone "$id" || {
    echo "  ⚠️  $id is still registered with PluginKit"
    DEREGISTERED=0; }
done

if [ "$DEREGISTERED" -eq 1 ]; then
  echo "✓ EPS Preview uninstalled."
else
  echo "⚠️  EPS Preview removed, but PluginKit still lists an extension."
  echo "   Log out and back in, then re-check with: pluginkit -m -i $QUICKLOOK_ID"
fi
