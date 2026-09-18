# EPS Preview

> This is a fork of [Zhangyanbo/eps-preview](https://github.com/Zhangyanbo/eps-preview).

Restore **spacebar Quick Look** and **Finder thumbnails** for `.eps` / `.ps`
files on modern macOS — the EPS support Apple removed back in macOS Ventura,
and which broke entirely once legacy Quick Look plugins stopped loading in
macOS Sequoia / Tahoe.

Select an EPS file in Finder, press **Space**, and see the full figure.
Finder icons show the real figure instead of a blank document.

## How it works

macOS 15 (Sequoia) and 26 (Tahoe) only register Quick Look extensions that
are **sandboxed** — but a sandboxed extension can't freely run Ghostscript.
EPS Preview solves this with a small, robust architecture:

```
EPSPreview.app
├── EPSPreview            host app (one-screen "installed" window)
├── EPSQuickLook.appex    sandboxed Quick Look preview  (spacebar)
├── EPSThumbnail.appex    sandboxed Finder thumbnails
└── RenderService.xpc     UNSANDBOXED helper, embedded in each extension
```

The sandboxed extensions hand an EPS path to the embedded, **unsandboxed**
`RenderService`, which runs your system **Ghostscript** (`gs`) to convert it
to PDF and returns the bytes. The extension then displays the PDF with
PDFKit. Because the render happens in the unsandboxed helper, there are no
sandbox gymnastics around executing `gs` or reading files.

A build from source does **not** bundle Ghostscript — it uses the copy you
install via Homebrew. That keeps this project small and MIT-licensed, and
always uses an up-to-date `gs`. (The downloadable release does bundle one —
see [Install](#install).)

Not *any* `gs`, though — and this is about the system copy a source build
uses; the release's own bundled Ghostscript is pinned and sealed by the app
signature, so it skips this vetting. The render service only runs a system
`gs` it finds at `/opt/homebrew/bin/gs`, `/usr/local/bin/gs`, `/opt/local/bin/gs` or
`/usr/bin/gs` — your `PATH` is never searched — that reports version **9.50**
or newer (where `-dSAFER` became the enforced default), and whose binary and
containing directory are writable by nobody but their owner. `scripts/install.sh`
applies exactly the same rules, so it cannot report Ghostscript as found for a
copy every preview would then refuse.

The `RenderService` only accepts XPC connections from processes whose code
signature is intact and whose executable lives inside the *same*
`EPSPreview.app` bundle, so an unrelated local process cannot use it to run
Ghostscript. This makes the ad-hoc signing step in `scripts/build.sh`
load-bearing: build via `bash scripts/build.sh`, not a bare `xcodebuild`, or
previews will fail with "Render service connection failed".

Previews are bounded on purpose: EPS files larger than **100 MB** are refused
up front, a single Ghostscript render is terminated after **20 s** (`-dSAFER`
restricts file/network access but not CPU, so a pathological PostScript body
could otherwise hang the helper), a rendered PDF larger than **64 MB** is
rejected instead of being read into memory, and at most **3** renders run at
once with at most **8** requests in flight — a Finder folder full of EPS files
is throttled rather than fanned out into unbounded Ghostscript processes;
requests past that are refused with "Too many previews at once." and Finder
retries them on its next pass. The size, time and concurrency limits all live
in `RenderLimits` (`Sources/Shared/RenderClient.swift`) — the concurrency
bounds among them, because the deadline the *client* gives up after is derived
from them: an admitted request may wait out the queue ahead of it before its
own render starts.

## Install

### Option A — Download (recommended, nothing to build)

1. Download `EPSPreview-x.y.z.dmg` from the
   [**Releases**](https://github.com/Zhangyanbo/eps-preview/releases) page.
2. Open the `.dmg` and drag **EPSPreview.app** onto **Applications**.
3. Open it once. macOS will block it the first time because the app isn't
   Apple-notarized — go to **System Settings → Privacy & Security**, scroll
   down, and click **Open Anyway**, then confirm. (You only do this once.)
4. Select any `.eps` / `.ps` file in Finder and press **Space**.

The release is **self-contained** — Ghostscript is bundled, so you do **not**
need Homebrew or any other install. Works on macOS 14+ (Apple Silicon).

### Option B — Build from source

Requirements: Xcode + [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`) + [Homebrew](https://brew.sh) Ghostscript
(`brew install ghostscript`).

```bash
git clone https://github.com/Zhangyanbo/eps-preview.git
cd eps-preview
bash scripts/make_build.sh      # build + ad-hoc sign
bash scripts/make_test.sh       # full test suite
bash scripts/make_install.sh    # build, install to /Applications, register extensions
```

`scripts/make_uninstall.sh` reverses `make_install.sh`. **Never run
`make_install.sh` / `make_uninstall.sh` with `sudo`** — both refuse outright
and exit 1 if you do. The guard lives only in the `make_*.sh` wrappers, so if
you run the underlying `scripts/install.sh` / `scripts/uninstall.sh` directly
(see below), the same "never with `sudo`" rule applies but nothing will stop
you from breaking it: `install.sh` calls `lsregister` and `open`, which are
per-user; running as root registers the extensions into *root's*
LaunchServices database, invisible to your actual login session, which
silently breaks Finder's thumbnails even though the install "succeeds". If a
past `sudo` run already left a root-owned `/Applications/EPSPreview.app`
behind, clear it once with `sudo rm -rf /Applications/EPSPreview.app` before
running `make_install.sh` again — that one-time cleanup step is the only
place `sudo` belongs in this workflow.

Each `make_*.sh` is a thin wrapper — for finer control, or to run one piece
in isolation, the commands underneath are:

```bash
xcodegen generate                                # regenerate EPSPreview.xcodeproj from project.yml
bash scripts/build.sh                             # builds + ad-hoc signs (no Apple Developer account needed)
bash scripts/install.sh                           # installs to /Applications, registers extensions
bash scripts/uninstall.sh                         # removes it, unregisters extensions
xcodebuild test -scheme EPSPreview -project EPSPreview.xcodeproj   # Swift unit tests
bash scripts/test-ghostscript-check.sh           # installer vetting, plain bash
bash scripts/test-ghostscript-manifest.sh        # bundled-library closure gate
bash scripts/test-githooks.sh                    # the git hooks' own logic
bash scripts/test-make-scripts.sh                # the make_*.sh wrappers' own logic
```

`xcodebuild test` only builds `EPSPreviewTests` (which compiles `Sources/Shared`
directly) — the scheme deliberately excludes the host app, both extensions, and
the render XPC service from the `test` action. Building them there used to leave
a full `EPSPreview.app` with embedded Quick Look/Thumbnail extensions (and
RenderService) sitting in DerivedData after every test run, and macOS's
LaunchServices auto-registers any such app it finds on disk — so every test run
silently registered a stray duplicate of the real `/Applications` install,
alongside whatever other build-tree copies (other worktrees, ad-hoc builds)
happened to exist. If you
ever see EPS Preview listed more than once under System Settings → General →
Login Items & Extensions → Quick Look, find and drop the stale copies with
`lsregister -dump` / `lsregister -u <path-to-stale-EPSPreview.app>`
(`lsregister` is
`/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister`).

The `EPSPreviewTests` target covers `Sources/Shared` — the Ghostscript
resolution cache and version floor, the admission counter, the render-outcome
rules, the app-bundle layout helper, the thumbnail geometry and the page
geometry / preview paging rules — plus the committed `Tests/Fixtures` EPS
inputs, which are checked for structural integrity so a truncated fixture fails
loudly. The plain-bash suites (no dependencies) cover the shell side:
`scripts/test-ghostscript-check.sh` pins the installer's Ghostscript vetting
against the service's using fake `gs` binaries,
`scripts/test-ghostscript-manifest.sh` pins the bundled-library closure gate
against fake manifests, `scripts/test-githooks.sh` pins the pre-commit and
pre-push hooks against throwaway repos and stubbed tools, and
`scripts/test-make-scripts.sh` pins `make_install.sh`/`make_uninstall.sh`'s
refusal to run as root, their delegation to `build.sh`/`install.sh`/
`uninstall.sh` otherwise, and `make_test.sh`'s refusal to run without
`xcodegen` on `PATH`.

A source build is **not** self-contained: it calls your Homebrew `gs` at
runtime (keeping the build MIT all the way down). To produce a self-contained,
shareable `.dmg` like the release, run `bash scripts/package-release.sh`.

`package-release.sh` bundles a *pinned* Ghostscript version
(`EXPECTED_GHOSTSCRIPT_VERSION` in `scripts/bundle-ghostscript.sh`). If your
Homebrew has a different version the build stops on purpose; review the
changelog/CVEs and bump the pin, or re-run with
`ALLOW_GHOSTSCRIPT_VERSION_MISMATCH=1` to bundle anyway (not recommended).

`package-release.sh` also pins the ~20 libraries Ghostscript links against, by
hash, in `scripts/ghostscript-dependencies.txt`. If Homebrew's copies differ
the build stops; review their changelogs/CVEs and either regenerate the
manifest (delete it and re-run) or re-run with
`ALLOW_DEPENDENCY_MANIFEST_MISMATCH=1` to bundle anyway (not recommended).

> Why "Open Anyway"? Removing that one-time prompt entirely requires an Apple
> Developer Program membership ($99/yr) to notarize the app. The project is
> otherwise free and needs no account to build, sign, or run.

## Uninstall

```bash
bash scripts/uninstall.sh
```

## Existing files still show a blank icon?

Finder caches icons aggressively. After installing, force a refresh:

```bash
bash scripts/refresh-thumbnails.sh
```

New EPS files always get thumbnails immediately.

## Local checks (contributors)

Git hooks live in `githooks/` and are opt-in per clone — activate them once:

```bash
git config core.hooksPath githooks
```

`pre-commit` runs `shellcheck` on staged `scripts/**/*.sh` (subdirectories
included) and on the hooks themselves, plus SwiftLint (against the committed
`.swiftlint.yml` baseline) on staged Swift sources; `pre-push` runs
`bash scripts/build.sh` and then `xcodebuild test` in the same Release
configuration, so neither a broken build nor a failing test reaches the
remote. Needs
`brew install shellcheck swiftlint`. Prefix a single command with
`SKIP_HOOKS=1` to bypass them in an emergency.

## Project layout

| Path | What |
|------|------|
| `Sources/Host` | Host app (SwiftUI status window) |
| `Sources/QuickLook` | Quick Look preview extension |
| `Sources/Thumbnail` | Thumbnail extension |
| `Sources/RenderService` | Unsandboxed XPC render helper (runs `gs`) |
| `Sources/Shared` | XPC protocol + client, limits, admission + render-outcome rules, Ghostscript locator (compiled into every target) |
| `Tests` | XCTest unit tests for `Sources/Shared` plus the committed EPS fixtures in `Tests/Fixtures` (`EPSPreviewTests` target) |
| `scripts/` | Build / install / uninstall / thumbnail-refresh |
| `githooks/` | Opt-in local pre-commit / pre-push hooks |
| `.swiftlint.yml` | Enforced SwiftLint baseline for `Sources` and `Tests` |
| `project.yml` | XcodeGen project definition |

The `.xcodeproj` is generated from `project.yml` by `scripts/build.sh` and is
intentionally not committed.

## License

This project's code is **MIT** — see [LICENSE](LICENSE).

Build-from-source uses your own Homebrew Ghostscript (nothing AGPL is
distributed). The downloadable **release** bundles a self-contained
Ghostscript, which is **AGPL-3.0**; see [NOTICE.md](NOTICE.md) for details and
source links.
