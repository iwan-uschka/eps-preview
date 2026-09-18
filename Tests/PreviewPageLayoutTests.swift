import PDFKit
import XCTest

final class PreviewPageLayoutTests: XCTestCase {

    func testSinglePageDocumentFillsPanelEdgeToEdge() {
        let layout = PreviewPageLayout.displayMode(forPageCount: 1)
        XCTAssertEqual(layout.mode, .singlePage)
        XCTAssertFalse(layout.showsPageBreaks)
    }

    func testMultiPageDocumentScrollsWithVisiblePageBreaks() {
        let layout = PreviewPageLayout.displayMode(forPageCount: 3)
        XCTAssertEqual(layout.mode, .singlePageContinuous)
        XCTAssertTrue(layout.showsPageBreaks)
    }

    func testTwoPagesAlreadyCountAsMultiPage() {
        let layout = PreviewPageLayout.displayMode(forPageCount: 2)
        XCTAssertEqual(layout.mode, .singlePageContinuous)
        XCTAssertTrue(layout.showsPageBreaks)
    }
}
