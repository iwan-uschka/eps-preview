# shellcheck shell=bash
# Post-signing assertions shared by scripts/build.sh and
# scripts/package-release.sh, so a fix to either check (e.g. for a change in
# codesign's output format) lands in both.
#
# Sourced, never executed — hence no shebang and no executable bit.
#
# Both helpers stay quiet on success and `exit 1` (ending the sourcing script)
# with an `error:` line on failure; callers print their own ✓ lines.
#
#   . "$ROOT/scripts/lib/signature-checks.sh"
#   assert_sandbox_state true "$APP"
#   assert_hardened_runtime "$APP"

# --verify says nothing about entitlement *contents*, and the sandbox state is
# load-bearing in both directions: macOS 15/26 refuse to register an
# unsandboxed Quick Look extension at all, while a sandboxed RenderService
# could not exec Ghostscript.
#
# Usage: assert_sandbox_state <true|absent> <bundle-path>
assert_sandbox_state() {
  local want="$1" path="$2" ents state
  # Without this, a missing bundle reads as `absent`: codesign fails, leaves a
  # 0-byte file, PlistBuddy exits 1 on it and the `|| state="absent"` fallback
  # below turns that into a *pass*. Every `absent` assertion would then hold
  # vacuously for a path the build forgot to produce.
  [ -e "$path" ] || { echo "error: no bundle at $path"; exit 1; }
  ents="$(mktemp)"
  codesign -d --entitlements :- --xml "$path" >"$ents" 2>/dev/null || true
  state="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ents" 2>/dev/null)" \
    || state="absent"
  rm -f "$ents"
  [ "$state" = "$want" ] || {
    echo "error: com.apple.security.app-sandbox is '$state' on $path (expected '$want')"
    exit 1; }
}

# The hardened runtime is load-bearing for the render service's peer check (a
# validated peer binary must not be hijackable in-process via
# DYLD_INSERT_LIBRARIES), and --verify doesn't report it either. Output is
# captured first rather than piped into `grep -q`, which under pipefail could
# fail the check through codesign's SIGPIPE instead of a missing flag.
#
# Usage: assert_hardened_runtime <bundle-path>
assert_hardened_runtime() {
  local path="$1" info
  info="$(codesign -dv "$path" 2>&1)" || {
    echo "error: cannot read code signature of $path"; exit 1; }
  [[ "$info" =~ flags=[^$'\n']*runtime ]] || {
    echo "error: hardened runtime flag missing on $path"; exit 1; }
}
