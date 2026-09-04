#!/usr/bin/env bash
# Build EPS Preview.app (host + Quick Look + Thumbnail extensions + render
# XPC service) and ad-hoc sign it. No Apple Developer Program account needed.
#
# Idempotent — safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found. Install with: brew install xcodegen"; exit 1; }
# The Command Line Tools alone ship an xcodebuild stub that fails opaquely
# ("tool 'xcodebuild' requires Xcode"), so check for a real Xcode up front.
xcodebuild -version >/dev/null 2>&1 || {
  echo "error: full Xcode required (xcode-select -p → $(xcode-select -p 2>/dev/null))"
  echo "       Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
  exit 1; }

# Marketing version to stamp into the built bundles; scripts/package-release.sh
# sets it from its version argument. Unset → keep whatever the source
# Info.plists declare.
MARKETING_VERSION="${EPS_MARKETING_VERSION:-}"
if [ -n "$MARKETING_VERSION" ] && ! [[ "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: EPS_MARKETING_VERSION must be MAJOR.MINOR.PATCH (got '$MARKETING_VERSION')"; exit 1
fi

echo "── (1/7) Generating Xcode project ──"
xcodegen generate

echo
echo "── (2/7) Building (Release) ──"
if command -v xcbeautify >/dev/null 2>&1; then BEAUTIFY=(xcbeautify); else BEAUTIFY=(cat); fi
xcodebuild \
  -project EPSPreview.xcodeproj \
  -scheme EPSPreview \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_STYLE=Manual \
  build | "${BEAUTIFY[@]}"

APP="build/Build/Products/Release/EPSPreview.app"
SERVICE="build/Build/Products/Release/RenderService.xpc"
[ -d "$APP" ]     || { echo "error: build produced no $APP"; exit 1; }
[ -d "$SERVICE" ] || { echo "error: build produced no $SERVICE"; exit 1; }

echo
echo "── (3/7) Embedding RenderService.xpc into each extension ──"
# A sandboxed extension can only reach an XPC service that lives inside its
# own bundle (Contents/XPCServices). So each extension carries its own copy.
embed_service() {
  local host_dir="$1"
  mkdir -p "$host_dir/Contents/XPCServices"
  rm -rf "$host_dir/Contents/XPCServices/RenderService.xpc"
  cp -R "$SERVICE" "$host_dir/Contents/XPCServices/"
  echo "  → $host_dir/Contents/XPCServices/RenderService.xpc"
}
embed_service "$APP/Contents/PlugIns/EPSQuickLook.appex"
embed_service "$APP/Contents/PlugIns/EPSThumbnail.appex"

echo
echo "── (4/7) Pinning NSExtension blocks in built Info.plists ──"
# Xcode has been observed to drop/rewrite the NSExtension block on build.
# Re-assert it directly in the built bundles so registration is reliable —
# copied from the source Info.plist, which stays the single source of truth,
# then diffed back so a failed copy can never ship silently.
patch_extension() {
  local plist="$1" source_plist="$2" block
  block="$(mktemp -t NSExtension.plist)"
  /usr/libexec/PlistBuddy -x -c "Print :NSExtension" "$source_plist" > "$block"
  /usr/libexec/PlistBuddy -c "Delete :NSExtension" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSExtension dict" -c "Merge $block :NSExtension" "$plist"
  diff <(/usr/libexec/PlistBuddy -x -c "Print :NSExtension" "$plist") "$block" || {
    echo "error: NSExtension in $plist diverges from $source_plist"; exit 1; }
  rm -f "$block"
  echo "  patched $(basename "$(dirname "$(dirname "$plist")")") from $source_plist"
}
patch_extension \
  "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/Info.plist" \
  Sources/QuickLook/Info.plist
patch_extension \
  "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/Info.plist" \
  Sources/Thumbnail/Info.plist

echo
echo "── (5/7) Stamping build version ──"
# Give every rebuild a unique, monotonically increasing CFBundleVersion so
# LaunchServices / PluginKit never serve cached *old* extension code after
# a reinstall.
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"
set_plist_string() {
  local plist="$1" key="$2" value="$3"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
}
for plist in \
  "$APP/Contents/Info.plist" \
  "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/Info.plist" \
  "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/Info.plist" \
  "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc/Contents/Info.plist" \
  "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc/Contents/Info.plist"; do
  [ -f "$plist" ] || continue
  set_plist_string "$plist" CFBundleVersion "$BUILD_VERSION"
  if [ -n "$MARKETING_VERSION" ]; then
    set_plist_string "$plist" CFBundleShortVersionString "$MARKETING_VERSION"
  fi
done
echo "  CFBundleVersion = $BUILD_VERSION"
if [ -n "$MARKETING_VERSION" ]; then
  echo "  CFBundleShortVersionString = $MARKETING_VERSION"
fi

echo
echo "── (6/7) Ad-hoc signing (inside-out) ──"
sign() { codesign --force --sign - --timestamp=none "$@"; }

# 1. The unsandboxed render service copies (no entitlements → unsandboxed).
sign "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"
sign "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc"
echo "  signed 2× RenderService.xpc (unsandboxed)"

# 2. The sandboxed extensions, each with its entitlements.
sign --entitlements Sources/QuickLook/QuickLook.entitlements \
  "$APP/Contents/PlugIns/EPSQuickLook.appex"
echo "  signed EPSQuickLook.appex (sandboxed)"
sign --entitlements Sources/Thumbnail/Thumbnail.entitlements \
  "$APP/Contents/PlugIns/EPSThumbnail.appex"
echo "  signed EPSThumbnail.appex (sandboxed)"

# 3. The host app, sealing everything.
sign --entitlements Sources/Host/Host.entitlements "$APP"
echo "  signed EPSPreview.app"

echo
echo "── (7/7) Verifying signature graph and entitlements ──"
# `cmd && echo ok` would let a verification failure slide past `set -e`.
codesign --verify --deep --strict --verbose=2 "$APP" || {
  echo "error: signature graph invalid for $APP"; exit 1; }
echo "  ✓ valid"

# --verify says nothing about entitlement *contents*, and the sandbox state is
# load-bearing in both directions: macOS 15/26 refuse to register an
# unsandboxed Quick Look extension at all, while a sandboxed RenderService
# could not exec Ghostscript.
assert_sandbox_state() {
  local want="$1" path="$2" ents state
  ents="$(mktemp)"
  codesign -d --entitlements :- --xml "$path" >"$ents" 2>/dev/null || true
  state="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ents" 2>/dev/null)" \
    || state="absent"
  rm -f "$ents"
  [ "$state" = "$want" ] || {
    echo "error: com.apple.security.app-sandbox is '$state' on $path (expected '$want')"
    exit 1; }
  echo "  ✓ app-sandbox $state — ${path#"$APP/"}"
}
assert_sandbox_state true   "$APP/Contents/PlugIns/EPSQuickLook.appex"
assert_sandbox_state true   "$APP/Contents/PlugIns/EPSThumbnail.appex"
assert_sandbox_state absent "$APP/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"
assert_sandbox_state absent "$APP/Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc"
assert_sandbox_state absent "$APP/Contents/XPCServices/RenderService.xpc"

echo
echo "✓ Build complete: $APP"
echo "  Install with: bash scripts/install.sh"
