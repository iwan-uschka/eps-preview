#!/usr/bin/env bash
# Single entry point for uninstall. Same no-sudo rule as make_install.sh —
# see its comment for why.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -eq 0 ]; then
  echo "error: do not run this with sudo — see make_install.sh's comment." >&2
  exit 1
fi

bash "$ROOT/scripts/uninstall.sh"
