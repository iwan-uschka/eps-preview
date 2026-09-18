import PDFKit

/// How a rendered document is paged in the Quick Look panel. Factored out of
/// `PreviewViewController` so the page-count rule is unit-testable without a
/// Quick Look extension host, the same way `ThumbnailGeometry.layout` is for
/// the thumbnail extension.
enum PreviewPageLayout {
    /// A one-page EPS should fill the panel edge to edge, but a multi-page
    /// PostScript file has to scroll with visible page breaks — otherwise
    /// page 1 looks like the whole file.
    static func displayMode(forPageCount pageCount: Int) -> (mode: PDFDisplayMode, showsPageBreaks: Bool) {
        let isMultiPage = pageCount > 1
        return (isMultiPage ? .singlePageContinuous : .singlePage, isMultiPage)
    }
}
