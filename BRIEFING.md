# Remediation branch agent briefing

You are implementing one branch of a repo-audit remediation for
`/Users/iwanuschka/projekte/_github/eps-preview`
(github.com/iwan-uschka/eps-preview). Your task prompt names your branch, its
base, and its scope (finding IDs referencing `AUDIT-REPORT.md`, which is
committed on the index branch `audit-2026-09/__index` — read it there, or
from the copy your task prompt inlines). Follow this protocol exactly.

**Authorization:** the repo owner approved this remediation plan on
2026-09-04, which authorizes commits on `audit-2026-09/*` branches.
**It does NOT authorize push or MR creation this run** — restate this in your
honesty section. Never force-push (moot — you will not push at all); never
touch `main`.

## Environment rules

- This is a Swift/macOS app, not a Node project — no node/pnpm prefix
  applies. Toolchain: Xcode 26.6, `xcodebuild` at `/usr/bin/xcodebuild`,
  XcodeGen (`xcodegen generate`) regenerates the `.xcodeproj` from
  `project.yml` — never edit the generated `.xcodeproj` directly, it is not
  committed.
- You work in an isolated git worktree at the path named in your task.
  **Verify your CWD is that worktree before every build or commit** — never
  operate in the shared main checkout.
- First: `git fetch origin`, then create your branch from the base named in
  your task. For branches based on `main`: `git checkout -b <branch>
  origin/main`. For the two branches based on
  `render-service-01-hardening`: that branch is created locally by another
  agent in a different worktree and is **not** pushed — your task will tell
  you how to obtain it (either it will already exist as a local branch ref
  you can `git checkout -b <branch> render-service-01-hardening`, or you
  will be given a patch/path to it; follow your task's specific instruction
  for this rather than assuming `origin/` has it).
- No install step — no package manager, no lockfile.

## Before coding

Read `README.md` in full before touching anything — it documents the XPC
peer-validation trust boundary, the 100MB/20s render limits, and why the
build must go through `scripts/build.sh` rather than bare `xcodebuild`
(the ad-hoc signing chain is load-bearing for XPC to work at all). No
`AGENTS.md`/`CLAUDE.md` exists in this repo.

## Implementation

- Stay strictly within your task's scope (its listed finding IDs). Unrelated
  problems you notice go in your final report — do not fix them.
- Match surrounding code style. No comments explaining what you changed. This
  codebase has no comments describing WHAT code does — only WHY, for
  non-obvious constraints (see existing examples in `RenderService.swift`
  and `scripts/build.sh`).
- Findings reference `AUDIT-REPORT.md` topic IDs (T1, T2, ...) — read the
  full finding text there (evidence, why-it-matters, remediation sketch)
  before implementing; the sketch is a starting point, not a spec.
- After edits, verify (all must pass — the whole app stays buildable, not
  just your changed files):

  ```
  bash scripts/build.sh
  ```

  This regenerates the Xcode project, builds Release, embeds the XPC
  service into each extension, patches `NSExtension` blocks, signs
  everything ad-hoc, and verifies the signature graph
  (`codesign --verify --deep --strict`). A failure anywhere in this script
  is a real failure — do not treat partial output as success.

  If your scope touches `scripts/install.sh`, `scripts/uninstall.sh`, or
  `scripts/refresh-thumbnails.sh`: these are NOT run automatically by
  `build.sh` — read them and reason about correctness; do not attempt to run
  `install.sh` (it writes to `/Applications` and touches LaunchServices /
  PluginKit registration on the real machine — out of bounds for a worktree
  agent). Note this as an unrunnable-but-reasoned-about check in your report.

  If your scope adds the unit-test target (`add-unit-test-infrastructure`
  branch only): also run `xcodebuild test -project EPSPreview.xcodeproj
  -scheme EPSPreview -derivedDataPath build` and report pass/fail.

  There is no CI, no lint gate (`swiftlint` is installed but has no repo
  config — do NOT add lint output as a blocking check unless your scope is
  `swiftlint-and-language-mode`, which adds the config), and no other
  automated verification in this repo. Do NOT attempt E2E Quick Look/Finder
  GUI testing, notarization, or anything requiring a live logged-in GUI
  session or Apple Developer account — list these as permanently unchecked
  Validation items with the reason, if your scope touches them at all.

## Commit — then stop

**Do not run `git push`. Do not create a merge/pull request. Do not use
`gh`/`glab` for anything.** This run's owner reviews and pushes each branch
themselves.

- Commit style: match repo history — imperative summary, e.g. "Guard
  against oversized files on the client, escalate stuck renders" (see
  `git log`). End the message with the Co-Authored-By trailer your harness
  specifies.
- One commit is fine; multiple logical commits are fine if that matches the
  scope's shape. Do not commit unrelated files (check `git status` before
  committing — this repo has no lockfile/build-artifact noise, so anything
  unexpected in `git status` is a red flag, not normal churn).
- After committing, leave the branch and worktree exactly as they are. Do
  not delete the worktree, do not switch back to another branch.

## Final report (your return value)

Return exactly this structure:

- branch name, base, worktree path, commit(s) made (short SHA + summary)
- what was implemented (short, per finding ID in scope)
- verification commands run + pass/fail for each, including the
  unrunnable/unattempted ones with reasons
- anything out of scope you noticed (not fixed)
- honesty section: restate the authorization interpretation above (commit
  only, no push, no MR, no self-review pipeline this run) plus anything
  skipped, failed, or uncertain

Never claim something passed that you did not run.
