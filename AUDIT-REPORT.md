# EPS Preview — Audit Report (audit-2026-09)

Consolidated from 4 parallel read-only audits (code quality/architecture,
security, tests/CI, dependencies/hygiene). Overlapping findings are merged
with combined evidence. Severity-ordered within each topic group.

---

## CRITICAL

### T1. `bundle-ghostscript.sh` silently produces broken release binaries
**Evidence:** `scripts/bundle-ghostscript.sh:85-88` (unresolved dylib dependency
is dropped with no `else`/error — `resolve_lib`'s `find | head -1` can return
empty), `:98,103,107` (`install_name_tool … || true`, rewrite failures
discarded), `:113-114,117-118` (`cp`/`codesign … || true`), `:131` (prints
`✓ self-contained Ghostscript` unconditionally regardless of any of the above).
**Why it matters:** this script builds the Ghostscript tree shipped in every
release DMG. Every failure mode is silently swallowed, and the maintainer's
own machine (which has Homebrew, unlike an end user) can never surface the
bug. Consequence: a `.dmg` where the bundled `gs` dyld-errors or produces a
font/resource error on every user machine, while the release build log reads
clean.
**Remediation sketch:** turn the `:85-88` `if` into a hard failure on
unresolved deps; drop `|| true` from the `install_name_tool`/`codesign` calls
and check exit codes; after rewriting, assert `"$OUT/converter" --version`
succeeds *and* `otool -L` shows no remaining `$PREFIX`-rooted paths; assert
`share/Resource/Init` exists; render one committed fixture EPS through
`$OUT/converter` as the final self-test.

---

## HIGH

### T2. Ghostscript stdout/stderr pipes are drained only after the process exits → chatty EPS deadlocks the render for the full 20s and is misreported as a timeout
*(found independently by all three code-facing agents)*
**Evidence:** `Sources/RenderService/RenderService.swift:84-86` (`errorPipe`
assigned to `standardError`; `standardOutput` is a `Pipe()` whose read end is
**never read at all**), `:109` (`process.waitUntilExit()`), `:112`
(`errorPipe...readDataToEndOfFile()` — only *after* the wait).
**Why it matters:** kernel pipe buffers are ~64KB. `-dQUIET` doesn't stop
PostScript `print`/`==` from writing to stdout, and a malformed EPS produces
long stderr diagnostics on its own. Once either pipe fills, Ghostscript
blocks in `write()`, never exits, and `waitUntilExit()` blocks with it. The
20s watchdog (added in `2495710`) then fires and reports "Ghostscript timed
out" for a file that actually failed in milliseconds — the real diagnostic in
`errorData` is discarded. A 2-line malicious EPS (`{(A) print} loop`) is a
guaranteed, reproducible 20s stall and CPU/process pin per file.
**Remediation sketch:** drain both pipes concurrently (`readabilityHandler`,
or reads on a background queue) *before* `waitUntilExit()`, with a retained-
bytes cap; route stdout to `/dev/null` or `-sstdout=%stderr` since nothing
consumes it; add fixture-based tests (high-stdout EPS, high-stderr EPS)
asserting the reply is not the timeout string.

### T3. RenderService's XPC handler blocks synchronously per-request, with no concurrency cap
**Evidence:** `RenderService.swift:43,109` (`waitUntilExit()` runs inline on
whatever queue NSXPC delivered the message on; no explicit dispatch queue set
in `Sources/RenderService/main.swift:17-19`); each render also gets a fresh
`NSXPCConnection`/service instance (`Sources/Shared/RenderClient.swift:56`,
`main.swift:17-19`) with no semaphore or queue-depth limit anywhere.
**Why it matters:** a Finder folder of many EPS files in icon view fans out
many concurrent thumbnail requests. Each holds its handler for the full
render duration with no admission control — N concurrent unsandboxed
Ghostscript interpreters, each with its own 20s budget, each able to trigger
T2's stall independently. The service cannot be cancelled or drained.
**Remediation sketch:** make the handler non-blocking (`process.
terminationHandler` invokes `reply`, handler returns immediately) and gate
`renderEPSToPDF` behind a bounded `DispatchSemaphore` (2-4 concurrent) with
fast-fail past a queue-depth limit.

