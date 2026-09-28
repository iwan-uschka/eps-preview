import Foundation
import XCTest

/// Actually launches `gs` under the profile `GhostscriptSandbox`/`GhostscriptLocator`
/// build, through the same `GhostscriptLaunch` wrapper `RenderService.render()`
/// uses — as opposed to `GhostscriptSandboxTests`, which only asserts on the
/// generated SBPL text.
///
/// A profile that denies something `gs` genuinely needs (the file-map-executable
/// grant its own dylibs need to load, say) still produces syntactically valid
/// SBPL: a text-only test would pass while the sandboxed render silently never
/// works. This exercises the whole thing end to end on a tiny fixed input, so
/// that failure mode fails the test suite instead of only a real render.
final class GhostscriptSandboxIntegrationTests: XCTestCase {

    func testRendersATinyEPSUnderTheGeneratedSandboxProfileAndProductionLimits() throws {
        guard FileManager.default.isExecutableFile(atPath: GhostscriptLaunch.sandboxExecPath) else {
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

        // Launched through `GhostscriptLaunch` — the same `/bin/sh` wrapper,
        // production rlimits (RLIMIT_NPROC=1 included) and argument order
        // `RenderService` uses — so a Ghostscript that needs to fork, or a
        // wrapper whose positional arguments drifted, fails here too.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GhostscriptLaunch.shellPath)
        process.environment = gs.environment
        process.arguments = GhostscriptLaunch.arguments(for: gs,
                                                        inputPath: inputURL.path,
                                                        outputPath: outputURL.path)
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice

        try process.run()

        // Wall-clock watchdog, the test-side counterpart to RenderService's:
        // the wrapper's `ulimit -t` only stops a gs that is burning CPU, so a
        // gs blocked under a bad profile (waiting on a denied resource) would
        // otherwise hang the whole test run instead of failing it.
        let timedOut = Atomic(false)
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.store(true)
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + GhostscriptLaunch.terminationGracePeriod) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + RenderLimits.renderTimeout, execute: watchdog)

        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        watchdog.cancel()

        // breaks-if: GhostscriptSandbox.profile denies something gs blocks waiting on instead of erroring out, so gs outlives renderTimeout
        XCTAssertFalse(timedOut.load(), """
            sandboxed gs did not finish within \(Int(RenderLimits.renderTimeout))s and was killed.
            stderr:
            \(errorOutput)
            """)

        XCTAssertEqual(process.terminationStatus, 0, """
            gs exited \(process.terminationStatus) under the generated sandbox profile and production \
            rlimits — a profile that blocks something gs needs (dylib loading, a resource file, ...), \
            or a limit gs cannot live with (a fork under RLIMIT_NPROC=1), fails here even though \
            the profile text itself is well-formed SBPL.
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
