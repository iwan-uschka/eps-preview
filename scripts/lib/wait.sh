# shellcheck shell=bash
# Polling helper shared by scripts/install.sh and scripts/uninstall.sh.
#
# Sourced, never executed — hence no shebang and no executable bit.
#
#   . "$ROOT/scripts/lib/wait.sh"
#   wait_until 10 some_predicate arg… || echo "timed out"

# Poll for an observable condition instead of guessing a sleep duration —
# LaunchServices/PluginKit take arbitrarily long on a loaded machine.
#
# Usage: wait_until <timeout-seconds> <command> [args…]
# Re-runs <command> every quarter second until it succeeds (returns 0) or
# <timeout-seconds> have passed (returns 1).
wait_until() {
  local timeout="$1"; shift
  local waited=0
  while ! "$@"; do
    [ "$waited" -lt "$((timeout * 4))" ] || return 1
    sleep 0.25
    waited=$((waited + 1))
  done
}