### T4. No client-side deadline/interruption handling — a stuck service hangs Quick Look forever
**Evidence:** `Sources/Shared/RenderClient.swift:56-79` — only
`remoteObjectProxyWithErrorHandler` is set; no `interruptionHandler`, no
`invalidationHandler`, no client-side timeout.
**Why it matters:** if the service accepts the connection and never replies
(T2/T3, or a crash between accept and reply that the proxy error handler
misses), `completion` is never invoked, the Quick Look/thumbnail callback
never fires, and the preview panel spins indefinitely; the connection also
leaks since `invalidate()` is only reachable via the one-shot finish path.
**Remediation sketch:** set `interruptionHandler`/`invalidationHandler` to
route into the existing one-shot completion, plus a client-side
`asyncAfter` deadline slightly above the service's own 20s.

### T5. XPC peer-trust check is identity-weak on three independent axes
*(security agent, findings #2/#3/#4 — three related gaps in the hardening
landed in `bd96f7c`)*
**Evidence:**
- **PID reuse:** `Sources/RenderService/main.swift:13,39` identifies the
  caller via `kSecGuestAttributePid`/`processIdentifier` — a snapshot, not a
  stable identity; the process can exit and the PID be recycled between
  connection-queueing and validation.
- **Self-relative bundle-root check, no expected-identity pin:**
  `main.swift:34,61` (`peerAppRoot == ownAppRoot`) compares the peer's bundle
  root to the *running service's own* location, and `SecCodeCheckValidity
  (peerCode, [], nil)` (`:44`) passes no requirement — any ad-hoc-signed
  binary anywhere under a copy of `EPSPreview.app` (including one an attacker
  built, since `/Applications` is admin-writable and `install.sh` strips
  quarantine tree-wide) satisfies the check. README's identity guarantee
  (`README.md:37-42`) is stronger than what the code enforces.
- **No hardened runtime / library validation:** `project.yml:25`
  (`ENABLE_HARDENED_RUNTIME: NO`), `scripts/build.sh:100` (no `-o runtime`).
  `DYLD_INSERT_LIBRARIES` against the genuine signed binary still passes
  `SecCodeCheckValidity` while the process is attacker-controlled — this
  undermines the entire peer-check premise, and costs nothing to fix (ad-hoc
  signing + hardened runtime are compatible).
**Remediation sketch:** switch to `kSecGuestAttributeAudit` (audit token, not
PID); require the peer's bundle identifier be one of the two known extensions
**and** validate against a build-time-embedded requirement (cdhash), not `[]`;
enable hardened runtime on every signed binary in `build.sh`/
`package-release.sh`.

### T6. No test target exists; `Sources/Shared` is copy-compiled into three targets instead of being a module
*(code-quality #5/#18, tests/CI M1 — same structural root cause)*
**Evidence:** `project.yml` has no `*Tests`/`bundle.unit-test` target and the
scheme (`:108-119`) has no `test:` action; `Sources/Shared` is listed as a
`sources:` path in three separate targets (`:65,82,101`) rather than a
framework, so every symbol is internal with no `@testable import` surface.
**Why it matters:** several genuinely testable, regression-prone pure
functions exist today (`wantsInterpolation`, `BundleLayout.
enclosingAppBundlePath`, the two size-cap branches in `RenderClient.render`)
and none are covered — regressions here are invisible (wrong bool → blurry
image, not a crash). This is also the blocker for testing everything else in
this report.
**Remediation sketch:** add a `bundle.unit-test` target whose own `sources:`
also lists `Sources/Shared` (compiles those files directly into the test
module, no access-level changes needed) plus a `test:` scheme action.
Extracting Shared into a real framework target additionally fixes T9 (host
app can't reuse gs-discovery code) but isn't required to start.

### T7. Host app's Ghostscript-detection ignores the bundled interpreter → false "not installed" warning on the exact install path meant to avoid it
*(found independently by code-quality #4, dependency #9, tests/CI M4)*
**Evidence:** `Sources/Host/HostApp.swift:14-17` checks only 4 hardcoded
system paths; it never checks `Contents/Helpers/gs/converter`, which
`RenderService.locateGhostscript()` (`RenderService.swift:137-167`) checks
and prefers. `project.yml:38-41` gives the `EPSPreview` host target only
`Sources/Host` — it does not compile `Sources/Shared`, so the host cannot
reuse the service's resolver even by import.
**Why it matters:** on the self-contained release DMG, the one artifact
whose "no Homebrew needed" is the entire selling point (README.md:62-63,
`package-release.sh`'s own INSTALL.txt), the host app's status window shows
an orange warning + "brew install ghostscript" while previews work
perfectly. Directly contradicts the shipped install instructions.
**Remediation sketch:** add `Sources/Shared` to the `EPSPreview` host
target's `sources:`, extract gs discovery into a shared resolver used by
both `HostApp` and `RenderService`, checking the bundled path first.

### T8. Built extension `NSExtension` metadata has two competing sources of truth with no consistency check
*(code-quality #16, tests/CI H2)*
**Evidence:** `Sources/QuickLook/Info.plist:31-49` and `Thumbnail/
Info.plist:31-48` declare the full `NSExtension` dict; `scripts/build.sh:
55-77` (`patch_extension`) then `Delete :NSExtension` and rebuilds it from a
**hardcoded** literal block (UTIs, `QLSupportsSearchableItems`,
`QLThumbnailMinimumSize`) that happens to match today.
**Why it matters:** any future edit to the source plists' `NSExtension`
block is silently deleted at build time and never reaches the shipped
bundle — the build succeeds, the change has zero effect, and nothing says so.
**Remediation sketch:** replace the hardcoded re-assertion with a
`PlistBuddy -c "Merge <source-plist>"`-style copy from the source of truth,
or add a diff assertion between built and source `NSExtension` dicts that
fails the build on divergence.

### T9. Entitlement state is never asserted after signing — the one regression that silently disables the whole product
**Evidence:** `scripts/build.sh:109-122` signs each target with specific
`--entitlements` then verifies only with `codesign --verify --deep --strict`,
which **does not check entitlement contents**. Per README:15-16,
`com.apple.security.app-sandbox` on the two extensions is mandatory — macOS
15/26 refuse to register an unsandboxed Quick Look extension at all. The
inverse is equally unguarded: the three `RenderService.xpc` copies are
signed *without* `--entitlements` on purpose (unsandboxed) with nothing
asserting they stayed that way.
**Why it matters:** an edited entitlements file, or a `project.yml`
`CODE_SIGN_ENTITLEMENTS` change, silently ships a build that either can't
register (no error, no preview, no diagnostic) or that unexpectedly
sandboxes the render helper (which then can't exec Ghostscript).
**Remediation sketch:** after signing, add `codesign -d --entitlements :-`
checks — assert `app-sandbox` present on both extensions, assert it's
*absent* on all three `RenderService.xpc` copies. Same check belongs in
`package-release.sh` after its re-seal.

### T10. Release DMG ships no license text at all — AGPL/LGPL/Apache compliance gap in the distributed artifact
**Evidence:** `scripts/package-release.sh:48-52,82-86` — the DMG stage
contains only `EPSPreview.app`, an `/Applications` symlink, and a Chinese
INSTALL.txt. Nothing copies `LICENSE` or `NOTICE.md` into the app bundle or
onto the DMG; `project.yml` has no resource-copy phase for them.
**Why it matters:** GPL/AGPL-3.0 §4-6 require conveying license text with
object code and preserving notices; LGPL and Apache-2.0 (NOTICE propagation,
§4(d)) components are also bundled (see T11). The release DMG is the one
artifact that actually triggers these obligations and is the one artifact
with zero license text — worse, `Sources/Host/Info.plist:29-30`'s
`NSHumanReadableCopyright` says "MIT-licensed" with no qualification, which
is affirmatively wrong for this bundle, not merely silent.
**Remediation sketch:** in `package-release.sh`, before the re-seal, copy
`LICENSE` + `NOTICE.md` into `Contents/Resources/`, and full third-party
license texts into a `Licenses/` folder on the mounted DMG; reword the
copyright string to reference bundled-component licensing.

### T11. `NOTICE.md` documents only Ghostscript; the release actually bundles ~21 dylibs from ~18 projects, several copyleft
**Evidence:** `scripts/bundle-ghostscript.sh:59-91` walks the *transitive*
dylib closure of the pinned `gs` build. Reproducing that walk locally
surfaces libjbig2dec (AGPL-3.0, a second Artifex-copyrighted work), libidn/
libintl (LGPL-2.1-or-later), tesseract (Apache-2.0, NOTICE propagation
required), freetype (FTL/GPLv2), plus a dozen permissive-licensed libs
(libpng, libjpeg-turbo, libtiff, openjpeg, webp, zstd, lz4, xz, etc.).
`NOTICE.md:6-27` names only Ghostscript itself.
**Why it matters:** every one of these still requires reproducing its
copyright notice in binary redistributions; the LGPL and Apache ones carry
additional obligations `NOTICE.md` doesn't address at all. This is a
compliance gap, not a version-bump — in scope for remediation.
**Remediation sketch:** extend `bundle-ghostscript.sh` to record, per
bundled dylib, owning formula + version + license, harvest each Homebrew
keg's license file into the output tree, and regenerate `NOTICE.md` as a
real third-party manifest from that data. (Bonus, separately actionable:
tesseract/leptonica/libarchive/webp/giflib exist only because Homebrew's
`gs` formula supports OCR/archive devices this app never uses — pruning them
shrinks both the license surface and the CVE surface, but needs a custom
build, so treat as a separate, larger follow-up.)

### T12. Untracked `PROBE.md` leaks internal infrastructure details and isn't gitignored
*(dependency agent #3, security agent #16 — same finding)*
**Evidence:** `PROBE.md` (created by this run's probe step) is untracked but
**not** matched by `.gitignore` (`git check-ignore -v PROBE.md` → not
ignored). Contents include internal GitLab hostnames and account names
(`gitlab.toto.io` as `iwanuschka`, `gitlab.oo.bitgrip.berlin` as
`christoph.wanja`), a note that one auth token is stored in plaintext at a
named config path, and GitHub token scopes. Tokens themselves are masked by
`gh`/`glab`, but the hostname+account+"plaintext token here" combination is
real internal-infra disclosure. `origin` is the public `iwan-uschka/
eps-preview` repo.
**Why it matters:** one careless `git add .`/`git add -A` publishes this to
a public fork. It's an audit scratch artifact with no reason to be tracked.
**Remediation sketch:** delete `PROBE.md` from the working tree (untracked,
no history rewrite needed) and add a scratch-file pattern to `.gitignore`
(e.g. `PROBE.md`, `AUDIT-REPORT.md`, `*.probe.md`) so future runs don't
repeat this. Separately (not this repo's problem to fix, but worth the
owner's attention): move the plaintext `gitlab.oo.bitgrip.berlin` token into
the OS keychain per glab's own suggestion.

---

## MEDIUM

### T13. Ghostscript discovery/candidate-path list is duplicated in 3+ places with divergent semantics, and two of the four hardcoded system paths are user-writable
*(code-quality #6, tests/CI M4, security #6)*
**Evidence:** `RenderService.swift:24-29` (4 paths, bundled-first),
`HostApp.swift:15` (same 4, no bundled check — root cause of T7),
`scripts/install.sh:15` (same 4 plus a `command -v gs` fallback the Swift
lacks). No version/integrity check on whichever system `gs` is found —
`/opt/homebrew/bin` and `/usr/local/bin` are console-user-writable under
Homebrew, so a same-uid attacker can trojan `gs` for silent, persistent code
execution inside the unsandboxed helper.
**Remediation sketch:** one shared resolver in `Sources/Shared` (see T6);
add an owner/permission check (reject non-root-owned or group/world-writable
candidates) and a minimum-version floor before trusting a system `gs`.

### T14. No sandbox/rlimit confinement on the Ghostscript child beyond `-dSAFER`
**Evidence:** `RenderService.swift:70-93` — bare `Process`, no
`sandbox_init`/`sandbox-exec`, no `RLIMIT_*`; the RenderService target has no
entitlements at all (`project.yml:96-106`).
**Why it matters:** thumbnail generation is zero-click (viewing a folder is
enough). `-dSAFER` is the sole barrier between untrusted PostScript and an
unsandboxed process with the user's full filesystem access, and it has a
repeated history of full bypasses (CVE-2023-36664, CVE-2024-29510, and
predecessors). This is architecturally the biggest single risk in the
codebase but also the most invasive to fix — flagging as medium-for-this-run
given the size of a proper fix (see deferred section) rather than because
the risk is small.
**Remediation sketch (large — likely its own branch/follow-up, not a quick
patch):** wrap the `gs` child in a `sandbox_init`/`sandbox-exec` profile
restricting it to the two temp paths + gs resource tree, deny network/exec;
add `RLIMIT_AS`/`RLIMIT_CPU`/`RLIMIT_FSIZE`/`RLIMIT_NPROC`.

### T15. No cap on Ghostscript's *output* size or on total concurrent renders
**Evidence:** `RenderService.swift:80` (`-sOutputFile=` into
`NSTemporaryDirectory()`), `:126` (`Data(contentsOf:)` reads the whole file
unconditionally) — input is capped at 100MB and time at 20s, but nothing
caps what `pdfwrite` produces. Combined with T3's lack of concurrency cap, N
simultaneous fan-out renders each with unbounded output multiplies the
exposure.
**Remediation sketch:** `RLIMIT_FSIZE` on the child (folds into T14), plus a
file-size check on the output before reading it into memory, capped well
below the input limit.

### T16. Unbounded environment handed to the Ghostscript child
**Evidence:** `RenderService.swift:139,165-167` — `ProcessInfo.processInfo.
environment` passed through with only `GS_LIB` overridden (bundled path);
system-gs path passes environment through untouched.
**Why it matters:** Ghostscript honors `GS_OPTIONS` (prepended as if on the
command line), `GS_FONTPATH`, and the dynamic loader honors `DYLD_*`. A
same-uid attacker doing `launchctl setenv GS_OPTIONS '--permit-file-write=/'`
once affects every future preview in an unsandboxed process; the explicit
`-dSAFER` flag overrides a bare `-dNOSAFER` but not `--permit-file-*`/`-I`
grants.
**Remediation sketch:** build the child's environment from scratch (`PATH`,
`TMPDIR`, `GS_LIB` only) instead of inheriting and patching.

### T17. Watchdog/timeout race: a successful render can be discarded and reported as a timeout; `kill()` targets a PID that may already be reaped
*(code-quality #15, security #12)*
**Evidence:** `RenderService.swift:95-117` — `timedOut` `Atomic` is both the
watchdog's write flag and the completion check's read; `isRunning` → `kill()`
at `:103-105` is check-then-act on a PID Foundation may have already reaped.
**Remediation sketch:** fold into T2/T3's rework — a `terminationHandler`-
driven flow makes this a single one-shot state transition instead of two
racing checks; track the child via `DispatchSourceProcess` rather than a raw
PID for signaling.

### T18. Peer-trust logic lives where it can't be unit-tested, and both sides of the bundle-path comparison lack canonicalization
*(tests/CI H5, security #15, code-quality #22 — `BundleLayout` loop bug)*
**Evidence:** `isTrustedPeer` is `private static` inside `main.swift`, which
has top-level executable code — Swift forbids linking a file with top-level
statements into a test target, so this is structurally excluded from T6's
otherwise-testable surface. Separately, `BundleLayout.
enclosingAppBundlePath` (`Sources/Shared/BundleLayout.swift:9-13`) compares
raw strings with no `resolvingSymlinksInPath()`/`standardized`, and its
`while current.path != "/"` loop never terminates on a relative URL input
(latent — current callers pass absolute URLs only).
**Why it matters:** a firmlink/symlink path variant, or any future relative-
URL caller, either fails every connection closed (denial, hard to diagnose —
symptom is indistinguishable from the "built with bare xcodebuild" case
README already warns about) or hangs.
**Remediation sketch:** extract `isTrustedPeer` into its own file so it can
be linked into a test target; normalize both paths with
`resolvingSymlinksInPath()` before comparing; bound `BundleLayout`'s walk by
`pathComponents.count` and require an absolute/file URL.

### T19. Client-side size guard is not fail-closed on unavailable file metadata
**Evidence:** `Sources/Shared/RenderClient.swift:29-35` — `try? fileURL.
resourceValues(...)`; on failure (network/FUSE volumes) the cap is silently
skipped and the full file is mapped and shipped over XPC before the
service's own re-check (`RenderService.swift:44`) rejects it.
**Remediation sketch:** treat unavailable size metadata as a refusal rather
than a skip.

### T20. `wantsInterpolation` does two full-buffer copies and has token-matching edge cases
*(code-quality #9, tests/CI H7)*
**Evidence:** `RenderClient.swift:93-106` — `String(data:encoding:
.isoLatin1)?.lowercased()` makes two full copies of up to 100MB for a
boolean; `text.range(of: "interpolate")` is an unanchored substring search
matching inside longer tokens, comments, or string literals; `hasPrefix
("true")` matches `interpolatetrue`.
**Why it matters:** the output is invisible when wrong (blurry vs. sharp
image, never an error) — the exact kind of regression that needs a test, not
a runtime check.
**Remediation sketch:** case-insensitive byte scan over `Data` directly (no
String materialization), bounded to a size-capped window; cover with unit
tests once T6 lands (no-token, explicit true/false, mixed case, token inside
a comment, binary DOS-EPS body).

### T21. XPC error channel is an untyped, unlocalized, pre-formatted string
**Evidence:** `Sources/Shared/RenderProtocol.swift:13` (`reply(Data?,
String?)`); producers at `RenderService.swift` several sites; flattened to a
single generic `NSError` code at `ThumbnailProvider.swift:14`; strings are
English while the project's only shipped UI text is Chinese
(`HostApp.swift`, `package-release.sh`'s INSTALL.txt).
**Remediation sketch:** typed error (enum/NSError domain+code) across the
XPC boundary; localize presentation strings in the extensions.

### T22. Rendered PDF geometry diverges between preview and thumbnail; multi-page PostScript truncated with no affordance
**Evidence:** `PreviewViewController.swift:61` resets `page.rotation = 0` on
every page; `ThumbnailProvider.swift:26,52` does not and draws from
`.mediaBox` while preview's `PDFView.autoScales` uses the crop box — for any
PDF with `/Rotate` or crop≠media box, Finder icon and spacebar preview
disagree. Separately, `PreviewViewController.swift:16-17`
(`.singlePage`/`displaysPageBreaks = false`) silently truncates multi-page
`.ps` files to page 1 with no indication more pages exist.
**Remediation sketch:** one shared "PDF page → drawable geometry" helper in
`Sources/Shared` used by both extensions; switch to `.singlePageContinuous`
when `pageCount > 1`.

### T23. Version argument in `package-release.sh` never reaches the shipped app's version strings
*(code-quality #17, dependency #10, tests/CI M5)*
**Evidence:** `scripts/package-release.sh:14` (`VERSION="${1:-1.0.0}"`) is
used only in the DMG filename (`:83`); all four `Info.plist`s hardcode
`CFBundleShortVersionString: 1.0.0`; `build.sh:84-96` stamps only
`CFBundleVersion` (a timestamp).
**Why it matters:** `EPSPreview-2.0.0.dmg` installs an app that reports
itself as 1.0.0 everywhere (Finder, About, crash reports) — releases aren't
identifiable from the installed artifact.
**Remediation sketch:** stamp `CFBundleShortVersionString` from `$VERSION`
in the same `PlistBuddy` loop `build.sh` already runs for `CFBundleVersion`;
validate the argument format; add `hdiutil verify` + a mount-and-check step
after DMG creation.

### T24. `install.sh`/`uninstall.sh` report success without verifying the post-conditions that actually matter
**Evidence:** `scripts/install.sh:34-41,50` — no signature verification at
the *installed* destination (different path than `build/`, and the peer
check in T5/T18 is path-sensitive), no check that PluginKit actually
registered the extensions (`open` + fixed `sleep 3`, output not inspected)
before printing `✓ Installed.`. `scripts/uninstall.sh:8-16` prints success
even as a no-op on a machine where nothing was installed, and doesn't verify
`pluginkit` actually deregistered anything.
**Remediation sketch:** `codesign --verify --deep --strict` at the installed
path; poll `pluginkit -m -i <id>` instead of a fixed sleep, downgrading the
success message when registration didn't happen; have uninstall check
`[ -d "$DEST" ]` up front and verify deregistration after.

### T25. No CI pipeline exists, though a genuinely useful one needs no paid Apple account
**Evidence:** no `.github/workflows/`; confirmed no run history. Everything
this project asserts automatically today only runs when a human executes
`build.sh` on one machine.
**Why it matters / what's actually feasible:** `xcodegen generate` + `bash
scripts/build.sh` (already asserts product existence + signature graph),
Swift availability-checking against the `MACOSX_DEPLOYMENT_TARGET: 14.0`
pin, `shellcheck` on 558 lines of bash doing `rm -rf`/`install_name_tool`,
plus T8/T9's plist/entitlement assertions and (once T6 lands) `xcodebuild
test` — all runnable on a stock `macos-15` GitHub-hosted runner with
`codesign --sign -`, no paid account needed.
**Constraint:** a job invoking `package-release.sh` would `brew install
ghostscript` and fail whenever Homebrew moves past the `10.07.1` pin — that
path should be manual/`workflow_dispatch`, not per-PR.
**Remediation sketch:** `.github/workflows/build.yml` on `macos-15` running
build.sh + the new assertions; separate `ubuntu-latest` shellcheck job.

### T26. No committed EPS/PS fixtures anywhere in the repo
**Evidence:** `git ls-files | grep -c '\.\(eps\|ps\)$'` → 0.
**Why it matters:** blocks not just automated tests but reproducible manual
verification by any contributor — including of the binary DOS-EPS-with-
preview-header case the protocol design (`RenderProtocol.swift:6-11`)
exists specifically to support.
**Remediation sketch:** commit `Tests/Fixtures/`: minimal ASCII EPS, binary
DOS-EPS with preview header, `Interpolate true`/`false` variants, a
pathological infinite-loop body (exercises T2's watchdog path), a
high-stdout EPS (exercises T2 directly). Generate the 100MB cap-boundary
input at test time rather than committing it.

### T27. `Sources/Shared` duplication forces other awkward decisions; bundle IDs and the mach service name are hardcoded string literals in 6+ places
**Evidence:** `RenderClient.swift:56`, `main.swift:8`, `ThumbnailProvider.
swift:14`, `project.yml` (multiple), four Info.plists all repeat
`com.zhangyanbo.EPSPreview...` literals.
**Why it matters:** renaming the bundle prefix compiles cleanly and fails
only at runtime as an unexplained "Render service connection failed."
**Remediation sketch:** derive from one shared constant (or `Bundle.main.
bundleIdentifier` prefix) once T6's shared module exists; assert it against
the built plist in `build.sh`.

### T28. README self-contradicts on whether Ghostscript is bundled, and the copyright/NOTICE framing has a legally ambiguous sentence
*(dependency #7/#8/#12)*
**Evidence:** `README.md:33-36` ("Ghostscript is **not** bundled") directly
contradicts `:62-63`/`:82-86` ("The release is self-contained... Ghostscript
is bundled"); the Chinese section (`:143`) repeats the unqualified claim and
never mentions the DMG path at all. Separately, `NOTICE.md:24-27`'s "the
release artifact... is covered by the AGPL-3.0" reads as a combined-work
claim where the actual shape (gs run as a separate unmodified process) is
GPLv3 §5 "mere aggregation" — the sentence is self-contradictory as written
and, read literally, could imply an AGPL grant over the Swift source.
**Remediation sketch:** qualify README's "not bundled" claim to the source-
build case; add the release/DMG path to the Chinese section; restate
NOTICE.md's framing on the aggregation basis (app code MIT; DMG additionally
aggregates unmodified third-party binaries under their own licenses) —
flagged for the owner's own read-through since this is the load-bearing
compliance paragraph, not something to auto-word.

### T29. Ghostscript dependency-closure versions are unpinned and unrecorded (distinct from the CVE-check item, which is deferred)
**Evidence:** `bundle-ghostscript.sh:19` pins only `gs` itself
(`EXPECTED_GHOSTSCRIPT_VERSION`); the 20 dylibs it bundles are resolved live
via `find ... | head -1` (`:63-67`) against whatever Homebrew has installed,
with no expected-version manifest. `GHOSTSCRIPT_PROVENANCE.txt` records
hashes but nothing diffs them against a baseline, so drift is invisible even
though it's recorded.
**Remediation sketch:** commit an expected-manifest (lib name + sha256,
generated once) and have the script diff generated provenance against it,
failing with the same "review then bump" message the version check already
uses. This is a process/tooling fix, not a version bump — in scope.

---

## LOW

- **T30.** Sending the whole file as `Data` over XPC then re-writing to a
  temp file (`RenderProtocol.swift:12-13`, `RenderService.swift:55-68`)
  forces ~5 full-size buffer copies per render; `FileHandle` (NSSecureCoding,
  preserves the TCC-avoidance rationale) would eliminate most of them.
  (`code-quality #10`)
