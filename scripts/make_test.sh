#!/usr/bin/env bash
# Single entry point for the full test suite: Swift unit tests (which only
# build EPSPreviewTests — see project.yml's scheme comment for why that
# matters) plus the plain-bash suites. See README.md's Tests section for
# what each one covers.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

command -v xcodegen >/dev/null 2>&1 || {
  echo "error: xcodegen not found. Install with: brew install xcodegen"; exit 1; }

echo "── Generating Xcode project ──"
xcodegen generate

echo
echo "── Swift unit tests (EPSPreviewTests) ──"
if command -v xcbeautify >/dev/null 2>&1; then BEAUTIFY=(xcbeautify); else BEAUTIFY=(cat); fi
set -o pipefail
xcodebuild test -scheme EPSPreview -project EPSPreview.xcodeproj \
  -destination 'platform=macOS' | "${BEAUTIFY[@]}"

echo
echo "── Ghostscript vetting tests ──"
bash scripts/test-ghostscript-check.sh

echo
echo "── Bundled-library manifest tests ──"
bash scripts/test-ghostscript-manifest.sh

echo
echo "── Git hooks tests ──"
bash scripts/test-githooks.sh

echo
echo "── make_*.sh entry-point tests ──"
bash scripts/test-make-scripts.sh

echo
echo "── refresh-thumbnails.sh tests ──"
bash scripts/test-refresh-thumbnails.sh

echo
echo "── package-release.sh version-validation tests ──"
bash scripts/test-package-release.sh

echo
echo "✓ All test suites passed."
