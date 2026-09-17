import CoreGraphics
import XCTest

final class ThumbnailGeometryTests: XCTestCase {

    /// No padding wanted: a zero minimum lets the max-fit half be exercised on
    /// its own, the way `thumbnailPixelSize` used to be before the thumbnail
    /// pipeline started padding to `request.minimumSize`.
    private let noMinimum = CGSize.zero

    // MARK: - Fitting into the maximum

    func testFitsSquarePageToRequestedMaximum() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 100, height: 100),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.contextSize, CGSize(width: 64, height: 64))
    }

    func testLandscapePageIsLetterboxedNotStretched() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 200, height: 100),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.contextSize, CGSize(width: 64, height: 32))
    }

    func testPortraitPageIsLetterboxedNotStretched() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 100, height: 200),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.contextSize, CGSize(width: 32, height: 64))
    }

    func testNonSquareMaximumUsesTheTighterAxis() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 100, height: 100),
                                     maximumSize: CGSize(width: 200, height: 50),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.contextSize, CGSize(width: 50, height: 50))
    }

    func testPageSmallerThanMaximumIsScaledUpToFill() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 8, height: 4),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.contextSize, CGSize(width: 64, height: 32))
    }

    func testUnpaddedPageRectCoversTheWholeContext() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 200, height: 100),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.pageRect, CGRect(x: 0, y: 0, width: 64, height: 32))
    }

    // MARK: - Padding out to the minimum

    func testContextIsPaddedToMinimumOnBothAxes() {
        // Fitted is 64×64, so a 100×100 minimum pads both ways.
        let layout = thumbnailLayout(pageSize: CGSize(width: 100, height: 100),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(layout.contextSize, CGSize(width: 100, height: 100))
    }

    func testPaddedPageIsCenteredInTheContext() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 100, height: 100),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: CGSize(width: 100, height: 100))
        // (100 - 64) / 2 on each axis, and the page keeps its fitted size —
        // padding must not scale it up to fill the minimum.
        XCTAssertEqual(layout.pageRect, CGRect(x: 18, y: 18, width: 64, height: 64))
    }

    func testOnlyTheAxisBelowTheMinimumIsPadded() {
        // A wide page fits to 64×32. A 40×40 minimum is already satisfied on
        // width but not on height, so only height is padded — and only that
        // axis gets a centering offset.
        let layout = thumbnailLayout(pageSize: CGSize(width: 200, height: 100),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: CGSize(width: 40, height: 40))
        XCTAssertEqual(layout.contextSize, CGSize(width: 64, height: 40))
        XCTAssertEqual(layout.pageRect, CGRect(x: 0, y: 4, width: 64, height: 32))
    }

    func testMinimumSmallerThanFittedAddsNoPadding() {
        let layout = thumbnailLayout(pageSize: CGSize(width: 100, height: 100),
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: CGSize(width: 16, height: 16))
        XCTAssertEqual(layout.contextSize, CGSize(width: 64, height: 64))
        XCTAssertEqual(layout.pageRect, CGRect(x: 0, y: 0, width: 64, height: 64))
    }

    // MARK: - Degenerate pages

    func testExtremeAspectRatioClampsShortAxisToOnePoint() {
        // Fits to 16×0.016, which would be a zero-height context once Quick
        // Look rasterizes it.
        let layout = thumbnailLayout(pageSize: CGSize(width: 500, height: 0.5),
                                     maximumSize: CGSize(width: 16, height: 16),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.contextSize, CGSize(width: 16, height: 1))
        XCTAssertEqual(layout.pageRect, CGRect(x: 0, y: 0, width: 16, height: 1))
    }

    func testPageOriginIsIrrelevantBecauseOnlySizeIsTaken() {
        // Kept from the pixel-size tests this replaced: the media box's origin
        // must never reach the layout. It cannot now — the signature takes a
        // CGSize — and this pins that it stays that way.
        let layout = thumbnailLayout(pageSize: CGRect(x: -37, y: 512, width: 120, height: 90).size,
                                     maximumSize: CGSize(width: 64, height: 64),
                                     minimumSize: noMinimum)
        XCTAssertEqual(layout.contextSize, CGSize(width: 64, height: 48))
    }
}