- **T31.** Thumbnail PNGs written to temp dir are never deleted
  (`ThumbnailProvider.swift:62-71`) — unbounded growth walking large EPS
  folders; contrast with the service, which does clean up its own temp
  files. Switching to `QLThumbnailReply(contextSize:drawing:)` removes the
  file entirely. (`code-quality #11`, `security #14`)
- **T32.** Sync/async completion inconsistency in `RenderClient.render` — some
  paths return inline, others reply on the XPC queue, no documented queue
  contract; re-entrancy hazard. (`code-quality #20`)
- **T33.** `RenderClient`'s public result is an untyped `(Data?, Bool,
  String?)` tuple permitting invalid both-nil/both-set states; pairs with
  T21's typed-error fix. (`code-quality #21`)
- **T34.** Comment contradicts code at `PreviewViewController.swift:71-76`
  ("report it" sits above `handler(nil)`, which doesn't). (`code-quality #23`)
- **T35.** gs stderr decoded as UTF-8 only, falling back to "unknown error"
  on 8-bit diagnostic bytes gs commonly emits; arbitrary 600-char truncation
  constant. (`code-quality #24`)
- **T36.** Attacker-controlled gs stderr text (up to that 600-char window) is
  rendered verbatim in the trusted Quick Look panel — UI spoofing only (plain
  `NSTextField`, no markup/code execution), but file-supplied text in a
  system-drawn panel. (`security #13`)
- **T37.** Misc Swift-idiom nits: redundant optional/guard in `RenderClient.
  swift:37-45`; `Atomic` only exposes mutate-on-read `swap` with no `load`;
  pure-alias constant in `RenderService.swift:35`; class named `RenderService`
  inside module `RenderService` forcing `Self.`-qualification; gs re-resolved
  (filesystem stats) on every single request with no caching; peer-trust
  policy lives in the process entry-point file rather than its own type.
  (`code-quality #25`)
- **T38.** `SWIFT_VERSION: 5.0` forgoes all concurrency checking despite
  escaping closures crossing queues around mutable class state throughout;
  no `SWIFT_TREAT_WARNINGS_AS_ERRORS`; no `.swiftlint.yml` despite swiftlint
  being installed (its output is currently advisory-only, not a gate).
  (`code-quality #26`, `tests/CI L5`)
- **T39.** `install.sh` uses fixed `sleep 1`/`sleep 3` instead of polling for
  the observable LaunchServices/PluginKit registration condition — races on a
  loaded machine. (`code-quality #27`)
- **T40.** Minor build-script inconsistencies: redundant `set -o pipefail`,
  inconsistent step numbering (`3.5/5`, `3.6/5` inside a 1-5 sequence),
  `RenderService/Info.plist` missing `LSMinimumSystemVersion` present in the
  other three. (`code-quality #28`)
- **T41.** `refresh-thumbnails.sh` suppresses all errors including its actual
  purpose (`qlmanage -r cache`) and always prints success. (`tests/CI L1`)
- **T42.** `build.sh` checks for `xcodegen` but not for a full Xcode
  install — opaque failure on Command Line Tools-only machines.
  (`tests/CI L3`)
- **T43.** `Atomic`'s mutate-on-read `swap` semantics are load-bearing
  (completion latch, timeout flag) and unpinned by any test. (`tests/CI L4`)
- **T44.** Host app is unsandboxed for no reason
  (`Sources/Host/Host.entitlements` — empty dict, no `app-sandbox`) and
  embeds an unused third copy of the unsandboxed RenderService
  (`project.yml:53-54`, widens T5's "same bundle" surface for no benefit).
  (`security #10`)
- **T45.** `.claude/` is ignored only via the user's *global* gitignore, not
  this repo's — any other clone/CI checkout would see it as committable.
  (`dependency #11`)
- **T46.** README/clone links point at the upstream repo's releases, which
  lack this fork's own XPC/input-size hardening
  (`bd96f7c`/`2495710`) — worth being explicit about whether this fork
  publishes its own binaries. (`dependency #13`)

---

## Excluded / deferred

- **Ghostscript 10.07.1 + bundled-library CVE check** (dependency #6,
  overlaps security #6) — needs a live CVE-database lookup this run
  couldn't perform, and any resulting version bump is a deliberate,
  owner-reviewed action per the pinning script's own stated policy. Feed
  T29's recorded versions into this check separately.
- **Pruning the OCR/archive dylib closure** (tesseract, leptonica,
  libarchive, webp, giflib — pulled in by Homebrew's `gs` formula but never
  exercised by this app) — requires a custom Ghostscript build, a real
  change to the release pipeline with its own test pass.
- **`sandbox_init`/`sandbox-exec` confinement + rlimits on the Ghostscript
  child (T14)** — correctness-critical but the largest single change in this
  report; recommend its own dedicated branch with focused testing rather
  than bundling into a general hardening pass.
- **Full third-party license manifest generation (T11's complete form)** —
  the narrow slice (ship existing LICENSE/NOTICE.md in the DMG, T10) is
  single-run sized; per-formula license harvesting into a generated
  manifest is a larger, separate lift.
- **Legal sign-off on the AGPL aggregation-vs-combined-work wording (T28)** —
  flagged and a correct direction proposed; final wording is the owner's call,
  not an automated fix.
- **Notarization / Developer ID signing / removing "Open Anyway"** — requires
  a paid Apple Developer Program membership; explicitly out of scope
  (README already documents this tradeoff).
- **End-to-end Quick Look/Finder integration test** (select file, press
  Space, assert rendered pixels) — needs a live logged-in GUI session with
  Accessibility/Automation TCC grants; not automatable in CI. Keep as a
  documented manual pre-release checklist instead.
- **Negative XPC peer-rejection test** (a second, separately-signed fixture
  app attempting a connection and being refused) — locally feasible but not
  a single-run deliverable; T18's extraction + unit tests for `BundleLayout`
  capture the tractable portion.
- **macOS 26 (Tahoe) CI coverage** — the README's central claims are
  version-specific but hosted runner images for the newest macOS typically
  lag; T25's CI matrix is limited to whatever GitHub actually offers.
- **The TCC-protected-location invariant** (service never resolves a path
  outside `/tmp`, by design) — cannot be tested without a real user TCC
  grant on a real account; recommend guarding it with an explicit
  "DO NOT change to a path-based API" comment plus an `AGENTS.md` note,
  since no automated test can protect it.
