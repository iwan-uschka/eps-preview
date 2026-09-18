import PDFKit

/// Paints a rendered page into the bitmap context Quick Look hands the
/// thumbnail extension's drawing block.
///
/// Factored out of `ThumbnailProvider` for the same reason
/// `ThumbnailGeometry` was: the real context only exists inside a live Quick
/// Look thumbnail request, so the transform chain can only be pinned by a
/// test if it can be pointed at a `CGBitmapContext` built by hand.
///
/// The context is a `CGBitmapContext` in Core Graphics' own coordinate system
/// (origin bottom-left, y up) — `QLThumbnailReply`'s header says so, and it
/// holds: `PDFPage.draw(with:to:)` needs no flip here.
enum ThumbnailDrawing {

    /// - Parameters:
    ///   - page: the page to paint, sized `pageSize` (already rotation-aware,
    ///     see `PDFPageGeometry.displaySize(of:)`).
    ///   - contextSize: the `contextSize` handed to `QLThumbnailReply`, in points.
    ///   - pageRect: where the page goes inside that context, in points.
    ///   - scale: `QLFileThumbnailRequest.scale`.
    ///   - interpolate: the source's interpolation intent (see `RenderClient`).
    static func draw(page: PDFPage,
                     pageSize: CGSize,
                     contextSize: CGSize,
                     pageRect: CGRect,
                     scale: CGFloat,
                     interpolate: Bool,
                     into context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        // Quick Look sizes the bitmap at `contextSize * scale` *pixels* but
        // leaves its transform at identity — "the size of the context will be
        // (scale * x, scale * y)" is about the pixel dimensions only, not the
        // coordinate system. Everything below is in points, so the scale has
        // to be applied here; without it the whole thumbnail is drawn into the
        // bottom-left 1/scale of the canvas and the rest stays transparent.
        context.scaleBy(x: scale, y: scale)

        // White background over the whole canvas, not just the fitted page:
        // ThumbnailGeometry.layout pads the context out to the requested
        // minimum, and that letterbox margin would otherwise stay transparent
        // (documents render on white).
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: contextSize))

        context.interpolationQuality = interpolate ? .high : .none

        context.translateBy(x: pageRect.origin.x, y: pageRect.origin.y)
        context.scaleBy(x: pageRect.width / pageSize.width,
                        y: pageRect.height / pageSize.height)
        page.draw(with: PDFPageGeometry.displayBox, to: context)
    }
}
