# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

Add entries under `## [Unreleased]` as you go; `scripts/package-release.sh`
turns that section into the next version's entry and publishes it as the
release notes.

## [Unreleased]

## [1.0.0] - 2026-06-26

### Added

- Spacebar Quick Look previews and Finder thumbnails for `.eps` / `.ps` files
  on macOS 15 (Sequoia) and 26 (Tahoe), via sandboxed Quick Look and
  Thumbnail extensions.
- Unsandboxed `RenderService.xpc`, embedded in each extension, that converts
  the EPS to PDF with Ghostscript.
- Interpolation that honours the source's `/Interpolate` flag: nearest
  neighbour by default, smoothing only when the EPS opts in.
- Ad-hoc signed build (`scripts/build.sh`) and install / uninstall /
  thumbnail-refresh scripts; no Apple Developer account needed.
- Self-contained release DMG (`scripts/package-release.sh`) with a bundled
  Ghostscript; source builds use the system Ghostscript instead.
