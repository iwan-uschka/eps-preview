import Foundation
import XCTest

/// The refusals `RenderService` answers before any Ghostscript runs: a
/// descriptor that is not a readable, non-empty regular file or is over the
/// input limit is refused straight from `renderEPSToPDF`, and the staging
/// copy (`RenderService.stage`) fails rather than carrying on when it cannot
/// create its file or the input grew past the limit after the size check.
/// Nothing here reaches `GhostscriptLocator.locate()`, so the result does not
/// depend on whether this machine has a `gs`.
final class RenderServiceTests: XCTestCase {
    private var workDir = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// A file of `size` bytes, sparse where the filesystem allows, opened for
    /// reading.
    private func inputFile(size: Int, contents: Data = Data()) throws -> FileHandle {
        let url = workDir.appendingPathComponent("input-\(UUID().uuidString).eps")
        try contents.write(to: url)
        XCTAssertEqual(truncate(url.path, off_t(size)), 0, "sizing the fixture input must succeed")
        return try FileHandle(forReadingFrom: url)
    }

    /// Calls `renderEPSToPDF` and returns what it replied. Every case here is
    /// refused before the render queue is involved, but the wait is bounded
    /// anyway so a regression that lets one through fails instead of hanging.
    private func reply(for input: FileHandle) -> (pdf: Data?, failure: RenderFailure?) {
        let replied = expectation(description: "reply")
        var result: (Data?, RenderFailure?) = (nil, nil)
        RenderService().renderEPSToPDF(input: input) { pdf, code in
            result = (pdf, code.map { RenderFailure(xpcCode: $0) })
            replied.fulfill()
        }
        wait(for: [replied], timeout: 10)
        return result
    }

    // MARK: - Refused at the door

    // breaks-if: regularFileSize stops rejecting a descriptor that is not a regular file (the S_IFREG check).
    func testPipeInputIsRefusedAsUnreadable() {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close() }

        let result = reply(for: pipe.fileHandleForReading)

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.failure, .inputUnreadable)
    }

    // breaks-if: the `size > 0` half of renderEPSToPDF's first guard is dropped.
    func testEmptyFileIsRefusedAsUnreadable() throws {
        let result = reply(for: try inputFile(size: 0))

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.failure, .inputUnreadable)
    }

    // breaks-if: renderEPSToPDF's maxInputBytes guard is removed or loosened past the limit.
    func testInputOneByteOverTheLimitIsRefusedAsTooLarge() throws {
        let result = reply(for: try inputFile(size: RenderLimits.maxInputBytes + 1))

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.failure, .inputTooLarge)
    }

    // MARK: - Staging

    func testStagingCopiesFromOffsetZeroWhateverTheSharedOffset() throws {
        let contents = Data("%!PS-Adobe-3.0 EPSF-3.0\n".utf8)
        let input = try inputFile(size: contents.count, contents: contents)
        // NSXPC hands the service a duplicate of the extension's descriptor,
        // so the offset may be anywhere when staging starts.
        try input.seekToEnd()
        let staged = workDir.appendingPathComponent("staged.eps")

        try RenderService.stage(input, atPath: staged.path)

        XCTAssertEqual(try Data(contentsOf: staged), contents)
    }

    func testStagingAcceptsAnInputExactlyAtTheLimit() throws {
        let limit = 4096
        let input = try inputFile(size: limit)
        let staged = workDir.appendingPathComponent("staged.eps")

        try RenderService.stage(input, atPath: staged.path, limit: limit)

        let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, limit)
    }

    // breaks-if: stage ignores a false return from FileManager.createFile and carries on to open the path.
    func testStagingFailsWhenTheStagingFileCannotBeCreated() throws {
        let input = try inputFile(size: 16)
        let unreachable = workDir.appendingPathComponent("no-such-directory/staged.eps")

        XCTAssertThrowsError(try RenderService.stage(input, atPath: unreachable.path)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileWriteUnknown)
        }
    }

    // breaks-if: stage drops its running `copied <= maxInputBytes` cap and trusts the earlier fstat.
    func testStagingStopsAnInputThatGrewPastTheLimit() throws {
        // Called directly, as for a file that grew after renderEPSToPDF's
        // fstat: the copy itself must still refuse to go past the limit.
        let limit = 4096
        let input = try inputFile(size: limit + 1)
        let staged = workDir.appendingPathComponent("staged.eps")

        XCTAssertThrowsError(try RenderService.stage(input, atPath: staged.path, limit: limit)) { error in
            XCTAssertEqual(error as? RenderFailure, .inputTooLarge)
        }
    }
}
