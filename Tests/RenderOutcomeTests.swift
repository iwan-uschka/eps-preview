import Foundation
import XCTest

/// Covers the four user-facing outcomes a finished Ghostscript can produce —
/// timeout, output-size refusal, non-zero exit and success — plus the guards
/// on the file it left behind. Driven through `RenderTermination` rather than
/// a live `Process`, because a signal death and a specific exit status cannot
/// be fabricated on a real one.
final class RenderOutcomeTests: XCTestCase {

    // MARK: - Helpers

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("render-outcome-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// Path of a would-be Ghostscript output file; nothing is written unless a
    /// test asks for it.
    private func outputPath(_ name: String = "out.pdf") -> String {
        directory.appendingPathComponent(name).path
    }

    private func write(_ bytes: Data, to path: String) throws {
        try bytes.write(to: URL(fileURLWithPath: path))
    }

    /// A file of `size` bytes that costs no disk: APFS keeps the hole sparse,
    /// so the 64 MB limit can be exceeded without writing 64 MB.
    private func writeSparseFile(ofSize size: Int, to path: String) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }

    private func exited(_ status: Int32) -> RenderTermination {
        RenderTermination(killedBySignal: false, status: status, timedOut: false)
    }

    private func signalled(_ signal: Int32, timedOut: Bool = false) -> RenderTermination {
        RenderTermination(killedBySignal: true, status: signal, timedOut: timedOut)
    }

    // MARK: - Success

    func testSuccessfulRenderReturnsTheWrittenPDF() throws {
        let path = outputPath()
        let pdf = Data("%PDF-1.4 pretend document".utf8)
        try write(pdf, to: path)

        let result = RenderOutcome.result(for: exited(0), errorOutput: Data(), outputPath: path)

        XCTAssertEqual(result.pdf, pdf)
        XCTAssertNil(result.error)
    }

    // MARK: - Timeout

    func testWatchdogKillIsReportedAsATimeout() {
        let result = RenderOutcome.result(for: signalled(SIGTERM, timedOut: true),
                                          errorOutput: Data(),
                                          outputPath: outputPath())

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.error,
                       "Ghostscript timed out after \(Int(RenderLimits.renderTimeout))s "
                           + "and was terminated.")
    }

    func testARenderThatFinishedAsTheWatchdogFiredStillCounts() throws {
        let path = outputPath()
        let pdf = Data("%PDF-1.4 raced the watchdog".utf8)
        try write(pdf, to: path)

        // `timedOut` is set, but the child exited on its own rather than being
        // signalled — the finished render wins.
        let termination = RenderTermination(killedBySignal: false, status: 0, timedOut: true)
        let result = RenderOutcome.result(for: termination, errorOutput: Data(), outputPath: path)

        XCTAssertEqual(result.pdf, pdf)
        XCTAssertNil(result.error)
    }

    // MARK: - Output size

    func testSIGXFSZIsReportedAsTheOutputLimit() {
        let result = RenderOutcome.result(for: signalled(SIGXFSZ),
                                          errorOutput: Data(),
                                          outputPath: outputPath())

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.error,
                       "The rendered PDF exceeds the "
                           + "\(RenderLimits.maxOutputBytes / (1024 * 1024)) MB preview output limit.")
    }

    func testAnOversizedOutputFileIsRejected() throws {
        let path = outputPath()
        try writeSparseFile(ofSize: RenderLimits.maxOutputBytes + 1, to: path)

        let result = RenderOutcome.result(for: exited(0), errorOutput: Data(), outputPath: path)

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.error,
                       "The rendered PDF exceeds the "
                           + "\(RenderLimits.maxOutputBytes / (1024 * 1024)) MB preview output limit.")
    }

    func testAFileExactlyAtTheLimitIsStillAccepted() throws {
        let path = outputPath()
        try writeSparseFile(ofSize: RenderLimits.maxOutputBytes, to: path)

        let result = RenderOutcome.result(for: exited(0), errorOutput: Data(), outputPath: path)

        XCTAssertEqual(result.pdf?.count, RenderLimits.maxOutputBytes)
        XCTAssertNil(result.error)
    }

    // MARK: - Non-zero exit

    func testNonZeroExitCarriesGhostscriptsOwnDiagnostic() {
        let stderr = Data("Error: /undefined in --xshow--\n".utf8)

        let result = RenderOutcome.result(for: exited(1), errorOutput: stderr, outputPath: outputPath())

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.error,
                       "Ghostscript exited with status 1. Error: /undefined in --xshow--\n")
    }

    func testASignalThatIsNeitherTimeoutNorSizeFallsThroughToTheStatus() {
        let stderr = Data("Fatal: segmentation fault".utf8)

        let result = RenderOutcome.result(for: signalled(SIGSEGV),
                                          errorOutput: stderr,
                                          outputPath: outputPath())

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.error,
                       "Ghostscript exited with status \(SIGSEGV). Fatal: segmentation fault")
    }

    // MARK: - Missing or empty output

    func testSuccessWithNoOutputFileIsReportedAsNoOutput() {
        let result = RenderOutcome.result(for: exited(0),
                                          errorOutput: Data(),
                                          outputPath: outputPath("never-written.pdf"))

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.error, "Ghostscript reported success but produced no PDF output.")
    }

    func testSuccessWithAnEmptyOutputFileIsReportedAsNoOutput() throws {
        let path = outputPath()
        try write(Data(), to: path)

        let result = RenderOutcome.result(for: exited(0), errorOutput: Data(), outputPath: path)

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.error, "Ghostscript reported success but produced no PDF output.")
    }

    // MARK: - Diagnostics

    func testNonUTF8DiagnosticsAreDecodedAsLatin1RatherThanDropped() {
        // "Error: échec" with the é as a lone 0xE9 — valid Latin-1, invalid
        // UTF-8, and exactly what a font or DSC warning quoting the file's own
        // bytes looks like.
        let stderr = Data([0x45, 0x72, 0x72, 0x6F, 0x72, 0x3A, 0x20, 0xE9, 0x63, 0x68, 0x65, 0x63])
        XCTAssertNil(String(data: stderr, encoding: .utf8), "the fixture must not be valid UTF-8")

        XCTAssertEqual(RenderOutcome.diagnostic(stderr), "Error: échec")
    }

    func testANonUTF8DiagnosticIsAlsoTruncated() {
        var stderr = Data([0xE9])
        stderr.append(Data(String(repeating: "x", count: RenderOutcome.maxErrorMessageCharacters).utf8))

        let text = RenderOutcome.diagnostic(stderr)

        XCTAssertEqual(text.count, RenderOutcome.maxErrorMessageCharacters)
        XCTAssertTrue(text.hasPrefix("é"), "the Latin-1 decoding must survive truncation, got \(text)")
    }

    func testDiagnosticIsTruncatedToTheMessageLimit() {
        let stderr = Data(String(repeating: "e", count: RenderOutcome.maxErrorMessageCharacters + 50).utf8)

        XCTAssertEqual(RenderOutcome.diagnostic(stderr).count, RenderOutcome.maxErrorMessageCharacters)
    }
}
