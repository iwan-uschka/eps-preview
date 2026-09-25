import Foundation
import XCTest

/// `wantsInterpolation` decides whether a preview is drawn smoothed or
/// nearest-neighbour, so both a false positive (a crisp pixel figure blurred)
/// and a false negative are visible-but-silent. The scanner reads PostScript
/// tokens rather than substrings; these tests pin the cases where those two
/// readings disagree.
final class WantsInterpolationTests: XCTestCase {

    private func scan(_ source: String) -> Bool {
        RenderClient.wantsInterpolation(Data(source.utf8))
    }

    // MARK: - The flag itself

    func testAnExplicitInterpolateTrueOptsIn() {
        XCTAssertTrue(scan("<< /ImageType 1 /Interpolate true >> image"))
    }

    func testInterpolateFalseDoesNotOptIn() {
        XCTAssertFalse(scan("<< /ImageType 1 /Interpolate false >> image"))
    }

    func testAFileWithoutTheKeyDoesNotOptIn() {
        XCTAssertFalse(scan("%!PS-Adobe-3.0 EPSF-3.0\n0 0 moveto 10 10 lineto stroke\n"))
    }

    func testEmptyInputDoesNotOptIn() {
        XCTAssertFalse(RenderClient.wantsInterpolation(Data()))
    }

    func testTheMatchIsCaseInsensitive() {
        // PostScript names are case-sensitive, but Ghostscript, Illustrator and
        // matplotlib all emit their own casing; matching loosely here can only
        // over-smooth, never fail a render.
        XCTAssertTrue(scan("/INTERPOLATE TRUE"))
    }

    func testTheFlagIsFoundDeepInThePageBody() {
        // The image dictionary sits wherever the raster is drawn, so the scan
        // covers the whole buffer rather than a leading window.
        let filler = String(repeating: "0 0 moveto 1 1 lineto stroke\n", count: 5_000)
        XCTAssertTrue(scan("%!PS-Adobe-3.0 EPSF-3.0\n" + filler + "/Interpolate true\n"))
    }

    // MARK: - Token boundaries

    func testALongerNameEndingInTheKeyDoesNotCount() {
        XCTAssertFalse(scan("/MyInterpolateHack true def"))
    }

    func testANameStartingWithTheKeyDoesNotCount() {
        XCTAssertFalse(scan("/InterpolateAlways true def"))
    }

    func testTheValueMustBeItsOwnToken() {
        XCTAssertFalse(scan("/Interpolate truename"))
    }

    func testTheKeyAndValueMustNotBeRunTogether() {
        XCTAssertFalse(scan("/Interpolatetrue"))
    }

    func testSelfDelimitingCharactersCountAsTokenBoundaries() {
        // `>>` closes the dictionary immediately after the value, with no
        // white space — the common compact form.
        XCTAssertTrue(scan("<</Interpolate true>>"))
    }

    func testACommentMayStandBetweenTheKeyAndItsValue() {
        XCTAssertTrue(scan("/Interpolate % a generator's annotation\n true"))
    }

    // MARK: - Text that merely mentions the flag

    func testACommentAskingForInterpolationIsNotAnOptIn() {
        XCTAssertFalse(scan("%!PS-Adobe-3.0\n% /Interpolate true would be nicer here\nshowpage\n"))
    }

    func testAFigureThatDrawsTheWordsIsNotAnOptIn() {
        // A slide about interpolation, set as PostScript text, used to smooth
        // every raster on the page.
        XCTAssertFalse(scan("(Interpolate true) show"))
    }

    func testAnEscapedParenthesisDoesNotEndTheStringEarly() {
        XCTAssertFalse(scan(#"(a \) and Interpolate true) show"#))
    }

    func testANestedParenthesisDoesNotEndTheStringEarly() {
        XCTAssertFalse(scan("(outer (inner) Interpolate true) show"))
    }

    func testTheFlagStillCountsAfterAStringThatMentionsIt() {
        XCTAssertTrue(scan("(Interpolate true) show\n/Interpolate true"))
    }

    // MARK: - Binary DOS-EPS

    func testTheScanWorksOnABinaryDOSEPSHeader() {
        // A DOS-EPS file starts with a 30-byte binary header and may carry a
        // TIFF preview; the PostScript body behind it is still ASCII. Scanning
        // bytes rather than a decoded String is what makes this need no
        // special case.
        var data = Data([0xC5, 0xD0, 0xD3, 0xC6])
        data.append(Data([0x1E, 0x00, 0x00, 0x00]))         // PostScript offset
        data.append(Data([0x40, 0x00, 0x00, 0x00]))         // PostScript length
        data.append(Data(repeating: 0xFF, count: 18))       // preview pointers
        data.append(Data("%!PS-Adobe-3.0 EPSF-3.0\n<</Interpolate true>> image\n".utf8))

        XCTAssertNil(String(data: data, encoding: .utf8), "the fixture must not be valid UTF-8")
        XCTAssertTrue(RenderClient.wantsInterpolation(data))
    }
}
