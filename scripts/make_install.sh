#!/usr/bin/env bash
# Single entry point for install: builds, then installs to /Applications and
# registers the Quick Look / Thumbnail extensions.
#
# Refuses to run under sudo — scripts/install.sh calls lsregister and open,
# both of which are per-user. Registering under root's LaunchServices
# database is invisible to your actual login session, which makes Finder's
# thumbnails silently stop working again even though the install "succeeded"
# (see README.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ "$(id -u)" -eq 0 ]; then
  echo "error: do not run this with sudo." >&2
  echo "       install.sh registers extensions per-user; running as root" >&2
  echo "       registers them into root's LaunchServices database, which is" >&2
  echo "       invisible to your actual login session." >&2
  echo "       /Applications is writable by your admin-group user already —" >&2
  echo "       sudo is not needed here. If a previous sudo run left a" >&2
  echo "       root-owned /Applications/EPSPreview.app behind, clear it with" >&2
  echo "       a one-time: sudo rm -rf /Applications/EPSPreview.app" >&2
  exit 1
fi

bash "$ROOT/scripts/build.sh"
bash "$ROOT/scripts/install.sh"
