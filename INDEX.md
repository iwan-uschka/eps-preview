# audit-2026-09 — Index

Phase: finished

This branch is the run's status board. It never merges into `main`.

## Run metadata

- Started: 2026-09-04, finished: 2026-09-05
- Repo: `iwan-uschka/eps-preview` (github.com), fork of `Zhangyanbo/eps-preview`
- Scope: all 47 findings from `AUDIT-REPORT.md` (owner selected "everything
  incl. Low"), plus one owner-directed addition (`translate-to-english`, not
  a numbered finding).
- Node/toolchain: N/A — Swift/macOS app (XcodeGen + xcodebuild), no node
  tooling involved. See `PROBE.md`.
- Review mode: delegated would normally apply (sandbox probe passed), but
  **overridden by explicit owner instruction this run** — see "Execution
  protocol" below; no branch ran the review-branch self-review pipeline.

## Execution protocol (owner-directed override of the skill's default)

Per explicit owner instruction on 2026-09-04, every branch agent this run:

1. Implemented its scope.
2. Ran the repo's verification commands (`bash scripts/build.sh`, plus
   scope-specific checks — see `BRIEFING.md`).
3. Committed locally on its branch.
4. **Stopped.** No self-review pipeline, no `git push`, no MR creation.

**Nothing in this run has been pushed except this index branch.** All 15
work branches exist only as local branches in worktrees under
`/Users/iwanuschka/projekte/_github/eps-preview-worktrees/`. The owner
reviews and pushes/MRs each branch themselves, on their own schedule — see
"How to review and push a branch" below.

## How to review and push a branch

Each branch's worktree is untouched since its agent finished — inspect,
amend, or push directly:

```bash
cd /Users/iwanuschka/projekte/_github/eps-preview-worktrees/<branch-name>
git log -p origin/main..HEAD    # see the actual diff
git push -u origin <full-branch-name>   # e.g. audit-2026-09/render-service-01-hardening
```

The two `render-service-02-*` branches are stacked on
`render-service-01-hardening`'s **local** tip (never pushed under that
name) — push `render-service-01-hardening` first, then rebase/push the
`02-*` branches against it, or push all three and let the forge show the
stack once `01` exists remotely.

Worktrees are left in place deliberately (not cleaned up) so nothing here
is lost before you've reviewed it. Remove one after you're done with it:
`git worktree remove /Users/iwanuschka/projekte/_github/eps-preview-worktrees/<branch-name>`.

## Deferred work → filed as GitHub issues (2026-09-05)

Issues were disabled on this fork; owner asked to enable them and file these
now. All 12 filed against `iwan-uschka/eps-preview`:

