#!/usr/bin/env bash
# Build, install to /Applications and register the extensions from the repo root: thin wrapper around scripts/make_install.sh, which holds the no-sudo guard.
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/make_install.sh "$@"
