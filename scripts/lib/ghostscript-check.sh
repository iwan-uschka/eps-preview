# shellcheck shell=bash
# Decides whether a system Ghostscript is usable, for the installer.
#
# Sourced, never executed — hence no shebang and no executable bit.
#
# This file MUST stay in lockstep with Sources/Shared/GhostscriptLocator.swift:
# the same candidate paths in the same order, the same ownership/permission
# vetting, the same 9.50 floor and the same version-string parsing. The
# installer is the only place a user is told whether Ghostscript is "found",
# and the render service is the only place that decides whether to run it. If
# the two disagree, install.sh prints a green check for a `gs` that every
# preview will then refuse — which is exactly what it used to do, by testing
# `-x` on three paths and falling back to `command -v gs`. Change one side and
# you must change the other; scripts/test-ghostscript-check.sh pins this side.
#
# macOS-only, like the rest of scripts/: it relies on BSD `stat -f`, and on
# `readlink -f` (macOS 12.3+; this project targets macOS 14+). Written for the
# bash 3.2 that macOS ships — no associative arrays, no `mapfile`, no `${x,,}`.
#
# Sourceable from a `set -euo pipefail` script:
#
#   . "$ROOT/scripts/lib/ghostscript-check.sh"
#   if gs_path="$(eps_gs_find)"; then echo "$gs_path"; fi
#
# `eps_gs_find` prints the accepted path on stdout and returns 0, or returns 1
# and prints one "why not" line per existing-but-rejected candidate on stderr.

if [ -n "${_EPS_GS_CHECK_SH:-}" ]; then
  return 0
fi
_EPS_GS_CHECK_SH=1

# Mirrors GhostscriptLocator.systemCandidates — order included: Apple-silicon
# Homebrew, Intel Homebrew, MacPorts, /usr/bin. PATH is deliberately not
# searched, there and here: the service will never run a `gs` found that way,
# so the installer must not report one.
EPS_GS_DEFAULT_CANDIDATES="/opt/homebrew/bin/gs /usr/local/bin/gs /opt/local/bin/gs /usr/bin/gs"

# Mirrors GhostscriptLocator.minimumSystemVersion. 9.50 is where -dSAFER
# became the enforced default.
EPS_GS_MINIMUM_MAJOR=9
EPS_GS_MINIMUM_MINOR=50

# Mirrors GhostscriptLocator.versionProbeTimeout (seconds).
EPS_GS_DEFAULT_PROBE_TIMEOUT=5

# Resolves every symlink in the path, like Foundation's
# resolvingSymlinksInPath(): vetting has to look at the file that will really
# be executed, not at a symlink whose mode bits say nothing.
_eps_gs_resolve() {
  readlink -f "$1" 2>/dev/null || printf '%s\n' "$1"
}

# Parses one version field the way Swift's `Int(_:)` does — an optional sign
# followed by digits, nothing else (no whitespace, no partial parse). Prints
# the value, or returns 1 if the field is not an integer, which is how
# `compactMap { Int($0) }` drops it.
_eps_gs_to_int() {
  local raw="$1" sign=1 digits
  case "$raw" in
    -*) sign=-1; digits="${raw#-}" ;;
    +*) digits="${raw#+}" ;;
    *)  digits="$raw" ;;
  esac
  case "$digits" in
    '' | *[!0-9]*) return 1 ;;
  esac
  # 10# so a zero-padded field like "02" is read as decimal 2, not as octal.
  printf '%d\n' "$(( sign * 10#$digits ))"
}

# Mirrors GhostscriptLocator.versionString(_:meetsMinimum:) exactly, including
# its edge cases: the text is split on ".", non-integer fields are dropped,
# fewer than two surviving fields is a rejection (so a bare "10" and "abc" are
# both refused rather than guessed at), and the minor field is compared as
# printed — "9.5" is minor 5, i.e. *below* the 9.50 floor.
eps_gs_version_meets_minimum() {
  local text="$1" field value count=0 major=0 minor=0

  # Word-splitting on "." is the split(separator:) equivalent; empty fields
  # fail _eps_gs_to_int and are skipped, as omittingEmptySubsequences does.
  local IFS=.
  # shellcheck disable=SC2086 # unquoted on purpose: this *is* the split
  set -- $text
  unset IFS

  for field in "$@"; do
    value="$(_eps_gs_to_int "$field")" || continue
    count=$(( count + 1 ))
    if [ "$count" -eq 1 ]; then
      major="$value"
    else
      minor="$value"
      break
    fi
  done

  [ "$count" -ge 2 ] || return 1
  if [ "$major" -ne "$EPS_GS_MINIMUM_MAJOR" ]; then
    [ "$major" -gt "$EPS_GS_MINIMUM_MAJOR" ]
    return
  fi
  [ "$minor" -ge "$EPS_GS_MINIMUM_MINOR" ]
}

