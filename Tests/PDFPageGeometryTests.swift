import CoreGraphics
import PDFKit
import XCTest

final class PDFPageGeometryTests: XCTestCase {

    /// A one-page PDF with no crop box, so `bounds(for: .cropBox)` falls back
    /// to this media box — exercising the same fallback `PDFPageGeometry`'s
    /// doc comment relies on.
    private func onePagePDF(width: CGFloat, height: CGFloat) throws -> PDFPage {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(data: data as Data))
        return try XCTUnwrap(document.page(at: 0))
    }

    func testDisplaySizeWithNoRotationMatchesTheMediaBox() throws {
        let page = try onePagePDF(width: 200, height: 100)
        XCTAssertEqual(PDFPageGeometry.displaySize(of: page), CGSize(width: 200, height: 100))
    }

    func testDisplaySizeAppliesTheQuarterTurnRotation() throws {
        let page = try onePagePDF(width: 200, height: 100)
        page.rotation = 90
        XCTAssertEqual(PDFPageGeometry.displaySize(of: page), CGSize(width: 100, height: 200))
    }

    func testUnrotatedSizeIsUnchanged() {
        XCTAssertEqual(PDFPageGeometry.rotatedSize(CGSize(width: 100, height: 50), byDegrees: 0),
                       CGSize(width: 100, height: 50))
    }

    func test90DegreesSwapsWidthAndHeight() {
        XCTAssertEqual(PDFPageGeometry.rotatedSize(CGSize(width: 100, height: 50), byDegrees: 90),
                       CGSize(width: 50, height: 100))
    }

    func test270DegreesSwapsWidthAndHeight() {
        XCTAssertEqual(PDFPageGeometry.rotatedSize(CGSize(width: 100, height: 50), byDegrees: 270),
                       CGSize(width: 50, height: 100))
    }

    func test180DegreesIsUnchanged() {
        XCTAssertEqual(PDFPageGeometry.rotatedSize(CGSize(width: 100, height: 50), byDegrees: 180),
                       CGSize(width: 100, height: 50))
    }

    func testNegativeDegreesNormalizeBeforeSwapping() {
        XCTAssertEqual(PDFPageGeometry.rotatedSize(CGSize(width: 100, height: 50), byDegrees: -90),
                       CGSize(width: 50, height: 100))
    }

    func testDegreesBeyond360Normalize() {
        XCTAssertEqual(PDFPageGeometry.rotatedSize(CGSize(width: 100, height: 50), byDegrees: 450),
                       CGSize(width: 50, height: 100))
    }
}
