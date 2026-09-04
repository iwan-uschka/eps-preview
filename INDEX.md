# audit-2026-09 — Index

Phase: execute

This branch is the run's status board. It never merges into `main`.

## Run metadata

- Started: 2026-09-04
- Repo: `iwan-uschka/eps-preview` (github.com), fork of `Zhangyanbo/eps-preview`
- Review mode: **delegated** would normally apply (sandbox probe passed), but
  **overridden by explicit owner instruction this run**: branch agents do
  NOT run the review-branch self-review pipeline. See "Execution protocol"
  below.
- Scope: all 47 findings from `AUDIT-REPORT.md` (owner selected "everything
  incl. Low").
- Node/toolchain: N/A — Swift/macOS app (XcodeGen + xcodebuild), no node
  tooling involved. See `PROBE.md`.

## Execution protocol (owner-directed override of the skill's default)

Per explicit owner instruction on 2026-09-04, this run's branch agents:

1. Implement their scope.
2. Run the repo's verification commands (`bash scripts/build.sh`, plus any
   scope-specific checks — see `BRIEFING.md`).
3. Commit locally on their branch.
4. **Stop.** No self-review pipeline (review-branch), no `git push`, no MR
   creation of any kind.

The owner reviews and pushes/MRs each branch themselves, on their own
schedule. This is a stricter subset of the plan-approval authorization in
`BRIEFING.md`/SKILL.md — plan approval on 2026-09-04 authorizes commits on
`audit-2026-09/*` branches; it does **not** authorize push or MR creation
this run. The index branch itself (this branch) is the one exception — it
is created and pushed now, as a status board, per separate explicit owner
confirmation.

## Deferred to Phase-4 issues (not branches this run)

- **T14** — sandbox-exec/rlimit confinement on the Ghostscript child process.
  Owner decision (2026-09-04): too large / high regression risk to bundle
  into this run; defer to a dedicated follow-up issue after the
  render-service branches land and prove stable.
- Ghostscript + bundled-library CVE check (needs live CVE lookup)
- Pruning the unused OCR/archive dylib closure (tesseract, leptonica, etc.)
- Full third-party license manifest generation (beyond the narrow
  ship-LICENSE-in-DMG slice in `docs-and-license-compliance`)
- Legal sign-off on NOTICE.md's AGPL aggregation wording
- Notarization / Developer ID signing
- End-to-end Quick Look/Finder GUI integration test
- Negative XPC peer-rejection test (needs a second signed fixture app)
- macOS 26 (Tahoe) CI coverage
- TCC-protected-location invariant — document-only, not testable

## Branch table

| Branch | Base | Scope (finding IDs) | Status |
|---|---|---|---|
| `audit-2026-09/render-service-01-hardening` | `main` | T2,T3,T4,T13,T15,T16,T17,T35,T37 | **done** (local commit `b7aebd8`) |
| `audit-2026-09/render-service-02-host-gs-detection` | `render-service-01-hardening` (local branch) | T7 | **done** (local commit `89c48ff`) |
| `audit-2026-09/render-service-02-protocol-rework` | `render-service-01-hardening` (local branch) | T20,T21,T30,T32,T33,T36 | in progress |
| `audit-2026-09/xpc-trust-and-hardened-signing` | `main` | T5,T18 | **done** (local commit `10dfa60`) |
| `audit-2026-09/build-and-maintenance-scripts` | `main` | T8,T9,T23,T24,T39,T40,T41,T42 | **done** (local commits `c84e6c9`,`de1a3b3`) |
| `audit-2026-09/host-app-sandboxing` | `main` | T44 | **done** (local commit `ae0d5b5`) |
| `audit-2026-09/release-build-integrity` | `main` | T1,T29 | in progress |
| `audit-2026-09/docs-and-license-compliance` | `main` | T10,T11,T28,T46 | **done** (local commit `56635ed`) |
| `audit-2026-09/refactor-shared-bundle-identifiers` | `main` | T27 | **done** (local commit `523ee7f`) |
| `audit-2026-09/repo-hygiene` | `main` | T12,T45 | **done** (local commit `9be91ca`) |
| `audit-2026-09/local-git-hooks` | `main` | owner-directed (replaces CI) | **done** (local commit `ba47ea8`) |
| `audit-2026-09/translate-to-english` | `main` | owner-directed (2026-09-05) | **done** (local commit `f868ad8`) |
| `audit-2026-09/repo-hygiene` | `main` | T12,T45 | pending |
| `audit-2026-09/local-git-hooks` | `main` | owner-directed (replaces CI) | pending |
| `audit-2026-09/refactor-shared-bundle-identifiers` | `main` | T27 | pending |
| `audit-2026-09/add-unit-test-infrastructure` | `main` | T6,T26,T37 (thumbnailPixelSize) | in progress |
| `audit-2026-09/thumbnail-preview-consistency` | `main` | T22,T31,T34 | in progress |
| `audit-2026-09/swiftlint-and-language-mode` | `main` | T38 | in progress |