- [#4 — Sandbox-confine the Ghostscript child process (rlimits + sandbox-exec)](https://github.com/iwan-uschka/eps-preview/issues/4) — T14
- [#5 — Check pinned Ghostscript + bundled libraries against known CVEs](https://github.com/iwan-uschka/eps-preview/issues/5)
- [#6 — Prune unused OCR/archive libraries from the bundled Ghostscript closure](https://github.com/iwan-uschka/eps-preview/issues/6)
- [#7 — Automate third-party license manifest generation for bundled Ghostscript libs](https://github.com/iwan-uschka/eps-preview/issues/7) — T11 (full form)
- [#8 — Legal review of NOTICE.md's AGPL aggregation wording](https://github.com/iwan-uschka/eps-preview/issues/8) — see HITL #5
- [#9 — Notarize the app / sign with a real Developer ID](https://github.com/iwan-uschka/eps-preview/issues/9)
- [#10 — Add an end-to-end Quick Look/Finder manual test checklist](https://github.com/iwan-uschka/eps-preview/issues/10)
- [#11 — Add a negative XPC peer-rejection test](https://github.com/iwan-uschka/eps-preview/issues/11)
- [#12 — Track macOS 26 (Tahoe) CI/runner coverage](https://github.com/iwan-uschka/eps-preview/issues/12)
- [#13 — Document the TCC path-avoidance invariant](https://github.com/iwan-uschka/eps-preview/issues/13)
- [#14 — Add unit tests for wantsInterpolation and BundleLayout once their rewriting branches merge](https://github.com/iwan-uschka/eps-preview/issues/14)
- [#15 — Fix pre-existing shellcheck SC2034 warning in package-release.sh](https://github.com/iwan-uschka/eps-preview/issues/15) — see HITL #8

No triage label was applied — the repo has no `needs-triage`-equivalent
convention (only GitHub's default label set exists).

## Branch table

| Branch | Base | Scope (finding IDs) | Commit(s) |
|---|---|---|---|
| `render-service-01-hardening` | `main` | T2,T3,T4,T13,T15,T16,T17,T35,T37 | `b7aebd8` |
| `render-service-02-host-gs-detection` | `render-service-01-hardening` (local) | T7 | `89c48ff` |
| `render-service-02-protocol-rework` | `render-service-01-hardening` (local) | T20,T21,T30,T32,T33,T36 | `c8cc7fa` |
| `xpc-trust-and-hardened-signing` | `main` | T5,T18 | `10dfa60` |
| `build-and-maintenance-scripts` | `main` | T8,T9,T23,T24,T39,T40,T41,T42 | `c84e6c9`, `de1a3b3` |
| `host-app-sandboxing` | `main` | T44 | `ae0d5b5` |
| `release-build-integrity` | `main` | T1,T29 | `4eb4e03` |
| `docs-and-license-compliance` | `main` | T10,T11,T28,T46 | `56635ed` |
| `repo-hygiene` | `main` | T12,T45 | `9be91ca` |
| `local-git-hooks` | `main` | owner-directed (replaces CI) | `ba47ea8` |
| `refactor-shared-bundle-identifiers` | `main` | T27 | `523ee7f` |
| `add-unit-test-infrastructure` | `main` | T6,T26,T37 (thumbnailPixelSize) | `7f686cc` |
| `thumbnail-preview-consistency` | `main` | T22,T31,T34 | `d1b0799` |
| `swiftlint-and-language-mode` | `main` | T38 | `9dba3e6` |
| `translate-to-english` | `main` | owner-directed (2026-09-05) | `f868ad8` |

All 15/15 **done** (locally committed, unpushed, unreviewed by anyone but
their own agent).

## Merge order

```
main
 ├─ render-service-01-hardening          ← push/review first among the three
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
 ├─ swiftlint-and-language-mode
 └─ translate-to-english
```

The 13 branches off `main` are independent of each other in principle, but
several touch the same files (see touchpoints below) — merging one before
reviewing another's overlapping diff will make the second harder to review
cleanly. No forced order among them; the `build.sh`-touching three (below)
are the one place order actually matters.

## Cross-branch touchpoints (owner must reconcile manually — nothing here auto-merges)

1. **`scripts/build.sh` — touched by three branches, needs manual
   reconciliation, in this order of dependency:**
   - `host-app-sandboxing` (`ae0d5b5`) removes the host app's own embedded
     `RenderService.xpc` copy and its `embed_service`/`sign` calls.
   - `build-and-maintenance-scripts` (`c84e6c9`) adds an
     `assert_sandbox_state absent "$APP/Contents/XPCServices/RenderService.xpc"`
     check for that exact path, **plus renumbers nearly every step-header
     line** in the file to a clean `(N/7)` scheme.
   - `xpc-trust-and-hardened-signing` (`10dfa60`) adds `-o runtime` to the
     `sign()` helper's `codesign` calls.
   **Concrete conflict, not just textual overlap**: if `build-and-maintenance-scripts`'s
   assertion is applied without also applying `host-app-sandboxing`'s
   removal, the merged `build.sh` will hard-fail on a path that no longer
   exists. Apply `host-app-sandboxing` first, or drop that one assertion
   line when reconciling.
   **Also add** (from `refactor-shared-bundle-identifiers`, see below): one
   line, `bash scripts/check-bundle-identifiers.sh`, near the end of the
   merged script.

2. **`project.yml`** — touched by `render-service-02-host-gs-detection`
   (adds `Sources/Shared` to the host target), `xpc-trust-and-hardened-signing`
   (`ENABLE_HARDENED_RUNTIME: YES`), `add-unit-test-infrastructure` (new
   test target + scheme action), `swiftlint-and-language-mode`
   (`SWIFT_STRICT_CONCURRENCY: targeted`), `host-app-sandboxing` (drops the
   host's embedded-service dependency), `thumbnail-preview-consistency`
   (excludes `PDFPageGeometry.swift` from the RenderService target's
   sources to avoid an unwanted PDFKit link). All additive, different
   sections — expect only trivial conflicts, reapply each small diff.

3. **`Sources/RenderService/RenderService.swift`** — owned primarily by
   `render-service-01-hardening` (the core rewrite: pipe draining,
   non-blocking handler, concurrency cap, gs vetting, output cap, env
   scrubbing, watchdog fix). The two `render-service-02-*` branches are
   chained on top of it specifically to avoid a parallel conflicting
   rewrite — they should apply cleanly in sequence, `01` then either `02`.

4. **`Sources/Host/HostApp.swift`** — touched independently by
   `host-app-sandboxing` (based on `main`, switches a gs-check to
   `fileExists`) and `render-service-02-host-gs-detection` (based on the
   render-service chain, replaces the whole check with `GhostscriptLocator`).
   These will conflict on merge; `render-service-02-host-gs-detection`'s
   version supersedes `host-app-sandboxing`'s narrower fix — but see the
   sandbox/version-check interaction flagged in HITL below before assuming
   that's a clean "take theirs."

5. **`scripts/bundle-ghostscript.sh`** — owned entirely by
   `release-build-integrity` (T1 hard-fail assertions + T29 dependency
   manifest, same file, same theme). No conflict expected.

## HITL — priority checklist (deploy-blocking first)

1. **Smoke-test `render-service-02-protocol-rework` on a real device before
   trusting it.** T30's FileHandle-over-XPC transfer is verified only via an
   in-process `NSXPCListener.anonymous()` harness — never under an actual
   *sandboxed* extension, which is the one case that matters in production.
   If Quick Look/Thumbnail regress after installing this branch, suspect
   this first; it's cleanly revertible to plain `Data` transfer.
2. **Resolve the `build.sh` merge order explicitly** (touchpoint #1 above) —
   apply `host-app-sandboxing` before `build-and-maintenance-scripts`, or
   manually drop the now-invalid assertion line.
3. **Review `Sources/Host/HostApp.swift` before pushing either
   `host-app-sandboxing` or `render-service-02-host-gs-detection`** —
   both changed it independently (touchpoint #4), and there's a real
   unresolved interaction: if `host-app-sandboxing`'s entitlement change
   lands on top of `render-service-02-host-gs-detection`'s
   `GhostscriptLocator` call, the locator's version-check step (spawns
   `gs --version`) will fail under sandbox for the Homebrew-gs case,
   silently reintroducing T7's false "not found" warning for source-build
   users (the DMG/bundled-gs path stays correct either way). Worth deciding
   before merging both.
4. **Translate one string manually.** `render-service-02-host-gs-detection`
   added a new Chinese loading string ("正在检测 Ghostscript……") to
   `HostApp.swift` that didn't exist when `translate-to-english` ran (that
   branch is based on plain `main`). Suggested: `"Checking for Ghostscript…"`.
5. **Read the AGPL-aggregation paragraph in `NOTICE.md` yourself** before
   pushing `docs-and-license-compliance` — the agent wrote it as its own
   good-faith technical + legal reading, explicitly not legal advice, and
   it's the one load-bearing compliance sentence in the repo.
6. **Add `bash scripts/check-bundle-identifiers.sh` to the end of the merged
   `build.sh`** (from `refactor-shared-bundle-identifiers`) once the
   `build.sh`-touching branches above are reconciled.
7. **Delete three leftover gitignored DMG files** in various worktrees/main
   checkout (`dist/EPSPreview-0.0.0-audit.dmg`, `dist/EPSPreview-0.0.0-i18n.dmg`,
   and any in the main checkout) — each agent's own `rm` was sandbox-denied.
   Harmless, just clutter.
8. **One pre-existing shellcheck warning** (`SC2034 LSREGISTER appears
   unused`, `scripts/package-release.sh:17`) will block the *first* future
   edit to that file once `local-git-hooks` is activated. Small follow-up:
   `export LSREGISTER` or delete if dead.

## Other notes worth knowing (non-blocking)

- **AUDIT-REPORT.md had two factual errors, both caught and corrected by
  branch agents during implementation** (not by review — worth knowing the
  original report wasn't perfect): T27's claim that all four `Info.plist`s
  repeat the bundle-ID literal was false (they already use
  `$(PRODUCT_BUNDLE_IDENTIFIER)`); T45's claim that `.claude/` was ignored
  via the user's *global* gitignore was false (no such global rule existed
  at all — the exposure was worse than stated, not better). Neither
  changes what was fixed, just the evidence trail.
- **`docs-and-license-compliance` also found `fontconfig` was missing
  entirely from the audit's bundled-dylib list**, and one license
  annotation was imprecise (`libidn` is GPL-2.0-or-later OR
  LGPL-3.0-or-later, not plain LGPL-2.1) — corrected in the rebuilt
  `NOTICE.md`.
- **`xpc-trust-and-hardened-signing` deviated from the planned approach**
  for a real API-availability reason: `kSecGuestAttributeAudit` needs a raw
  audit token `NSXPCConnection` doesn't expose publicly. Used
  `NSXPCConnection.setCodeSigningRequirement` instead (macOS 13+, re-validates
  per-message) — verified with a differential test showing unmodified
  `main` accepts a foreign ad-hoc binary and this branch rejects it. Also
  installed `xcodegen` via Homebrew (was missing) — a machine-state change,
  not a repo change.
- **`render-service-01-hardening` deviated from the T13 sketch**: literally
  rejecting "non-root-owned" gs candidates would reject Homebrew's own `gs`
  (owned by the console user), breaking the documented build-from-source
  path. Implemented the achievable subset (reject group/world-writable
  binaries/dirs, reject third-party ownership) instead — same-uid
  substitution remains a documented, undefended residual gap. Version floor
  is gs ≥ 9.50, a judgement call (where `-dSAFER` became default), not
  CVE-driven.
- **`render-service-01-hardening`'s gs-vetting widened, not created, a
  pre-existing divergence**: `scripts/install.sh`'s own gs check
  (`command -v gs` fallback) has no ownership/version vetting, so it can
  report "found" for a binary the service now refuses. Not assigned to any
  branch this run — candidate for the T14 follow-up issue.
- `render-service-01-hardening`'s T20 (`wantsInterpolation` rewrite, done in
  the `02-protocol-rework` branch) scans the *entire* input buffer with no
  leading-window cap — a documented tradeoff (176ms measured worst case on
  100MB) to avoid wrong answers on large figures, not an oversight.
- `SWIFT_STRICT_CONCURRENCY: targeted` (added by `swiftlint-and-language-mode`)
  is **provably inert on this toolchain** (Xcode 26.6) — confirmed via 4
  separate builds that it produces a byte-identical compiler invocation to
  leaving the key unset. Added anyway since it's zero-risk and matches the
  pre-authorized instruction; `complete` mode currently surfaces exactly one
  real issue on `main` (`PreviewViewController` actor-isolation crossing) —
  re-measure after the render-service branches merge, don't treat that
  count as still accurate post-merge.
- `add-unit-test-infrastructure` only covers code not otherwise touched this
  run (18/18 tests passing, incl. a real binary DOS-EPS fixture with a
  genuine `gs`-generated TIFF preview). Add unit tests for
  `wantsInterpolation` and `BundleLayout` as a follow-up once their
  respective branches merge.
- `thumbnail-preview-consistency` makes PDF rotation honored (not zeroed)
  in both preview and thumbnail — spec-correct and consistent, but a
  visible behavior change for any `/Rotate`-carrying input; no fixture
  exists yet to confirm what Ghostscript actually emits for rotated
  sources.
- `docs-and-license-compliance` used `WebFetch` (read-only, public GitHub
  pages) to check release history for T46 — outside the literal wording of
  the `gh`/`glab` ban but adjacent to it; nothing was mutated. Flagged by
  the agent itself.
- Every commit's `Co-Authored-By` trailer reads "Claude Sonnet 5" per this
  harness's fixed convention — every branch agent this run actually ran on
  Opus, per the plan. Cosmetic only.

## Decision log

- 2026-09-04 — Owner selected full scope (all 47 findings, all severities).
- 2026-09-04 — T14 (sandbox confinement) deferred to an issue rather than a
  branch — owner call, given regression risk and file overlap with
  render-service-01-hardening.
- 2026-09-04 — CI workflow replaced with local git hooks — owner preference
  for local-only enforcement over remote CI.
- 2026-09-04 — Branch agents implement + verify + commit locally, then stop.
  No self-review pipeline, no push, no MR this run — owner override of the
  skill's default delegated-review + push + MR protocol. Owner reviews and
  pushes/MRs each branch themselves.
- 2026-09-05 — Owner added a scope item outside the original audit: remove
  all Chinese text from the repo. New branch `translate-to-english` created
  and completed same day.
- 2026-09-05 — Run complete. All 15 branches locally committed.
- 2026-09-05 — Owner asked to file the deferred items as GitHub issues.
  Discovered Issues were disabled on this fork (`gh issue create` failed
  outright); owner confirmed enabling them. Ran `gh repo edit --enable-issues`
  then filed all 12 (see "Deferred work" above for links).
