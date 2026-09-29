#!/usr/bin/env bash
# Build + ad-hoc sign from the repo root: thin wrapper around scripts/build.sh.
set -euo pipefail
cd "$(dirname "$0")"
exec bash scripts/build.sh "$@"