## Merge order

```
main
 ├─ render-service-01-hardening
 │   ├─ render-service-02-host-gs-detection
 │   └─ render-service-02-protocol-rework
 ├─ xpc-trust-and-hardened-signing
 ├─ build-and-maintenance-scripts
 ├─ host-app-sandboxing
 ├─ release-build-integrity
 ├─ docs-and-license-compliance
 ├─ repo-hygiene
 ├─ local-git-hooks
 ├─ refactor-shared-bundle-identifiers
 ├─ add-unit-test-infrastructure
 ├─ thumbnail-preview-consistency
 └─ swiftlint-and-language-mode
```

Since nothing pushes/MRs automatically this run, "merge order" here just
means **local branch creation order**: the two `render-service-02-*`
branches are created from `render-service-01-hardening`'s local tip, so `01`
must be implemented (or at least committed) before `02-*` agents start.
When the owner later pushes/MRs manually, push `01` first.

## Cross-branch touchpoints

- `project.yml` — touched by `render-service-02-host-gs-detection` (adds
  `Sources/Shared` to the host target), `xpc-trust-and-hardened-signing`
  (`ENABLE_HARDENED_RUNTIME: YES`), `add-unit-test-infrastructure` (new test
  target + scheme action), `swiftlint-and-language-mode` (Swift version /
  strict concurrency), `host-app-sandboxing` (drops host's embedded service
  target dependency). All are small, additive XcodeGen key changes in
  different sections — expect trivial conflicts on manual merge, resolve by
  reapplying the small diff.
- `scripts/build.sh` — **touched by three branches, needs manual reconciliation
  at merge time (raised from "low risk" after all three landed):**
  `xpc-trust-and-hardened-signing` (`10dfa60`, adds `-o runtime` to `sign()`
  calls), `build-and-maintenance-scripts` (`c84e6c9`, entitlement post-verify
  + NSExtension consistency check + **renumbered nearly every step header
  line to a clean `(N/7)` scheme** — this touches much more of the file than
  originally estimated), `host-app-sandboxing` (`ae0d5b5`, removes the host's
  `embed_service` call and its `sign` step). **Concrete dependency, not just
  textual overlap:** `build-and-maintenance-scripts` added an
  `assert_sandbox_state absent "$APP/Contents/XPCServices/RenderService.xpc"`
  check for the host's own copy of the service — but `host-app-sandboxing`
  deletes that exact copy. Whichever of the two is applied second must drop
  that one assertion line, or the merged `build.sh` will fail on a path that
  no longer exists. Owner: resolve this explicitly when merging, don't apply
  both diffs blindly.
- `Sources/RenderService/RenderService.swift` — owned primarily by
  `render-service-01-hardening` (the big rewrite); `render-service-02-*`
  branches are chained on top specifically to avoid a parallel conflicting
  rewrite of the same functions.
