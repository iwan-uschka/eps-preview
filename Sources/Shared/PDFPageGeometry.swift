import PDFKit

/// Single source of truth for how a rendered page is framed, so the spacebar
/// preview and the Finder thumbnail agree for pages that carry a `/Rotate`
/// value or a crop box that differs from the media box.
enum PDFPageGeometry {
    /// The crop box is what `PDFView` displays by default, and PDFKit already
    /// falls back to the media box when a page has no crop box (intersecting
    /// with the media box either way), so this one choice covers both.
    static let displayBox: PDFDisplayBox = .cropBox

    /// Size the page occupies on screen. `bounds(for:)` is in unrotated page
    /// space while `draw(with:to:)` — the call `PDFView` makes for each page —
    /// applies the rotation, so the two have to be combined here.
    static func displaySize(of page: PDFPage) -> CGSize {
        rotatedSize(page.bounds(for: displayBox).size, byDegrees: page.rotation)
    }

    static func rotatedSize(_ size: CGSize, byDegrees degrees: Int) -> CGSize {
        let normalized = ((degrees % 360) + 360) % 360
        guard normalized == 90 || normalized == 270 else { return size }
        return CGSize(width: size.height, height: size.width)
    }
}
