#!/usr/bin/env bash
# Assert that the bundle identifiers declared in Swift
# (Sources/Shared/BundleIdentifiers.swift), in project.yml, in the literals
# scripts/install.sh and scripts/uninstall.sh carry, and in the built bundles
# all agree.
#
# The Swift build cannot see project.yml, so a one-sided rename compiles and
# links cleanly and fails only at runtime, as "Render service connection
# failed". This is the check that turns that into a build-time error.
#
# Read-only and standalone — run it any time. The project.yml half needs no
# build; the built-bundle half is skipped until scripts/build.sh has run.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONSTANTS="Sources/Shared/BundleIdentifiers.swift"
[ -f "$CONSTANTS" ] || { echo "error: $CONSTANTS not found"; exit 1; }
command -v swift >/dev/null 2>&1 || {
  echo "error: swift not found. Install Xcode."; exit 1; }

# Ask the compiler for the values instead of pattern-matching them out of the
# source, so this check cannot drift from however the constants are spelled.
VALUES="$(mktemp)"
trap 'rm -f "$VALUES"' EXIT
{
  cat "$CONSTANTS"
  echo 'print(BundleIdentifiers.app)'
  echo 'print(BundleIdentifiers.quickLookExtension)'
  echo 'print(BundleIdentifiers.thumbnailExtension)'
  echo 'print(BundleIdentifiers.renderService)'
} | swift - > "$VALUES" || {
  echo "error: could not evaluate $CONSTANTS"; exit 1; }
{
  read -r SWIFT_APP || true
  read -r SWIFT_QUICKLOOK || true
  read -r SWIFT_THUMBNAIL || true
  read -r SWIFT_RENDER_SERVICE || true
} < "$VALUES"
[ -n "${SWIFT_APP:-}" ] && [ -n "${SWIFT_QUICKLOOK:-}" ] \
  && [ -n "${SWIFT_THUMBNAIL:-}" ] && [ -n "${SWIFT_RENDER_SERVICE:-}" ] || {
  echo "error: $CONSTANTS did not yield all four identifiers"; exit 1; }

echo "── Swift constants ──"
printf '  %s\n' "$SWIFT_APP" "$SWIFT_QUICKLOOK" "$SWIFT_THUMBNAIL" "$SWIFT_RENDER_SERVICE"

echo
echo "── project.yml ──"
# Compare the *set* of declared identifiers, so target order in project.yml
# does not matter here; the built-bundle pass below checks which target got
# which identifier. EPSPreviewTests is excluded: it is a test-only bundle,
# never installed and never an XPC peer, so it has no entry in
# BundleIdentifiers.swift to match against.
[ -f project.yml ] || { echo "error: project.yml not found"; exit 1; }
declared="$(sed -n 's/^[[:space:]]*PRODUCT_BUNDLE_IDENTIFIER:[[:space:]]*//p' project.yml \
  | { grep -v '\.Tests$' || true; } | sort)"
expected="$(printf '%s\n' "$SWIFT_APP" "$SWIFT_QUICKLOOK" "$SWIFT_THUMBNAIL" "$SWIFT_RENDER_SERVICE" | sort)"
if [ "$declared" != "$expected" ]; then
  echo "error: project.yml PRODUCT_BUNDLE_IDENTIFIER values do not match $CONSTANTS"
  diff <(echo "$expected") <(echo "$declared") | sed 's/^/  /' || true
  exit 1
fi
echo "  ✓ 4 identifiers match"

# install.sh and uninstall.sh poll pluginkit by the two extension identifiers
# and uninstall.sh removes the app's containers by the app-identifier prefix;
# a one-sided rename would make them wait out their timeout and report a
# successful install as "not registered".
echo
echo "── install/uninstall scripts ──"
for script in scripts/install.sh scripts/uninstall.sh; do
  [ -f "$script" ] || { echo "error: $script not found"; exit 1; }
  for pair in "QUICKLOOK_ID:$SWIFT_QUICKLOOK" "THUMBNAIL_ID:$SWIFT_THUMBNAIL"; do
    var="${pair%%:*}"
    want="${pair#*:}"
    got="$(sed -n "s/^$var=//p" "$script")"
    [ "$got" = "$want" ] || {
      echo "error: $script $var is '$got', expected '$want'"
      exit 1; }
  done
  echo "  ✓ $script"
done
grep -qF "Containers/$SWIFT_APP\"*" scripts/uninstall.sh || {
  echo "error: scripts/uninstall.sh does not remove Containers/$SWIFT_APP*"
  exit 1; }
echo "  ✓ scripts/uninstall.sh container prefix"

# Every hand-written Info.plist must keep deriving CFBundleIdentifier from the
# build setting rather than repeating a literal, or project.yml stops being the
# single source of truth for the plists.
echo
echo "── Source Info.plists ──"
for plist in Sources/Host/Info.plist Sources/QuickLook/Info.plist \
             Sources/Thumbnail/Info.plist Sources/RenderService/Info.plist; do
  value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null || true)"
  [ "$value" = '$(PRODUCT_BUNDLE_IDENTIFIER)' ] || {
    echo "error: $plist CFBundleIdentifier is '$value', expected \$(PRODUCT_BUNDLE_IDENTIFIER)"
    exit 1; }
  echo "  ✓ $plist"
done

APP="build/Build/Products/Release/EPSPreview.app"
echo
echo "── Built bundles ──"
if [ ! -d "$APP" ]; then
  echo "  skipped — no $APP (run: bash scripts/build.sh)"
  echo
  echo "✓ Bundle identifiers consistent (source only)"
  exit 0
fi

QUICKLOOK="$APP/Contents/PlugIns/EPSQuickLook.appex"
THUMBNAIL="$APP/Contents/PlugIns/EPSThumbnail.appex"

assert_bundle_id() {
  local want="$1" bundle="$2" value
  [ -d "$bundle" ] || { echo "error: missing bundle $bundle"; exit 1; }
  value="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "$bundle/Contents/Info.plist" 2>/dev/null || true)"
  [ "$value" = "$want" ] || {
    echo "error: $bundle CFBundleIdentifier is '$value', expected '$want'"
    exit 1; }
  echo "  ✓ $want — ${bundle#"$APP/"}"
}

assert_bundle_id "$SWIFT_APP"            "$APP"
assert_bundle_id "$SWIFT_QUICKLOOK"      "$QUICKLOOK"
assert_bundle_id "$SWIFT_THUMBNAIL"      "$THUMBNAIL"
assert_bundle_id "$SWIFT_RENDER_SERVICE" "$QUICKLOOK/Contents/XPCServices/RenderService.xpc"
assert_bundle_id "$SWIFT_RENDER_SERVICE" "$THUMBNAIL/Contents/XPCServices/RenderService.xpc"
# The host embeds no service of its own (asserted in scripts/build.sh); only
# the extension-embedded copies are checked here.

echo
echo "✓ Bundle identifiers consistent (source + built bundles)"
