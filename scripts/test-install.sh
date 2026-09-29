#!/usr/bin/env bash
# Pins scripts/install.sh's and scripts/uninstall.sh's own failure paths:
# install.sh stopping before anything destructive when the build is missing,
# an extension lacks its embedded RenderService.xpc or the build-tree
# signature is invalid; dropping (not installing) a staged copy whose
# signature is invalid; and both scripts treating a failing `pluginkit` as
# "not registered" / "not gone" rather than as success.
#
# Both scripts hardcode /Applications/EPSPreview.app and lsregister's system
# path, so each case runs a throwaway copy of them with those two lines (and
# the polling timeouts, down to 0 s) rewritten by sed — the technique
# scripts/test-check-bundle-identifiers.sh uses — against a fake Applications
# directory and a fake $HOME. Every other command with an effect outside
# $WORK (codesign, pluginkit, killall, osascript, open, qlmanage, pgrep,
# brew, xattr) is a PATH stub. The rewrite is checked before anything runs,
# so a changed DEST line aborts the suite instead of touching /Applications.
set -uo pipefail
# No `set -e`: a failing assertion must be counted and reported, not abort
# the run.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Normalized through `cd && pwd`, as install.sh does for its own ROOT: a
# trailing slash on $TMPDIR would otherwise leave `//` in every path here and
# none in the ones the scripts compute, and the codesign stub matches exactly.
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/eps-install-test.XXXXXX")" && pwd)"
trap 'rm -rf "$WORK"' EXIT INT TERM

PASSED=0
FAILED=0

pass() { PASSED=$(( PASSED + 1 )); printf 'PASS  %s\n' "$1"; }
fail() { FAILED=$(( FAILED + 1 )); printf 'FAIL  %s — %s\n' "$1" "$2"; }

APPS="$WORK/Applications"
DEST="$APPS/EPSPreview.app"
FAKE_HOME="$WORK/home"
STUB="$WORK/stub"
LOG="$WORK/calls.log"
mkdir -p "$STUB" "$APPS" "$FAKE_HOME"

# --- throwaway copies of the scripts ---------------------------------------
FAKE_ROOT="$WORK/root"
mkdir -p "$FAKE_ROOT/scripts/lib"
cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$FAKE_ROOT/scripts/"
cp "$ROOT/scripts/lib/"*.sh "$FAKE_ROOT/scripts/lib/"
for script in install.sh uninstall.sh; do
  f="$FAKE_ROOT/scripts/$script"
  sed -i '' \
    -e "s#^DEST=\"/Applications/EPSPreview.app\"\$#DEST=\"$DEST\"#" \
    -e "s#^LSREGISTER=.*#LSREGISTER=\"$STUB/lsregister\"#" \
    -e 's#wait_until [0-9][0-9]* #wait_until 0 #' \
    "$f"
  if ! grep -qxF "DEST=\"$DEST\"" "$f" || ! grep -qxF "LSREGISTER=\"$STUB/lsregister\"" "$f" \
     || grep -q '^DEST="/Applications' "$f"; then
    echo "error: could not redirect DEST/LSREGISTER in the copy of $script — refusing to run it" >&2
    exit 1
  fi
done
APP="$FAKE_ROOT/build/Build/Products/Release/EPSPreview.app"

# --- PATH stubs ------------------------------------------------------------
# Each records its name and arguments. codesign fails for any path matching
# the glob in $CODESIGN_FAIL_ON. pluginkit answers per $PLUGINKIT_MODE:
#   listed        — prints a match, exits 0
#   none          — prints nothing, exits 0 (PluginKit's "no match")
#   placeholder   — prints "(no matches)", exits 0
#   fail-noisy    — prints a match, exits 1
#   fail-silent   — prints nothing, exits 1
for tool in killall osascript open qlmanage brew xattr lsregister; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 0\n' "$tool" "$LOG" > "$STUB/$tool"
done
printf '#!/bin/sh\nexit 1\n' > "$STUB/pgrep"   # no EPS Preview processes running
cat > "$STUB/codesign" <<EOF
#!/bin/sh
echo "codesign \$*" >> "$LOG"
for last; do :; done
case "\$last" in \${CODESIGN_FAIL_ON:-/nothing/matches/this}) exit 1 ;; esac
exit 0
EOF
cat > "$STUB/pluginkit" <<EOF
#!/bin/sh
echo "pluginkit \$*" >> "$LOG"
case "\${PLUGINKIT_MODE:-listed}" in
  listed)      echo "     com.zhangyanbo.EPSPreview.QuickLook(1.0)"; exit 0 ;;
  none)        exit 0 ;;
  placeholder) echo "(no matches)"; exit 0 ;;
  fail-noisy)  echo "     com.zhangyanbo.EPSPreview.QuickLook(1.0)"; exit 1 ;;
  fail-silent) exit 1 ;;
