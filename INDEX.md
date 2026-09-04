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
| `audit-2026-09/render-service-01-hardening` | `main` | T2,T3,T4,T13,T15,T16,T17,T35,T37 | in progress |
| `audit-2026-09/render-service-02-host-gs-detection` | `render-service-01-hardening` | T7 | blocked on 01 |
| `audit-2026-09/render-service-02-protocol-rework` | `render-service-01-hardening` | T20,T21,T30,T32,T33,T36 | blocked on 01 |
| `audit-2026-09/xpc-trust-and-hardened-signing` | `main` | T5,T18 | in progress |
| `audit-2026-09/build-and-maintenance-scripts` | `main` | T8,T9,T23,T24,T39,T40,T41,T42 | in progress |
| `audit-2026-09/host-app-sandboxing` | `main` | T44 | **done** (local commit `ae0d5b5`) |
| `audit-2026-09/release-build-integrity` | `main` | T1,T29 | in progress |
| `audit-2026-09/docs-and-license-compliance` | `main` | T10,T11,T28,T46 | pending |
| `audit-2026-09/repo-hygiene` | `main` | T12,T45 | pending |
| `audit-2026-09/local-git-hooks` | `main` | owner-directed (replaces CI) | pending |
| `audit-2026-09/refactor-shared-bundle-identifiers` | `main` | T27 | pending |
| `audit-2026-09/add-unit-test-infrastructure` | `main` | T6,T26,T37 (thumbnailPixelSize) | pending |
| `audit-2026-09/thumbnail-preview-consistency` | `main` | T22,T31,T34 | pending |
| `audit-2026-09/swiftlint-and-language-mode` | `main` | T38 | pending |

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
- `scripts/build.sh` — touched by `xpc-trust-and-hardened-signing` (adds
  `-o runtime` to `sign()` calls), `build-and-maintenance-scripts`
  (entitlement post-verify, NSExtension consistency check, misc line fixes),
  `host-app-sandboxing` (removes the host's `embed_service` call). Different
  functions/lines in the same file — sequential application, low risk.
- `Sources/RenderService/RenderService.swift` — owned primarily by
  `render-service-01-hardening` (the big rewrite); `render-service-02-*`
  branches are chained on top specifically to avoid a parallel conflicting
  rewrite of the same functions.
- `scripts/bundle-ghostscript.sh` — owned entirely by
  `release-build-integrity` (T1 assertions + T29 provenance manifest are the
  same file, same theme).

## HITL / follow-up items

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
