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
/// Sizes are in points, not device pixels: `QLThumbnailReply(contextSize:)`
/// multiplies the *pixel* dimensions of the bitmap it creates by the request's
/// `scale`, so the size handed to it must not be pre-scaled. It does not scale
/// that bitmap's transform to match, though — putting the request's `scale`
/// back into the coordinate system is `ThumbnailDrawing`'s job, not this one's.
///
/// Both axes are clamped to at least one point: `CGContext` refuses a
/// zero-sized bitmap, and a page thinner than a point (extreme aspect ratios,
/// sub-point media boxes) would otherwise fit to nothing.
///
/// `pageSize` must have positive width and height — callers reject empty pages
/// before asking for a layout. `maximumSize` must be positive on both axes for
/// the same reason: a zero on either axis makes the fit scale zero, so both
/// sides hit the one-point clamp and the aspect ratio is lost. (`minimumSize`
/// may be zero — that simply asks for no padding.)
enum ThumbnailGeometry {
    static func layout(pageSize: CGSize,
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
}
