#!/usr/bin/env bash
# Package a release DMG from the repo root: thin wrapper around scripts/package-release.sh <version>.
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/package-release.sh "$@"
