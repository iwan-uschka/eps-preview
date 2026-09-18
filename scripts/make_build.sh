#!/usr/bin/env bash
# Single entry point for a full build. Thin wrapper around scripts/build.sh —
# kept as its own make_* script purely so build/test/install/uninstall share
# one naming convention and none of them need remembering separately.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
exec bash "$ROOT/scripts/build.sh"
