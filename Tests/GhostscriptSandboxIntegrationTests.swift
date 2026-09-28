import Foundation
import XCTest

/// Actually launches `gs` under the profile `GhostscriptSandbox`/`GhostscriptLocator`
/// build, the same way `RenderService.render()` does — as opposed to
/// `GhostscriptSandboxTests`, which only asserts on the generated SBPL text.
///
/// A profile that denies something `gs` genuinely needs (the file-map-executable
/// grant its own dylibs need to load, say) still produces syntactically valid
/// SBPL: a text-only test would pass while the sandboxed render silently never
/// works. This exercises the whole thing end to end on a tiny fixed input, so
/// that failure mode fails the test suite instead of only a real render.
final class GhostscriptSandboxIntegrationTests: XCTestCase {

    private static let sandboxExecPath = "/usr/bin/sandbox-exec"

    func testRendersATinyEPSUnderTheGeneratedSandboxProfile() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec is not available on this machine")
        }
        guard let gs = GhostscriptLocator.locate() else {
            throw XCTSkip("no usable Ghostscript installed on this machine")
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
        let stem = "sandbox-integration-" + UUID().uuidString
        let inputURL = scratch.appendingPathComponent(stem + ".eps")
        let outputURL = scratch.appendingPathComponent(stem + ".pdf")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        let eps = """
        %!PS-Adobe-3.0 EPSF-3.0
        %%BoundingBox: 0 0 8 8
        0.5 setgray 0 0 8 8 rectfill
        showpage
        """
        try Data(eps.utf8).write(to: inputURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sandboxExecPath)
        process.environment = gs.environment
        process.arguments = [
            "-p", gs.sandboxProfile,
            gs.executablePath,
            "-dNOPAUSE", "-dBATCH", "-dQUIET",
            "-dSAFER",
            "-dEPSCrop",
            "-dAutoRotatePages=/None",
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.4",
            "-sOutputFile=" + outputURL.path,
            inputURL.path,
        ]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, """
            gs exited \(process.terminationStatus) under the generated sandbox profile — a profile \
            that blocks something gs needs (dylib loading, a resource file, ...) fails here even \
            though the profile text itself is well-formed SBPL.
            stderr:
            \(errorOutput)
            profile:
            \(gs.sandboxProfile)
            """)

        let rendered = try? Data(contentsOf: outputURL)
        XCTAssertNotNil(rendered, "sandboxed gs must produce an output file")
        XCTAssertFalse(rendered?.isEmpty ?? true, "sandboxed gs must produce a non-empty PDF")
    }
}
