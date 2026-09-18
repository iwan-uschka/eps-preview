import CoreGraphics
import PDFKit
import XCTest

/// Pins where `ThumbnailDrawing.draw` actually puts ink.
///
/// The context Quick Look hands the thumbnail extension only exists inside a
/// live thumbnail request, so these draw into a hand-built `CGBitmapContext`
/// standing in for it — same coordinate system (origin bottom-left, y up) and
/// same pixel dimensions (`contextSize * scale`) that
/// `QLThumbnailReply(contextSize:drawingBlock:)` documents.
///
/// The bitmap is deliberately left *unpainted* rather than pre-filled, so a
/// region the drawing never reaches reads back as transparent and is
/// distinguishable from one it painted white.
final class ThumbnailDrawingTests: XCTestCase {

    // MARK: - Fixture

    /// A one-page PDF with a differently coloured 20×20 square in each corner,
    /// on a deliberately non-square (1:2 portrait) page — the shape that made
    /// the real-world mis-positioning obvious. No crop box, so
    /// `bounds(for: .cropBox)` falls back to this media box.
    private static let markerPageSize = CGSize(width: 100, height: 200)

    private func markerPage() throws -> PDFPage {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Self.markerPageSize)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        for (color, rect) in [
            (Marker.bottomLeft, CGRect(x: 0, y: 0, width: 20, height: 20)),
            (Marker.bottomRight, CGRect(x: 80, y: 0, width: 20, height: 20)),
            (Marker.topLeft, CGRect(x: 0, y: 180, width: 20, height: 20)),
            (Marker.topRight, CGRect(x: 80, y: 180, width: 20, height: 20)),
        ] {
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(rect)
        }
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        return try XCTUnwrap(document.page(at: 0))
    }

    private enum Marker {
        static let bottomLeft: (CGFloat, CGFloat, CGFloat) = (0, 0, 1)   // blue
        static let bottomRight: (CGFloat, CGFloat, CGFloat) = (0, 1, 0)  // green
        static let topLeft: (CGFloat, CGFloat, CGFloat) = (1, 0, 0)      // red
        static let topRight: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)     // black
        static let white: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)
    }

    // MARK: - Bitmap standing in for Quick Look's context

    /// `contextSize * scale` pixels, transform left at identity — exactly what
    /// `QLThumbnailReply` creates.
    private func bitmap(contextSize: CGSize, scale: CGFloat) throws -> CGContext {
        try XCTUnwrap(CGContext(data: nil,
                                width: Int(contextSize.width * scale),
                                height: Int(contextSize.height * scale),
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    /// Samples one pixel, addressed in Core Graphics coordinates (origin
    /// bottom-left) so the expectations below read the same way the page does.
    private func pixel(_ context: CGContext, x: Int, y: Int) throws -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        let base = try XCTUnwrap(context.data).bindMemory(to: UInt8.self,
                                                          capacity: context.bytesPerRow * context.height)
        let row = context.height - 1 - y
        let offset = row * context.bytesPerRow + x * 4
        return (CGFloat(base[offset]) / 255, CGFloat(base[offset + 1]) / 255,
                CGFloat(base[offset + 2]) / 255, CGFloat(base[offset + 3]) / 255)
    }

    private func assertPixel(_ context: CGContext, x: Int, y: Int,
                             is expected: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1,
                             _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try pixel(context, x: x, y: y)
        let tolerance: CGFloat = 0.1
        XCTAssertEqual(actual.0, expected.0, accuracy: tolerance, "\(message) — red at (\(x),\(y))",
                       file: file, line: line)
        XCTAssertEqual(actual.1, expected.1, accuracy: tolerance, "\(message) — green at (\(x),\(y))",
                       file: file, line: line)
        XCTAssertEqual(actual.2, expected.2, accuracy: tolerance, "\(message) — blue at (\(x),\(y))",
                       file: file, line: line)
        XCTAssertEqual(actual.3, alpha, accuracy: tolerance, "\(message) — alpha at (\(x),\(y))",
                       file: file, line: line)
    }

    // MARK: - The layout under test
    //
    // A 100×200 page fitted to 60×120 and centered in a 100×180 context: 20 pt
    // of padding left and right, 30 pt above and below. Nothing here is 1:1
    // with the canvas, which is the point — a page that happens to cover its
    // whole context hides both an offset bug and a scale bug.

    private let contextSize = CGSize(width: 100, height: 180)
    private let pageRect = CGRect(x: 20, y: 30, width: 60, height: 120)

    // MARK: - Tests

    func testMarkersLandWhereTheLayoutPutsThemAtRetinaScale() throws {
        let scale: CGFloat = 2
        let context = try bitmap(contextSize: contextSize, scale: scale)
        ThumbnailDrawing.draw(page: try markerPage(),
                              pageSize: Self.markerPageSize,
                              contextSize: contextSize,
                              pageRect: pageRect,
                              scale: scale,
                              interpolate: false,
                              into: context)

        // Each 20 pt marker maps to 12 pt (20 × 60/100) inside pageRect, so in
        // pixels: x 40…64 and 136…160, y 60…84 and 276…300. Sample the middles.
        try assertPixel(context, x: 52, y: 72, is: Marker.bottomLeft, "page's bottom-left corner")
        try assertPixel(context, x: 148, y: 72, is: Marker.bottomRight, "page's bottom-right corner")
        try assertPixel(context, x: 52, y: 288, is: Marker.topLeft, "page's top-left corner")
        try assertPixel(context, x: 148, y: 288, is: Marker.topRight, "page's top-right corner")

        // The page's own middle is blank, and so is the letterbox padding
        // around it — all of it painted white, none of it left transparent.
        try assertPixel(context, x: 100, y: 180, is: Marker.white, "middle of the page")
        try assertPixel(context, x: 10, y: 180, is: Marker.white, "padding left of the page")
        try assertPixel(context, x: 190, y: 180, is: Marker.white, "padding right of the page")
        try assertPixel(context, x: 100, y: 10, is: Marker.white, "padding below the page")
        try assertPixel(context, x: 100, y: 350, is: Marker.white, "padding above the page")
    }

    func testEveryCornerOfTheScaledCanvasIsPaintedNotLeftTransparent() throws {
        // The regression this pins: drawing in points into a context sized in
        // pixels filled only the bottom-left 1/scale of the canvas and left
        // three quarters of a Retina thumbnail transparent.
        let scale: CGFloat = 2
        let context = try bitmap(contextSize: contextSize, scale: scale)
        ThumbnailDrawing.draw(page: try markerPage(),
                              pageSize: Self.markerPageSize,
                              contextSize: contextSize,
                              pageRect: pageRect,
                              scale: scale,
                              interpolate: false,
                              into: context)

        let maxX = context.width - 1, maxY = context.height - 1
        try assertPixel(context, x: 0, y: 0, is: Marker.white, "bottom-left of the canvas")
        try assertPixel(context, x: maxX, y: 0, is: Marker.white, "bottom-right of the canvas")
        try assertPixel(context, x: 0, y: maxY, is: Marker.white, "top-left of the canvas")
        try assertPixel(context, x: maxX, y: maxY, is: Marker.white, "top-right of the canvas")
    }

    func testUnscaledRequestIsNotScaledTwice() throws {
        // scale 1 was the one case the regression got right; it must stay
        // right, or the fix has simply moved the error.
        let scale: CGFloat = 1
        let context = try bitmap(contextSize: contextSize, scale: scale)
        ThumbnailDrawing.draw(page: try markerPage(),
                              pageSize: Self.markerPageSize,
                              contextSize: contextSize,
                              pageRect: pageRect,
                              scale: scale,
                              interpolate: false,
                              into: context)

        try assertPixel(context, x: 26, y: 36, is: Marker.bottomLeft, "page's bottom-left corner")
        try assertPixel(context, x: 74, y: 36, is: Marker.bottomRight, "page's bottom-right corner")
        try assertPixel(context, x: 26, y: 144, is: Marker.topLeft, "page's top-left corner")
        try assertPixel(context, x: 74, y: 144, is: Marker.topRight, "page's top-right corner")
        try assertPixel(context, x: context.width - 1, y: context.height - 1, is: Marker.white,
                        "top-right of the canvas")
    }
}
