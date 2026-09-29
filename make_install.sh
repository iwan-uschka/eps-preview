#!/usr/bin/env bash
# Install the existing build to /Applications from the repo root: thin wrapper around scripts/install.sh.
set -euo pipefail
cd "$(dirname "$0")"
# Same no-sudo rule as scripts/make_install.sh — see its comment for why.
if [ "$(id -u)" -eq 0 ]; then
  echo "error: do not run this with sudo — see scripts/make_install.sh's comment." >&2
  exit 1
fi
exec bash scripts/install.sh "$@"
