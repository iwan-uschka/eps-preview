import CoreGraphics

/// Pixel dimensions for a thumbnail of `box`, fitted into `maximumSize` with
/// the aspect ratio preserved, at device `scale`.
///
/// Clamped to at least 1×1: `CGContext` refuses a zero-sized bitmap, and a
/// page thinner than one device pixel (extreme aspect ratios, sub-pixel media
/// boxes) would otherwise round down to nothing.
///
/// `box` must have positive width and height — callers reject empty pages
/// before asking for a size.
func thumbnailPixelSize(box: CGRect,
                        maximumSize: CGSize,
                        scale: CGFloat) -> (width: Int, height: Int) {
    let fit = min(maximumSize.width / box.width, maximumSize.height / box.height)
    return (max(Int((box.width * fit * scale).rounded()), 1),
            max(Int((box.height * fit * scale).rounded()), 1))
}
