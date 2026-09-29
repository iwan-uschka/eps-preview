# Manual pre-release checklist: Quick Look / Finder end-to-end

None of the automated coverage in `Tests/` or `scripts/test-*.sh` drives the
actual end-user path — select a `.eps`/`.ps` file in Finder, press Space, see
the rendered preview; view a folder, see correct thumbnails. That path only
exists inside a live, logged-in GUI session with real Finder/Quick
Look/PluginKit integration and the Accessibility/Automation TCC grants a
script would need to drive Finder itself — not something a background CI
runner or a worktree agent can provision non-interactively, and GitHub-hosted
macOS runners can't reliably drive it either. So it stays a manual checklist:
run it yourself, by hand, logged into a real Mac, before tagging a release.

Re-run this whenever `Sources/QuickLook`, `Sources/Thumbnail`,
`Sources/RenderService`, `Sources/Shared`, or `Sources/Host` changes, or
`project.yml` or `scripts/build.sh`, `scripts/install.sh`,
`scripts/uninstall.sh` changes, and always before cutting a release DMG
(`scripts/package-release.sh`).

## 1. Set up

```bash
bash scripts/make_install.sh
```

Confirm the install actually registered: open **System Settings → General →
Login Items & Extensions → Quick Look** and check **EPS Preview** is listed
and enabled exactly once. (If it's listed more than once, see the stray
extension note in `README.md`'s "Build from source" section before
continuing — a stale duplicate will make the results below ambiguous about
which copy actually rendered.)

Create a scratch folder with a mix of known-good and known-tricky files.
The committed fixtures in `Tests/Fixtures/` cover several of the tricky
cases and can be copied in directly:

| File | Why it's here |
|------|----------------|
| `Tests/Fixtures/minimal-ascii.eps` | Known-good baseline — plain ASCII EPS |
| `Tests/Fixtures/interpolate-true.eps` | Known-tricky — image dict requests interpolation; checks the Retina interpolation path renders smoothly, not blocky |
| `Tests/Fixtures/interpolate-false.eps` | Known-tricky — image dict declines interpolation; should render crisp/blocky, not smoothed |
| `Tests/Fixtures/binary-dos-eps-with-preview.eps` | Known-tricky — DOS EPS binary header with an embedded TIFF preview; render must come from Ghostscript, not the stale embedded preview |

Add a few more by hand:

- A real-world `.eps` and a real-world `.ps` file from any existing project
  (vector figure, e.g. a plot or diagram) — known-good.
- A photo-heavy or large-canvas EPS — known-good, checks rendering isn't
  only tested against toy fixtures.
- A deliberately malformed/truncated EPS (e.g. `head -c 200` a valid one) —
  known-tricky, should fail gracefully (no preview / clear failure), not
  hang or crash Finder.
- Optional, only if you want to exercise the size/time limits described in
  `README.md`: a file over 100 MB (should be refused up front) and/or a
  pathological PostScript body that loops (`{(A) print} loop`, should be
  terminated by the render service's own timeout rather than hanging
  Finder itself).

**Release-candidate variant:** `make_install.sh` is a source build, which
calls your Homebrew `gs` at runtime — it does not exercise the pinned
Ghostscript and bundled libraries a release DMG ships (see `README.md`'s
"Build from source" section). Before cutting a release, also build the DMG
with `bash make_release.sh <version>` (see `README.md`'s "Releasing" — it
stamps `CHANGELOG.md` and only prints the publish commands, so nothing is
tagged or uploaded until you run them after this checklist passes), install
`EPSPreview.app` from it the
way `README.md`'s "Option A" describes (drag into Applications, "Open
Anyway"), and do this on a machine or account without Homebrew `gs` on
`PATH` — no automated test exercises the bundled `converter`'s sandbox
profile (`GhostscriptSandboxIntegrationTests` only ever resolves a system
`gs`), so this is the only check that the bundled-tree sandbox roots are
right. Then run §2–§5 against that install too. If a section fails, discard
the stamp (`git checkout CHANGELOG.md NOTICE.md`) before fixing and rerunning
`make_release.sh`.

## 2. Finder thumbnails

1. Open the scratch folder in Finder, icon view.
2. Wait for thumbnails to generate. Every known-good file should show its
   actual rendered content, not a generic document icon.
3. Eyeball each thumbnail against the file's actual content — orientation,
   aspect ratio, and (for the interpolate-true/false pair) that one looks
   smoothed and the other doesn't.
4. Known-tricky files should either render correctly or fail visibly
   (generic icon) — never a beachball, and never a Finder hang.
5. If any file still shows a blank/generic icon after settling, try
   `bash scripts/refresh-thumbnails.sh` once before deciding it's a real
   failure — Finder's icon cache is aggressive and this is expected on
   already-cached files, not a bug (see `README.md`'s "Existing files
   still show a blank icon?" section).

## 3. Quick Look (spacebar)

For each file in the scratch folder:

1. Select it in Finder, press **Space**.
2. Confirm the preview panel shows the rendered figure, matches the
   thumbnail, and appears within a couple of seconds for known-good files.
3. Arrow through to the next file with Quick Look still open (Left/Right or
   the on-screen arrows) and confirm each preview updates correctly rather
   than showing the previous file's content.
4. For the malformed/truncated fixture: confirm Quick Look shows a sensible
   failure (blank/placeholder, or Finder's own "no preview available"), not
   an infinite spinner and not a crash.
5. If you added an oversized or looping fixture: confirm Quick Look
   eventually gives up (error or placeholder) rather than hanging — it's
   fine if this takes up to the render service's own timeout window, but it
   must resolve, not spin forever.

## 4. Fan-out (optional, only after touching concurrency/timeout code)

1. Select all files in the scratch folder (⌘A) and press Space to open
   Quick Look, then arrow rapidly through all of them.
2. Confirm Finder/Quick Look stays responsive throughout — no beachball, no
   force-quit needed. It's fine if a couple of previews come back as "Too
   many previews at once" and Finder retries; what to watch for is Finder
   or the extension actually hanging.

## 5. Uninstall

```bash
bash scripts/make_uninstall.sh
```

Confirm **EPS Preview** no longer appears under Login Items & Extensions,
and that a fresh Quick Look (Space) on an EPS file in the scratch folder
falls back to Finder's default (no preview / generic icon), not a crash.

## 6. Record the result

Before tagging a release, note in the release notes (the new version's
`CHANGELOG.md` section, before you commit it — `gh release create` publishes
that section) or PR description: the
macOS version tested (this project supports macOS 14+ and specifically
targets 15/Sequoia and 26/Tahoe — test on whichever you have, ideally all
over time) and pass/fail for each section
above. A failure here blocks the release regardless of what the automated
suites report — this is the only check that exercises the real
Finder/PluginKit/Quick Look integration end to end.
