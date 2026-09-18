import Foundation
import XCTest

/// Guards the committed `Tests/Fixtures` set: these files are the shared
/// reference inputs for both automated tests and manual Quick Look checks, so
/// a truncated or renamed fixture must fail loudly rather than silently skip.
final class FixtureTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Fixtures.url(name),
                               "missing fixture \(name)")
        return try Data(contentsOf: url)
    }

    private func latin1(_ data: Data) throws -> String {
        try XCTUnwrap(String(data: data, encoding: .isoLatin1))
    }

    func testMinimalAsciiFixtureIsAConformingEPSF() throws {
        let text = try latin1(fixture("minimal-ascii.eps"))
        XCTAssertTrue(text.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"))
        XCTAssertTrue(text.contains("%%BoundingBox: 0 0 100 100"))
        XCTAssertTrue(text.contains("showpage"))
    }

    func testInterpolateFixturesCarryTheOppositeDirectives() throws {
        let wants = try latin1(fixture("interpolate-true.eps"))
        let declines = try latin1(fixture("interpolate-false.eps"))
        XCTAssertTrue(wants.contains("/Interpolate true"))
        XCTAssertFalse(wants.contains("/Interpolate false"))
        XCTAssertTrue(declines.contains("/Interpolate false"))
        XCTAssertFalse(declines.contains("/Interpolate true"))
    }

    func testInterpolationIntentIsReadFromTheSource() throws {
        XCTAssertTrue(RenderClient.wantsInterpolation(try fixture("interpolate-true.eps")))
        XCTAssertFalse(RenderClient.wantsInterpolation(try fixture("interpolate-false.eps")))
        XCTAssertFalse(RenderClient.wantsInterpolation(try fixture("minimal-ascii.eps")))
    }

    func testBinaryDOSFixtureHasAWellFormedPreviewHeader() throws {
        let data = try fixture("binary-dos-eps-with-preview.eps")
        // Every bounds-dependent read below is gated on a `guard`, not a plain
        // assertion: a truncated fixture has to report a readable failure
        // instead of trapping on an out-of-range subscript and taking the rest
        // of the test process down with it.
        guard data.count > 30 else {
            XCTFail("fixture too short: \(data.count) bytes")
            return
        }
        XCTAssertEqual(Array(data.prefix(4)), [0xC5, 0xD0, 0xD3, 0xC6])

        func word(at offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << (8 * $1) }
        }
        let psOffset = word(at: 4), psLength = word(at: 8)
        let tiffOffset = word(at: 20), tiffLength = word(at: 24)

        XCTAssertEqual(psOffset, 30)
        guard tiffOffset == psOffset + psLength,
              data.count == tiffOffset + tiffLength,
              tiffLength >= 4 else {
            XCTFail("inconsistent header offsets/lengths: ps \(psOffset)+\(psLength), "
                    + "tiff \(tiffOffset)+\(tiffLength), file \(data.count) bytes")
            return
        }

        let start = data.startIndex + psOffset
        let ps = try latin1(data[start..<(start + psLength)])
        XCTAssertTrue(ps.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"))

        let tiffStart = data.startIndex + tiffOffset
        XCTAssertEqual(Array(data[tiffStart..<(tiffStart + 4)]), [0x49, 0x49, 0x2A, 0x00])
    }
}

/// `Tests/Fixtures` is copied into the test bundle as a folder reference, so
/// fixtures keep their directory name instead of being flattened into
/// `Resources/`.
enum Fixtures {
    static func url(_ name: String) -> URL? {
        guard let resources = Bundle(for: FixtureTests.self).resourceURL else { return nil }
        let url = resources.appendingPathComponent("Fixtures").appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
