import CoreGraphics

/// Where a thumbnail of a `pageSize`-sized page goes: the context Quick Look
/// should create for it, and the rect the page is drawn into inside that
/// context.
///
/// The page is fitted into `maximumSize` with its aspect ratio preserved, then
/// the context is padded out to `minimumSize` on whichever axis the fitted page
/// falls short of it. Quick Look rejects a reply whose context is smaller than
/// the minimum it asked for, and padding keeps a very long or very wide page
/// letterboxed and centered rather than stretched to fill. `pageRect` is that
/// fitted page centered in the context; where no padding is needed it covers
/// the context exactly, at the origin.
///
/// Sizes are in points, not device pixels. `QLThumbnailReply(contextSize:)`
/// applies the request's `scale` itself, which is why no scale is taken here —
/// a hand-built `CGContext` would have needed one.
///
/// Both axes are clamped to at least one point: `CGContext` refuses a
/// zero-sized bitmap, and a page thinner than a point (extreme aspect ratios,
/// sub-point media boxes) would otherwise fit to nothing.
///
/// `pageSize` must have positive width and height — callers reject empty pages
/// before asking for a layout.
func thumbnailLayout(pageSize: CGSize,
                     maximumSize: CGSize,
                     minimumSize: CGSize) -> (contextSize: CGSize, pageRect: CGRect) {
    let fit = min(maximumSize.width / pageSize.width, maximumSize.height / pageSize.height)
    let fitted = CGSize(width: max(pageSize.width * fit, 1),
                        height: max(pageSize.height * fit, 1))
    let contextSize = CGSize(width: max(fitted.width, minimumSize.width),
                             height: max(fitted.height, minimumSize.height))
    let pageRect = CGRect(x: (contextSize.width - fitted.width) / 2,
                          y: (contextSize.height - fitted.height) / 2,
                          width: fitted.width,
                          height: fitted.height)
    return (contextSize, pageRect)
}
