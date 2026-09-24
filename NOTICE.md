# Notices and licenses

EPS Preview's own source code is licensed under the **MIT License**
(see [LICENSE](LICENSE)).

## Bundled Ghostscript (release builds only)

The downloadable release (`.dmg`) bundles a self-contained build of
**Ghostscript**, which is licensed under the **GNU Affero General Public
License v3.0 (AGPL-3.0)**.

- Ghostscript home page: https://www.ghostscript.com/
- Source code: https://github.com/ArtifexSoftware/ghostpdl-downloads
  (releases build a pinned Ghostscript version from upstream source — see
  `EXPECTED_GHOSTSCRIPT_VERSION` / `GHOSTSCRIPT_SOURCE_SHA256` in
  `scripts/bundle-ghostscript.sh`, and the `GHOSTSCRIPT_PROVENANCE.txt`
  shipped inside the app bundle, for the exact version and hash of the build
  you have). The build passes `--without-tesseract`, so the OCR device — and
  the tesseract/leptonica/libarchive dependency closure it otherwise pulls
  in — is never built; this EPS→PDF converter never exercises OCR.

The bundled Ghostscript also carries the shared libraries it links against
(libfreetype, libtiff, libopenjp2, libidn, libintl and others — the exact set
and hashes are in `scripts/ghostscript-dependencies.txt` and in the shipped
`GHOSTSCRIPT_PROVENANCE.txt`). Each remains under its own license (FTL/GPLv2,
LGPL, Apache-2.0, BSD and similar); they are sourced unmodified from
Homebrew's formulae.

When you **build from source** (`scripts/build.sh`) instead of using a
release, Ghostscript is **not** bundled — the app calls the copy you install
yourself via Homebrew — so the build-from-source app is MIT all the way down.

Because the release binary combines this MIT code with AGPL Ghostscript, the
**release artifact as distributed is covered by the AGPL-3.0** with respect to
Ghostscript. The corresponding Ghostscript source is available at the links
above.