- `scripts/bundle-ghostscript.sh` — owned entirely by
  `release-build-integrity` (T1 assertions + T29 provenance manifest are the
  same file, same theme).

## HITL / follow-up items

- **`refactor-shared-bundle-identifiers` (done, `523ee7f`) corrected
  AUDIT-REPORT.md**: the report's evidence for T27 claimed all four
  `Info.plist`s repeat the bundle-ID literal — false against current `main`,
  they already use `$(PRODUCT_BUNDLE_IDENTIFIER)`. Only 3 Swift call sites
  had real duplication; fixed via a new `Sources/Shared/
  BundleIdentifiers.swift`. Verified with a real signed XPC round-trip probe
  (not just compile-check) that the render service still resolves correctly.
- **Owner action needed**: this branch adds `scripts/check-
  bundle-identifiers.sh` (a standalone consistency check) but deliberately
  does NOT wire it into `scripts/build.sh` — three other branches
  (`host-app-sandboxing`, `xpc-trust-and-hardened-signing`,
  `build-and-maintenance-scripts`) already edit that file heavily. **Add
  one line, `bash scripts/check-bundle-identifiers.sh`, near the end of the
  merged `build.sh`** (after signing, so it can also check the built
  bundles) once all `build.sh`-touching branches are merged.
- **`translate-to-english` (done, `f868ad8`) — two small cleanup items**:
  (1) another leftover gitignored DMG at `dist/EPSPreview-0.0.0-i18n.dmg`
  (~20MB) in that worktree, sandbox-denied `rm` again, delete manually; (2)
  suggests translating `render-service-02-host-gs-detection`'s new loading
  string to `"Checking for Ghostscript…"` (see the gap noted above) rather
  than a literal translation, and separately flagged a **pre-existing**
  SwiftUI markdown-rendering bug in `HostApp.swift` (string concatenation
  defeats `Text` markdown parsing, so `**Space**` shows literal asterisks)
  that it correctly left alone as outside "translate the strings" scope.

- **New owner-directed branch (2026-09-05): `translate-to-english`.** Owner
  wants zero Chinese text left anywhere in the repo — README.md's `中文速览`
  section deleted entirely (not translated), `scripts/package-release.sh`'s
  Chinese `INSTALL.txt` heredoc translated, `Sources/Host/HostApp.swift`'s
  Chinese UI strings translated. Based on plain `main`, so it only covers
  the Chinese text that exists there today.