esac
EOF
chmod 0755 "$STUB"/*

# --- fixtures and runners --------------------------------------------------
# make_app <path> <marker> [appex-without-service]: a fake bundle with both
# extensions and their embedded RenderService.xpc, except for the named one.
make_app() {
  local path="$1" marker="$2" skip="${3:-}" appex
  rm -rf "$path"
  mkdir -p "$path/Contents/MacOS"
  printf '%s\n' "$marker" > "$path/Contents/marker"
  for appex in EPSQuickLook.appex EPSThumbnail.appex; do
    mkdir -p "$path/Contents/PlugIns/$appex/Contents"
    [ "$appex" = "$skip" ] || mkdir -p "$path/Contents/PlugIns/$appex/Contents/XPCServices/RenderService.xpc"
  done
}

# run <script> [VAR=value…]: runs the throwaway copy with the stubs first on
# PATH, no Ghostscript candidates (so the Homebrew branch runs against the
# brew stub) and the fake $HOME; RC and OUT hold the result, LOG the calls.
run() {
  local script="$1"; shift
  rm -f "$LOG"
  OUT=""
  RC=0
  OUT="$(env PATH="$STUB:$PATH" HOME="$FAKE_HOME" EPS_GS_CANDIDATES="" "$@" \
    bash "$FAKE_ROOT/scripts/$script" 2>&1)" || RC=$?
}

marker() { cat "$1/Contents/marker" 2>/dev/null; }
called() { grep -q "^$1 " "$LOG" 2>/dev/null; }

OUT=""
RC=0

# --- install.sh: refusals before anything destructive ----------------------
rm -rf "$FAKE_ROOT/build"
make_app "$DEST" old
# breaks-if: install.sh's `[ -d "$APP" ]` not-built guard is removed
run install.sh
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"error: not built yet. Run: bash scripts/build.sh"* ]] \
   && ! called codesign && [ "$(marker "$DEST")" = old ]; then
  pass "install.sh refuses to run without a build, before any signature check"
else
  fail "install.sh refuses to run without a build" "rc=$RC out=$OUT"
fi

for appex in EPSQuickLook.appex EPSThumbnail.appex; do
  make_app "$APP" new "$appex"
  # breaks-if: assert_embedded_service loses its `exit 1`, or its call for this extension is dropped
  run install.sh
  if [ "$RC" -eq 1 ] && [[ "$OUT" == *"error: $appex is missing its embedded RenderService.xpc."* ]] \
     && ! called codesign && ! called killall && [ "$(marker "$DEST")" = old ]; then
    pass "install.sh refuses a build whose $appex has no embedded RenderService.xpc"
  else
    fail "install.sh refuses a build whose $appex has no embedded RenderService.xpc" "rc=$RC out=$OUT"
  fi
done

make_app "$APP" new
# breaks-if: the build-tree `codesign --verify` check is dropped or moved after the processes are killed / the bundle is copied
run install.sh CODESIGN_FAIL_ON="$APP"
if [ "$RC" -eq 1 ] && [[ "$OUT" == *"error: signature invalid at $APP"* ]] \
   && ! called killall && ! called lsregister \
   && [ ! -e "$DEST.installing" ] && [ "$(marker "$DEST")" = old ]; then
  pass "install.sh refuses an invalidly signed build before quitting, copying or replacing anything"
else
  fail "install.sh refuses an invalidly signed build" "rc=$RC out=$OUT calls=$(tr '\n' '|' < "$LOG" 2>/dev/null)"
fi

# breaks-if: the staged-copy `codesign --verify` is dropped, or its failure branch stops removing $TMP_DEST
run install.sh CODESIGN_FAIL_ON="$DEST.installing"
if [ "$RC" -eq 1 ] \
   && [[ "$OUT" == *"error: signature invalid in the copy made for $DEST"* ]] \
   && [ ! -e "$DEST.installing" ] && [ "$(marker "$DEST")" = old ] && ! called open; then
  pass "install.sh drops a staged copy with an invalid signature and keeps the old install"
else
  fail "install.sh drops a staged copy with an invalid signature" "rc=$RC out=$OUT"
fi

# --- install.sh: happy path and repetition ---------------------------------
run install.sh PLUGINKIT_MODE=listed
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"✓ Installed."* ]] && [ "$(marker "$DEST")" = new ] \
   && [ ! -e "$DEST.installing" ] && called brew \
   && [ "$(grep -c 'reported by pluginkit' <<<"$OUT")" -eq 2 ]; then
  pass "install.sh replaces the old install and reports both extensions registered"
else
  fail "install.sh happy path" "rc=$RC out=$OUT"
fi

# Running it again over its own install must replace, not nest, the bundle.
run install.sh PLUGINKIT_MODE=listed
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"✓ Installed."* ]] && [ "$(marker "$DEST")" = new ] \
   && [ ! -e "$DEST/EPSPreview.app" ] && [ ! -e "$DEST.installing" ]; then
  pass "install.sh run twice leaves one bundle, not one nested in the other"
else
  fail "install.sh run twice" "rc=$RC out=$OUT"
fi

# --- install.sh: what counts as registered ---------------------------------
# breaks-if: extension_registered drops `|| return 1` and trusts output from a failing pluginkit
run install.sh PLUGINKIT_MODE=fail-noisy
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"⚠️  Installed, but macOS has not registered the extensions yet."* ]] \
   && [ "$(grep -c 'not reported by pluginkit' <<<"$OUT")" -eq 2 ] && [[ "$OUT" != *"✓ Installed."* ]]; then
  pass "install.sh does not count a failing pluginkit as registered"
else
  fail "install.sh with a failing pluginkit" "rc=$RC out=$OUT"
fi

for mode in none placeholder; do
  # breaks-if: extension_registered stops rejecting empty output or the "(no matches)" placeholder
  run install.sh PLUGINKIT_MODE="$mode"
  if [ "$RC" -eq 0 ] && [[ "$OUT" == *"⚠️  Installed, but macOS has not registered the extensions yet."* ]]; then
    pass "install.sh does not count pluginkit's '$mode' answer as registered"
  else
    fail "install.sh with pluginkit answering '$mode'" "rc=$RC out=$OUT"
  fi
done

# --- uninstall.sh ----------------------------------------------------------
CONTAINER="$FAKE_HOME/Library/Containers/com.zhangyanbo.EPSPreview.QuickLook"

make_app "$DEST" installed
mkdir -p "$CONTAINER"
run uninstall.sh PLUGINKIT_MODE=none
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"✓ EPS Preview uninstalled."* ]] \
   && [ ! -e "$DEST" ] && [ ! -e "$CONTAINER" ]; then
  pass "uninstall.sh removes the bundle and its containers and reports success"
else
  fail "uninstall.sh happy path" "rc=$RC out=$OUT"
fi

# Idempotent: a second run, with the bundle already gone, still cleans up.
mkdir -p "$CONTAINER"
run uninstall.sh PLUGINKIT_MODE=none
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"note: $DEST not found — cleaning up any leftovers."* ]] \
   && [[ "$OUT" == *"✓ EPS Preview uninstalled."* ]] && [ ! -e "$CONTAINER" ]; then
  pass "uninstall.sh run again without a bundle still cleans up and succeeds"
else
  fail "uninstall.sh run again without a bundle" "rc=$RC out=$OUT"
fi

# breaks-if: extension_gone drops `|| return 1` and reads a failing pluginkit's empty output as "gone"
make_app "$DEST" installed
run uninstall.sh PLUGINKIT_MODE=fail-silent
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"⚠️  EPS Preview removed, but PluginKit still lists an extension."* ]] \
   && [ "$(grep -c 'is still registered with PluginKit' <<<"$OUT")" -eq 2 ] \
   && [[ "$OUT" != *"✓ EPS Preview uninstalled."* ]]; then
  pass "uninstall.sh does not count a failing pluginkit as deregistered"
else
  fail "uninstall.sh with a failing pluginkit" "rc=$RC out=$OUT"
fi

# breaks-if: extension_gone treats any non-empty output, the "(no matches)" placeholder included, as still registered
run uninstall.sh PLUGINKIT_MODE=placeholder
if [ "$RC" -eq 0 ] && [[ "$OUT" == *"✓ EPS Preview uninstalled."* ]]; then
  pass "uninstall.sh reads pluginkit's '(no matches)' placeholder as deregistered"
else
  fail "uninstall.sh with pluginkit's '(no matches)' placeholder" "rc=$RC out=$OUT"
fi

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ]
