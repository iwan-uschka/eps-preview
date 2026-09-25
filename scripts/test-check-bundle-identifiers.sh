#!/usr/bin/env bash
# Pins check-bundle-identifiers.sh's failure paths: each one-sided rename it
# exists to catch must exit non-zero with its `error:` line, and an unmodified
# tree must pass. Every case runs the script from a throwaway copy of just the
# files it reads (the Swift constants, project.yml, install/uninstall scripts
# and the four source Info.plists), mutated one identifier at a time — the
# real tree is never edited. The built-bundle cases fake a minimal
# build/Build/Products/Release/EPSPreview.app of Info.plists, so no real build
# is needed. Needs `swift` (the script evaluates the constants with it) and
# /usr/libexec/PlistBuddy, i.e. macOS with Xcode, like make_test.sh itself.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-bundle-ids-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

FILES=(
  scripts/check-bundle-identifiers.sh
  Sources/Shared/BundleIdentifiers.swift
  project.yml
  scripts/install.sh
  scripts/uninstall.sh
  Sources/Host/Info.plist
  Sources/QuickLook/Info.plist
  Sources/Thumbnail/Info.plist
  Sources/RenderService/Info.plist
)

# fresh_tree <name> — prints the path of a new copy of FILES under $WORK.
fresh_tree() {
  local tree="$WORK/$1" f
  for f in "${FILES[@]}"; do
    mkdir -p "$tree/$(dirname "$f")"
    cp "$ROOT/$f" "$tree/$f"
  done
  echo "$tree"
}

# fake_build <tree> — a minimal built app whose bundles carry the real ids.
fake_build() {
  local app="$1/build/Build/Products/Release/EPSPreview.app" bundle id
  for pair in \
    ".:com.zhangyanbo.EPSPreview" \
    "Contents/PlugIns/EPSQuickLook.appex:com.zhangyanbo.EPSPreview.QuickLook" \
    "Contents/PlugIns/EPSThumbnail.appex:com.zhangyanbo.EPSPreview.Thumbnail" \
    "Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc:com.zhangyanbo.EPSPreview.RenderService" \
    "Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc:com.zhangyanbo.EPSPreview.RenderService"; do
    bundle="$app/${pair%%:*}"
    id="${pair#*:}"
    mkdir -p "$bundle/Contents"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $id" \
      "$bundle/Contents/Info.plist" >/dev/null
  done
}

# expect_failure <description> <tree> <expected error substring>
expect_failure() {
  local desc="$1" tree="$2" want="$3" rc=0 out
  out="$(bash "$tree/scripts/check-bundle-identifiers.sh" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ] && [[ "$out" == *"error: "*"$want"* ]]; then
    pass "$desc"
  else
    fail "$desc" "rc=$rc out=$out"
  fi
}

# expect_success <description> <tree> <expected summary substring>
expect_success() {
  local desc="$1" tree="$2" want="$3" rc=0 out
  out="$(bash "$tree/scripts/check-bundle-identifiers.sh" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && [[ "$out" == *"$want"* ]]; then
    pass "$desc"
  else
    fail "$desc" "rc=$rc out=$out"
  fi
}

T="$(fresh_tree clean)"
expect_success "unmodified tree passes (source only)" "$T" \
  "✓ Bundle identifiers consistent (source only)"

T="$(fresh_tree project-yml)"
sed -i '' 's/PRODUCT_BUNDLE_IDENTIFIER: com.zhangyanbo.EPSPreview.QuickLook$/PRODUCT_BUNDLE_IDENTIFIER: com.example.QuickLook/' "$T/project.yml"
expect_failure "project.yml identifier rename is rejected" "$T" \
  "project.yml PRODUCT_BUNDLE_IDENTIFIER values do not match"

T="$(fresh_tree install-quicklook)"
sed -i '' 's/^QUICKLOOK_ID=.*/QUICKLOOK_ID=com.example.QuickLook/' "$T/scripts/install.sh"
expect_failure "install.sh QUICKLOOK_ID mismatch is rejected" "$T" \
  "scripts/install.sh QUICKLOOK_ID is 'com.example.QuickLook'"

T="$(fresh_tree uninstall-thumbnail)"
sed -i '' 's/^THUMBNAIL_ID=.*/THUMBNAIL_ID=com.example.Thumbnail/' "$T/scripts/uninstall.sh"
expect_failure "uninstall.sh THUMBNAIL_ID mismatch is rejected" "$T" \
  "scripts/uninstall.sh THUMBNAIL_ID is 'com.example.Thumbnail'"

T="$(fresh_tree uninstall-containers)"
sed -i '' 's#Containers/com.zhangyanbo.EPSPreview"\*#Containers/com.example.EPSPreview"*#' "$T/scripts/uninstall.sh"
expect_failure "uninstall.sh container prefix mismatch is rejected" "$T" \
  "scripts/uninstall.sh does not remove Containers/"

T="$(fresh_tree plist-literal)"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.zhangyanbo.EPSPreview.QuickLook" \
  "$T/Sources/QuickLook/Info.plist"
expect_failure "source Info.plist with a literal CFBundleIdentifier is rejected" "$T" \
  "Sources/QuickLook/Info.plist CFBundleIdentifier is 'com.zhangyanbo.EPSPreview.QuickLook'"

T="$(fresh_tree built-clean)"
fake_build "$T"
expect_success "matching built bundles pass (source + built bundles)" "$T" \
  "✓ Bundle identifiers consistent (source + built bundles)"

T="$(fresh_tree built-wrong-id)"
fake_build "$T"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.example.Thumbnail" \
  "$T/build/Build/Products/Release/EPSPreview.app/Contents/PlugIns/EPSThumbnail.appex/Contents/Info.plist"
expect_failure "built bundle with the wrong CFBundleIdentifier is rejected" "$T" \
  "EPSThumbnail.appex CFBundleIdentifier is 'com.example.Thumbnail'"

T="$(fresh_tree built-missing)"
fake_build "$T"
rm -rf "$T/build/Build/Products/Release/EPSPreview.app/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"
expect_failure "built app missing an embedded RenderService.xpc is rejected" "$T" \
  "missing bundle build/Build/Products/Release/EPSPreview.app/Contents/PlugIns/EPSQuickLook.appex/Contents/XPCServices/RenderService.xpc"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