- **Known gap this creates**: `render-service-02-host-gs-detection` (done,
  `89c48ff`) added a *new* Chinese loading-state string ("正在检测
  Ghostscript……") to `HostApp.swift` that didn't exist on `main` — the
  `translate-to-english` branch won't see or fix it, since it's based on
  `main`, not that chain. **Owner: translate that one string manually when
  merging**, or ask for a tiny follow-up fix — not worth restructuring the
  branch graph for one string.
- **`render-service-02-host-gs-detection` (done, `89c48ff`) — real
  unresolved concern for a future merge**: if `host-app-sandboxing`'s
  entitlement change lands on the host app too, `GhostscriptLocator`'s
  version-check step (`meetsMinimumVersion`, spawns `gs --version`) will
  fail under sandbox for the Homebrew-path case, silently reintroducing T7's
  false "not found" warning for source-build users even though the DMG path
  stays correct (bundled gs is exempt from version vetting). Agent flagged
  this clearly; not fixed by anyone yet — worth a look before merging both.
- **Could not visually verify** — `render-service-02-host-gs-detection`'s
  agent had no Screen Recording / Accessibility permission in its sandbox,
  so the three UI states (searching/installed/missing) are unverified by
  eye; verified instead via a standalone `GhostscriptLocator` harness
  confirming the resolver itself works (found `/opt/homebrew/bin/gs` in
  0.115s cold). Owner: worth a 10-second manual launch-and-look before
  pushing this one.
- **`local-git-hooks` (done, `ba47ea8`) found a pre-existing shellcheck
  warning** that will block the *first* future edit to
  `scripts/package-release.sh` once hooks are activated: `SC2034 LSREGISTER
  appears unused` at line 17. Not fixed (out of this branch's scope, no
  other branch covers it) — small follow-up recommended (`export
  LSREGISTER` or delete if dead).

- **`docs-and-license-compliance` (done, `56635ed`) corrected the audit
  report itself**: reproduced the actual bundled-dylib closure rather than
  trusting AUDIT-REPORT.md's list, and found `fontconfig` (`libfontconfig.1.
  dylib`) was missing from it entirely, plus one license annotation was
  imprecise (`libidn` is GPL-2.0-or-later OR LGPL-3.0-or-later per Homebrew,
  not plain LGPL-2.1). NOTICE.md now reflects 20 third-party projects (21
  dylibs) with license/version/homepage sourced from `brew info --json=v2`,
  not guessed. Verified end-to-end with a real DMG build + mount + inspect.
- **Owner: read the aggregation-legal-wording paragraph in NOTICE.md
  yourself** before pushing — the agent flagged it as its own good-faith
  reading, explicitly not legal advice, and it's the one load-bearing
  compliance sentence in the repo.
- **Cleanup needed in the main checkout (not a branch issue)**: `docs-and-
  license-compliance`'s verification run left `dist/EPSPreview-0.0.0-
  audit.dmg` (~20MB, gitignored, harmless) behind — its own `rm` was
  sandbox-denied. Delete manually when convenient.
- **`docs-and-license-compliance` used `WebFetch`** (read-only, public GitHub
  pages) to check whether this fork has published releases, for the T46
  fix — technically outside the briefing's `gh`/`glab` ban's literal wording
  but adjacent to it; nothing was mutated. Flagged by the agent itself,
  noting here for visibility.

- **`render-service-01-hardening` (done, `b7aebd8`) — real deviation from the
  T13 sketch, correctly reasoned**: "reject non-root-owned gs candidates" as
  literally specified would reject Homebrew's own `gs` (owned by the console
  user, not root on this machine), breaking the README's documented
  build-from-source path entirely. Implemented the achievable subset instead
  — reject group/world-writable binaries or parent dirs, and binaries owned
  by a *third* account — with a code comment explaining why. **Residual gap,
  documented, not fixed**: same-uid substitution of `gs` (an attacker with
  the same user account replacing the binary) is still possible and isn't
  defensible from inside this process. Version floor is gs ≥ 9.50 (a
  judgement call — where `-dSAFER` became default — not a CVE-driven floor;
  rejection is currently reported to the user as generic "not found", not
  "found but rejected", which the future typed-error branch should improve).
- **Widened, not created, by the same branch**: `scripts/install.sh`'s own gs
  check (`command -v gs` fallback) now diverges further from the vetted
  Swift resolver, which deliberately has no PATH fallback and now also
  rejects on ownership/version — `install.sh` can report "Ghostscript found"
  for a binary the service will refuse to use. Whoever eventually touches
  `install.sh` again should reconcile this (not assigned to any branch this
  run — note for the T14 follow-up issue or a future pass).
- **Known residual limitations, documented in code by the agent, not
  regressions**: no reap-safe force-kill in Foundation (tiny PID-reuse
  window on the SIGKILL escalation path, pre-existing pattern, now narrower);
  a genuinely unkillable gs process holds its concurrency slot for the
  service's lifetime (client-side deadline means the *user* no longer hangs,
  but the slot leaks); a hostile EPS flooding stdout before failing can push
  its own real error past the 64KB retained diagnostic head, truncating it
  (no security impact, just a worse error message).

- **`repo-hygiene` (done, `9be91ca`) corrected a factual detail in
  AUDIT-REPORT.md's T45**: the report said `.claude/` was ignored via the
  user's *global* gitignore; the agent checked and found no such global rule
  exists at all — `.claude/` was fully committable even on this machine
  before this fix. Doesn't change the remediation, just the severity
  framing (worse than stated, not better). Also confirmed: `AUDIT-REPORT.md`
  itself remains a tracked file on this index branch regardless of the new
  `.gitignore` entry (gitignore never untracks already-tracked paths) — not
  a problem since this branch never merges to `main`, just noting it isn't
  "fixed" by the repo-hygiene branch, it was never meant to be.

- **`xpc-trust-and-hardened-signing` (done, `10dfa60`) deviated from the
  planned approach on T5 axis 1**, for a real API-availability reason, not a
  shortcut: `kSecGuestAttributeAudit` needs the connection's raw audit
  token, which `NSXPCConnection` does not expose publicly (no
  `xpc_connection_get_audit_token` bridging, no public `auditToken`
  property). Instead the agent used `NSXPCConnection.
  setCodeSigningRequirement` (macOS 13+), which XPC re-validates per-message
  against the live connection — closes the same PID-reuse gap without
  private API. Verified with a differential test: an ad-hoc "evil" probe
  binary was accepted by unmodified `origin/main` and rejected by this
  branch. cdhash pinning (part of axis 2) was found structurally impossible
  given inside-out ad-hoc signing (the extension's cdhash isn't known until
  after the already-signed service exists) — used an identifier-based
  `SecRequirementCreateWithString` instead. **Owner: no action needed, just
  documented** — reasoning and differential-test methodology are in the
  agent's full report if you want to verify before pushing.
- **`xpc-trust-and-hardened-signing` installed `xcodegen` via Homebrew**
  (was missing on this machine) to be able to run `build.sh` at all — a
  machine-state change flagged by the agent, not a repo change.

- **`host-app-sandboxing` (done, `ae0d5b5`) extended its own scope by one
  line**: sandboxing `Sources/Host/Host.entitlements` broke
  `HostApp.swift`'s `ghostscriptInstalled` check — `isExecutableFile(atPath:)`
  is denied under the sandbox for the four system gs paths (verified
  empirically by the agent with a throwaway signed test app; no entitlement
  fixes it). The agent switched that one check to `fileExists(atPath:)` and
  flagged it explicitly as outside its assigned file list. **Owner: review
  this specific change** (`Sources/Host/HostApp.swift`) before pushing —
  agent's reasoning and test method are in its full report; not blindly
  applied here, just recorded.
- **`host-app-sandboxing` also noticed but did not fix**: the host status
  window still doesn't check the *bundled* Ghostscript path (this is exactly
  T7, owned by `render-service-02-host-gs-detection` once
  `render-service-01-hardening` lands) — confirms T7 is still needed as
  planned, not made redundant by this branch's fix.

- **Unit tests for logic fixed by other branches**: `add-unit-test-infrastructure`
  only adds the test target/fixtures + tests for code not otherwise touched
  this run (`thumbnailPixelSize`). Once `render-service-02-protocol-rework`
  (wantsInterpolation rewrite) and `xpc-trust-and-hardened-signing`
  (`BundleLayout` canonicalization) land, add unit tests for those functions
  as a quick follow-up — noted here so it isn't dropped.
- **`local-git-hooks`'s swiftlint step is a no-op** until
  `swiftlint-and-language-mode` merges and adds `.swiftlint.yml` — by design,
  the hook should check for the config file's existence before running lint.

## Decision log

- 2026-09-04 — Owner selected full scope (all 47 findings, all severities).
- 2026-09-04 — T14 (sandbox confinement) deferred to an issue rather than a
  branch — owner call, given regression risk and file overlap with
  render-service-01-hardening.
- 2026-09-04 — CI workflow replaced with local git hooks — owner preference
  for local-only enforcement over remote CI.
- 2026-09-04 — Branch agents implement + verify + commit locally, then stop.
  No self-review pipeline, no push, no MR this run — owner override of the
  skill's default delegated-review + push + MR protocol. Owner will review
  and push/MR each branch themselves.
