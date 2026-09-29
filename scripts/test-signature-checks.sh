#!/usr/bin/env bash
# Pins scripts/lib/signature-checks.sh — build.sh's and package-release.sh's
# post-signing assertions — against throwaway copies of /bin/sleep, re-signed
# ad hoc by the real codesign with and without the sandbox entitlement and the
# hardened runtime. Each helper `exit 1`s on failure, so every case runs it in
# a subshell. Needs macOS (codesign, PlistBuddy).
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/eps-signature-checks-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

# check <helper> <args…>: runs one helper from the library in a subshell,
# leaving its exit status in RC and its combined output in OUT.
check() {
  OUT=""
  RC=0
  # shellcheck source=lib/signature-checks.sh disable=SC1091
  OUT="$( . "$ROOT/scripts/lib/signature-checks.sh"; "$@" 2>&1 )" || RC=$?
}

# signed <name> [codesign options…]: a copy of /bin/sleep at $WORK/<name>,
# re-signed ad hoc with the given options.
signed() {
  local path="$WORK/$1"; shift
  cp /bin/sleep "$path"
  codesign --force --sign - "$@" "$path" >/dev/null 2>&1 \
    || { echo "error: could not sign fixture $path" >&2; exit 1; }
  printf '%s\n' "$path"
}

SANDBOX_ENTS="$WORK/sandbox.entitlements"
cat > "$SANDBOX_ENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.app-sandbox</key>
  <true/>
</dict>
</plist>
PLIST

SANDBOXED="$(signed sandboxed --entitlements "$SANDBOX_ENTS")"
PLAIN="$(signed plain)"
HARDENED="$(signed hardened --options runtime)"
# `signed` runs in a command substitution, so its exit only ends that.
[ -n "$SANDBOXED" ] && [ -n "$PLAIN" ] && [ -n "$HARDENED" ] || exit 1
UNSIGNED="$WORK/unsigned"
printf 'not code\n' > "$UNSIGNED"
MISSING="$WORK/no-such-bundle.app"

OUT=""
RC=0

# --- assert_sandbox_state -------------------------------------------------
check assert_sandbox_state true "$SANDBOXED"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "assert_sandbox_state true passes quietly on a sandboxed binary"
else
  fail "assert_sandbox_state true on a sandboxed binary" "rc=$RC out=$OUT"
fi

check assert_sandbox_state absent "$PLAIN"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "assert_sandbox_state absent passes quietly on a binary without entitlements"
else
  fail "assert_sandbox_state absent on a binary without entitlements" "rc=$RC out=$OUT"
fi

# breaks-if: the `[ -e "$path" ]` guard is removed, so a missing bundle reads as `absent` and passes
check assert_sandbox_state absent "$MISSING"
if [ "$RC" -eq 1 ] && [[ "$OUT" == "error: no bundle at $MISSING" ]]; then
  pass "assert_sandbox_state refuses a missing bundle instead of reading it as absent"
else
  fail "assert_sandbox_state refuses a missing bundle" "rc=$RC out=$OUT"
fi

# An existing file with no signature has no entitlements either, so it reads as
# `absent` on purpose: the `|| true` / `|| state="absent"` fallbacks are intended.
# breaks-if: a failing `codesign -d` on an existing unsigned file stops reading as `absent` (fallback removed or turned into an error)
check assert_sandbox_state absent "$UNSIGNED"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "assert_sandbox_state absent passes on an existing file with no signature"
else
  fail "assert_sandbox_state absent on an unsigned file" "rc=$RC out=$OUT"
fi

# breaks-if: the final `[ "$state" = "$want" ]` comparison stops failing (e.g. loses its exit 1)
check assert_sandbox_state true "$PLAIN"
if [ "$RC" -eq 1 ] \
   && [[ "$OUT" == "error: com.apple.security.app-sandbox is 'absent' on $PLAIN (expected 'true')" ]]; then
  pass "assert_sandbox_state true fails naming the absent state on an unsandboxed binary"
else
  fail "assert_sandbox_state true on an unsandboxed binary" "rc=$RC out=$OUT"
fi

# The other direction: a sandboxed RenderService could not exec Ghostscript.
# breaks-if: assert_sandbox_state only checks for a missing sandbox, not an unexpected one
check assert_sandbox_state absent "$SANDBOXED"
if [ "$RC" -eq 1 ] \
   && [[ "$OUT" == "error: com.apple.security.app-sandbox is 'true' on $SANDBOXED (expected 'absent')" ]]; then
  pass "assert_sandbox_state absent fails on a sandboxed binary"
else
  fail "assert_sandbox_state absent on a sandboxed binary" "rc=$RC out=$OUT"
fi

# --- assert_hardened_runtime ----------------------------------------------
check assert_hardened_runtime "$HARDENED"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  pass "assert_hardened_runtime passes quietly on a runtime-signed binary"
else
  fail "assert_hardened_runtime on a runtime-signed binary" "rc=$RC out=$OUT"
fi

# breaks-if: a failing `codesign -dv` is no longer reported (its `|| { … exit 1; }` is dropped)
check assert_hardened_runtime "$UNSIGNED"
if [ "$RC" -eq 1 ] && [[ "$OUT" == "error: cannot read code signature of $UNSIGNED" ]]; then
  pass "assert_hardened_runtime fails when codesign cannot read a signature"
else
  fail "assert_hardened_runtime on an unsigned file" "rc=$RC out=$OUT"
fi

# breaks-if: the flags=…runtime match is loosened or its failure branch loses its exit 1
check assert_hardened_runtime "$PLAIN"
if [ "$RC" -eq 1 ] && [[ "$OUT" == "error: hardened runtime flag missing on $PLAIN" ]]; then
  pass "assert_hardened_runtime fails on a binary signed without the hardened runtime"
else
  fail "assert_hardened_runtime without the hardened runtime" "rc=$RC out=$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
