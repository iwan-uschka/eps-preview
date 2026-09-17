import CoreGraphics
import XCTest

final class ThumbnailGeometryTests: XCTestCase {

    func testFitsSquareBoxToRequestedMaximum() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      maximumSize: CGSize(width: 64, height: 64),
                                      scale: 1)
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 64)
    }

    func testMultipliesByDeviceScale() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      maximumSize: CGSize(width: 64, height: 64),
                                      scale: 2)
        XCTAssertEqual(size.width, 128)
        XCTAssertEqual(size.height, 128)
    }

    func testFractionalScaleIsHonored() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      maximumSize: CGSize(width: 64, height: 64),
                                      scale: 1.5)
        XCTAssertEqual(size.width, 96)
        XCTAssertEqual(size.height, 96)
    }

    func testLandscapeBoxIsLetterboxedNotStretched() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 200, height: 100),
                                      maximumSize: CGSize(width: 64, height: 64),
                                      scale: 1)
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 32)
    }

    func testPortraitBoxIsLetterboxedNotStretched() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 100, height: 200),
                                      maximumSize: CGSize(width: 64, height: 64),
                                      scale: 1)
        XCTAssertEqual(size.width, 32)
        XCTAssertEqual(size.height, 64)
    }

    func testNonSquareMaximumUsesTheTighterAxis() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      maximumSize: CGSize(width: 200, height: 50),
                                      scale: 1)
        XCTAssertEqual(size.width, 50)
        XCTAssertEqual(size.height, 50)
    }

    func testExtremeAspectRatioClampsShortAxisToOnePixel() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 500, height: 0.5),
                                      maximumSize: CGSize(width: 16, height: 16),
                                      scale: 1)
        XCTAssertEqual(size.width, 16)
        XCTAssertEqual(size.height, 1)
    }

    func testSubPixelResultClampsBothAxesToOnePixel() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      maximumSize: CGSize(width: 16, height: 16),
                                      scale: 0.01)
        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 1)
    }

    func testHalfPixelRoundsAwayFromZero() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 3, height: 3),
                                      maximumSize: CGSize(width: 10, height: 10),
                                      scale: 0.35)
        XCTAssertEqual(size.width, 4)
        XCTAssertEqual(size.height, 4)
    }

    func testBoxOriginDoesNotAffectPixelSize() {
        let atOrigin = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 120, height: 90),
                                          maximumSize: CGSize(width: 64, height: 64),
                                          scale: 2)
        let offset = thumbnailPixelSize(box: CGRect(x: -37, y: 512, width: 120, height: 90),
                                        maximumSize: CGSize(width: 64, height: 64),
                                        scale: 2)
        XCTAssertEqual(atOrigin.width, offset.width)
        XCTAssertEqual(atOrigin.height, offset.height)
    }

    func testBoxSmallerThanMaximumIsScaledUpToFill() {
        let size = thumbnailPixelSize(box: CGRect(x: 0, y: 0, width: 8, height: 4),
                                      maximumSize: CGSize(width: 64, height: 64),
                                      scale: 1)
        XCTAssertEqual(size.width, 64)
        XCTAssertEqual(size.height, 32)
    }
}
