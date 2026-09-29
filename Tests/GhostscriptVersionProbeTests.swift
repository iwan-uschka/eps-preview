import Foundation
import XCTest

/// `GhostscriptLocator.probeVersion` and `meetsMinimumVersion` — the
/// `gs --version` probe every system candidate must pass — driven against
/// fake `gs` scripts written per test, so the result never depends on which
/// Ghostscript (if any) this machine has. The version-string comparison on
/// its own is `GhostscriptLocatorTests`' ground.
final class GhostscriptVersionProbeTests: XCTestCase {

    /// Writes an executable `/bin/sh` script at `<temp>/<uuid>/gs` whose body
    /// is `body`, standing in for a system candidate's `gs --version`.
    private func fakeGhostscript(_ body: String) throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gs-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let gs = directory.appendingPathComponent("gs")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: gs)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gs.path)
        return gs.path
    }

    func testProbeReturnsTheFirstLineAndAcceptsAVersionAtTheFloor() throws {
        let gs = try fakeGhostscript("printf ' 9.50 \\nextra\\n'")

        XCTAssertEqual(GhostscriptLocator.probeVersion(gs), "9.50")
        XCTAssertTrue(GhostscriptLocator.meetsMinimumVersion(gs))
    }

    // breaks-if: probeVersion stops checking terminationStatus and trusts what a failing gs printed.
    func testProbeRejectsAGsThatPrintsAVersionButExitsNonZero() throws {
        let gs = try fakeGhostscript("echo 10.05.1; exit 1")

        XCTAssertNil(GhostscriptLocator.probeVersion(gs))
        XCTAssertFalse(GhostscriptLocator.meetsMinimumVersion(gs))
    }

    // breaks-if: probeVersion maps empty output to "", or meetsMinimumVersion lets a nil probe pass.
    func testProbeRejectsAGsThatPrintsNothing() throws {
        let gs = try fakeGhostscript("exit 0")

        XCTAssertNil(GhostscriptLocator.probeVersion(gs))
        XCTAssertFalse(GhostscriptLocator.meetsMinimumVersion(gs))
    }

    // breaks-if: probeVersion's `process.run()` catch stops returning nil.
    func testProbeRejectsACandidateThatCannotBeLaunched() {
        let missing = NSTemporaryDirectory() + "gs-probe-missing-" + UUID().uuidString + "/gs"

        XCTAssertNil(GhostscriptLocator.probeVersion(missing))
        XCTAssertFalse(GhostscriptLocator.meetsMinimumVersion(missing))
    }

    // breaks-if: meetsMinimumVersion stops comparing the probed version against minimumSystemVersion.
    func testProbeRejectsAGsBelowTheFloor() throws {
        let gs = try fakeGhostscript("echo 9.27")

        XCTAssertEqual(GhostscriptLocator.probeVersion(gs), "9.27")
        XCTAssertFalse(GhostscriptLocator.meetsMinimumVersion(gs))
    }
}