# Mirrors GhostscriptLocator.isWritableOnlyByOwner: the file must be owned by
# root or by us, and must not be group- or world-writable. Anything else could
# be swapped out by another unprivileged account between this check and the
# render. BSD `stat -f`: %u is the owner's uid, %p the mode including the
# file-type bits (masking with 022 ignores those).
_eps_gs_writable_only_by_owner() {
  local info owner mode
  info="$(stat -f '%u %p' "$1" 2>/dev/null)" || return 1
  owner="${info%% *}"
  mode="${info##* }"
  case "$owner" in '' | *[!0-9]*) return 1 ;; esac
  case "$mode" in '' | *[!0-7]*) return 1 ;; esac
  if [ "$owner" -ne 0 ] && [ "$owner" -ne "$(id -u)" ]; then
    return 1
  fi
  [ $(( 8#$mode & 8#22 )) -eq 0 ]
}

# Runs `gs --version` under a time bound and prints its first line, trimmed.
# Returns 1 if the binary cannot be run, exits non-zero, prints nothing, or
# does not answer in time — all of which GhostscriptLocator.probeVersion()
# also treats as "no version".
#
# macOS ships no timeout(1) and bash 3.2 has no `wait -n`, so the bound is a
# watchdog subshell that signals the child directly. That shape is preferred
# over `perl -e 'alarm …'` because the pid we start is the pid we kill: the
# interpreter is gone when this returns rather than orphaned, and `wait` still
# reports its real exit status. Polling `kill -0` in a loop would not work at
# all here — a finished background child stays visible to `kill -0` as a
# zombie until it is reaped.
eps_gs_probe_version() {
  local path="$1" timeout="${EPS_GS_PROBE_TIMEOUT:-$EPS_GS_DEFAULT_PROBE_TIMEOUT}"
  local out pid watchdog status=0 line

  out="$(mktemp "${TMPDIR:-/tmp}/eps-gs-version.XXXXXX")" || return 1

  # Same scratch environment the service gives Ghostscript
  # (GhostscriptLocator.childEnvironment): nothing inherited, so a GS_OPTIONS
  # or DYLD_* set once cannot steer the probe.
  env -i PATH=/usr/bin:/bin TMPDIR="${TMPDIR:-/tmp}" "$path" --version >"$out" 2>/dev/null &
  pid=$!
  ( sleep "$timeout"
    kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  watchdog=$!

  wait "$pid" 2>/dev/null || status=$?
  kill -TERM "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  line="$(head -n 1 "$out" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" || line=""
  rm -f "$out"

  [ "$status" -eq 0 ] || return 1
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}

# Prints the first acceptable Ghostscript and returns 0; returns 1 if none of
# the candidates is usable. Candidates come from EPS_GS_CANDIDATES
# (space-separated) when set — including when set to the empty string, which
# means "no candidates" — otherwise from EPS_GS_DEFAULT_CANDIDATES.
#
# Rejection reasons for candidates that exist but did not qualify go to
# stderr, so the caller can tell the user *why* nothing was accepted without
# re-running the probes.
eps_gs_find() {
  local candidates="${EPS_GS_CANDIDATES-$EPS_GS_DEFAULT_CANDIDATES}"
  local timeout="${EPS_GS_PROBE_TIMEOUT:-$EPS_GS_DEFAULT_PROBE_TIMEOUT}"
  local path resolved parent reason version rejections=""

  # shellcheck disable=SC2086 # space-separated list, split on purpose
  set -- $candidates
  for path in "$@"; do
    # isExecutableFile(atPath:) equivalent — a missing candidate is simply the
    # next one's turn, and is not worth a reason line.
    [ -f "$path" ] && [ -x "$path" ] || continue

    resolved="$(_eps_gs_resolve "$path")"
    parent="$(dirname "$resolved")"
    if ! _eps_gs_writable_only_by_owner "$resolved"; then
      if [ "$resolved" = "$path" ]; then
        reason="group/world-writable, or owned by another user"
      else
        # Worth naming: the candidate itself can look fine and still point at
        # a file anyone may rewrite.
        reason="resolves to $resolved, which is group/world-writable, or owned by another user"
      fi
    elif ! _eps_gs_writable_only_by_owner "$parent"; then
      reason="its directory $parent is group/world-writable, or owned by another user"
    elif ! version="$(eps_gs_probe_version "$path")"; then
      reason="did not answer --version within ${timeout} s, or exited non-zero"
    elif ! eps_gs_version_meets_minimum "$version"; then
      reason="version $version is below ${EPS_GS_MINIMUM_MAJOR}.${EPS_GS_MINIMUM_MINOR}"
    else
      printf '%s\n' "$path"
      return 0
    fi
    rejections="${rejections}  ✗ ${path}: ${reason}
"
  done

  [ -z "$rejections" ] || printf '%s' "$rejections" >&2
  return 1
}
