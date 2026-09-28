import Foundation
import XCTest

/// Runs `GhostscriptLaunch`'s real `/bin/sh` wrapper — the exact script and
/// argument array `RenderService` launches — around a stand-in command that
/// reports the rlimits it inherited, so a drift between the Swift argument
/// order and the script's `$1`/`$2`/`$3`/`shift` sequence fails here rather
/// than silently mis-setting a limit or dropping the Ghostscript path.
///
/// The stand-in runs under a permissive profile: what is under test is the
/// wrapper's wiring, not the Ghostscript profile, which
/// `GhostscriptSandboxIntegrationTests` covers against a real `gs`.
final class GhostscriptLaunchTests: XCTestCase {

    private static let permissiveProfile = "(version 1)(allow default)"

    /// Prints the three inherited limits, then every argument it was given.
    private static let reportingCommand = [
        "/bin/sh", "-c", #"ulimit -f; ulimit -t; ulimit -u; printf '%s\n' "$@""#, "reporter",
    ]

    private struct Run {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func runWrapper(limits: GhostscriptLaunch.Limits, command: [String]) throws -> Run {
        guard FileManager.default.isExecutableFile(atPath: GhostscriptLaunch.sandboxExecPath) else {
            throw XCTSkip("sandbox-exec is not available on this machine")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GhostscriptLaunch.shellPath)
        process.environment = GhostscriptLocator.childEnvironment()
        process.arguments = GhostscriptLaunch.wrapperArguments(limits: limits,
                                                               sandboxProfile: Self.permissiveProfile,
                                                               command: command)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Both streams stay far below a pipe buffer, so reading them one
        // after the other cannot block the child.
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus,
                   stdout: String(decoding: out, as: UTF8.self),
                   stderr: String(decoding: err, as: UTF8.self))
    }

    // MARK: - Wiring

    func testEachLimitLandsOnItsOwnRlimitAndTheCommandKeepsItsArguments() throws {
        // Three distinct values, so a swap between any two positions shows.
        let limits = GhostscriptLaunch.Limits(outputBlocks: 4321, cpuSeconds: 56, processes: 7)

        let run = try runWrapper(limits: limits,
                                 command: Self.reportingCommand + ["first", "second arg"])

        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.stdout, "4321\n56\n7\nfirst\nsecond arg\n")
    }

    func testTheProductionProcessLimitStillLetsTheCommandStart() throws {
        // RLIMIT_NPROC is per-uid and checked at fork(): this account already
        // owns far more than one process, so this only passes because
        // neither the wrapper nor sandbox-exec forks on the way to the command.
        let run = try runWrapper(limits: .production, command: Self.reportingCommand)

        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.stdout.split(separator: "\n").last.map(String.init),
                       String(GhostscriptLaunch.processLimit))
    }

    func testTheFullArgumentListHandsSandboxExecTheProfileThenTheExecutable() {
        let gs = GhostscriptLocator.Ghostscript(executablePath: "/fake/bin/gs",
                                                environment: [:],
                                                sandboxReadOnlyRoots: [],
                                                sandboxExecutableRoots: [],
                                                sandboxProfile: "(version 1) ; fake")

        let arguments = GhostscriptLaunch.arguments(for: gs, inputPath: "/tmp/in.eps", outputPath: "/tmp/out.pdf")

        // `-c`, the script, `$0`, then the three limits: `$4` is the profile.
        XCTAssertEqual(arguments[0], "-c")
        XCTAssertEqual(arguments[1], GhostscriptLaunch.script)
        XCTAssertEqual(Array(arguments[3...5]), [
            String(GhostscriptLaunch.Limits.production.outputBlocks),
            String(GhostscriptLaunch.cpuTimeLimitSeconds),
            String(GhostscriptLaunch.processLimit),
        ])
        XCTAssertEqual(arguments[6], gs.sandboxProfile)
        XCTAssertEqual(arguments[7], gs.executablePath)
        XCTAssertEqual(arguments.last, "/tmp/in.eps")
        XCTAssertTrue(arguments.contains("-sOutputFile=/tmp/out.pdf"))
    }

    // MARK: - A limit that cannot be applied

    // breaks-if: any `ulimit` line in GhostscriptLaunch.script loses its `|| { ...; exit 71; }` guard.
    func testAFailingUlimitExitsWithTheLimitFailureStatusBeforeTheCommandRuns() throws {
        let valid = GhostscriptLaunch.Limits(outputBlocks: 4321, cpuSeconds: 56, processes: 7)
        // A negative value is rejected by `ulimit` itself, so each of the
        // three calls can be made to fail on its own.
        let cases: [(GhostscriptLaunch.Limits, String)] = [
            (.init(outputBlocks: -1, cpuSeconds: valid.cpuSeconds, processes: valid.processes),
             "could not limit Ghostscript output size"),
            (.init(outputBlocks: valid.outputBlocks, cpuSeconds: -1, processes: valid.processes),
             "could not limit Ghostscript CPU time"),
            (.init(outputBlocks: valid.outputBlocks, cpuSeconds: valid.cpuSeconds, processes: -1),
             "could not limit Ghostscript process count"),
        ]

        for (limits, message) in cases {
            let run = try runWrapper(limits: limits, command: Self.reportingCommand + ["ran"])

            XCTAssertEqual(run.status, GhostscriptLaunch.limitFailureStatus, message)
            XCTAssertTrue(run.stderr.contains(message), "expected \"\(message)\" in: \(run.stderr)")
            XCTAssertEqual(run.stdout, "", "the command must not start once a limit failed to apply")
        }
    }

    // breaks-if: RenderOutcome.result maps GhostscriptLaunch.limitFailureStatus to anything but .malformedInput.
    func testALimitFailureExitIsReportedAsAMalformedInput() {
        // Documents the current mapping: a failed rlimit is reported to the
        // caller the same way as a corrupt EPS, since `RenderOutcome` treats
        // every non-zero, non-signalled exit alike.
        let termination = RenderTermination(killedBySignal: false,
                                            status: GhostscriptLaunch.limitFailureStatus,
                                            timedOut: false)

        let result = RenderOutcome.result(for: termination,
                                          errorOutput: Data("could not limit Ghostscript CPU time".utf8),
                                          outputPath: NSTemporaryDirectory() + "never-written-" + UUID().uuidString)

        XCTAssertNil(result.pdf)
        XCTAssertEqual(result.failure, .malformedInput)
    }
}
