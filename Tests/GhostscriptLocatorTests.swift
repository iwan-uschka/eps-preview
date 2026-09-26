import Foundation
import XCTest

/// Covers the caching policy in front of Ghostscript resolution and the
/// version floor. Both are driven through injected fakes: a real lookup would
/// depend on whether this machine happens to have Homebrew's `gs`, and on how
/// long it takes to answer `--version`.
final class GhostscriptLocatorTests: XCTestCase {

    // MARK: - Helpers

    /// Counts resolver invocations from whichever thread reached it.
    private final class CallCounter {
        private let lock = NSLock()
        private var calls = 0

        func record() {
            lock.lock()
            calls += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return calls
        }
    }

    /// Collects one result per concurrent caller.
    private final class ResultCollector {
        private let lock = NSLock()
        private var paths: [String?] = []

        func append(_ path: String?) {
            lock.lock()
            paths.append(path)
            lock.unlock()
        }

        var collected: [String?] {
            lock.lock()
            defer { lock.unlock() }
            return paths
        }
    }

    private func ghostscript(_ path: String) -> GhostscriptLocator.Ghostscript {
        GhostscriptLocator.Ghostscript(executablePath: path, environment: [:])
    }

    // MARK: - Caching

    func testSuccessfulResolutionIsCachedForever() {
        let calls = CallCounter()
        var now: TimeInterval = 1_000
        let cache = GhostscriptResolutionCache(failureTTL: 30, clock: { now }, resolve: {
            calls.record()
            return GhostscriptLocator.Ghostscript(executablePath: "/opt/homebrew/bin/gs",
                                                 environment: ["PATH": "/usr/bin:/bin"])
        })

        XCTAssertEqual(cache.locate()?.executablePath, "/opt/homebrew/bin/gs")
        XCTAssertEqual(cache.locate()?.executablePath, "/opt/homebrew/bin/gs")
        now += 86_400
        XCTAssertEqual(cache.locate()?.executablePath, "/opt/homebrew/bin/gs")
        XCTAssertEqual(cache.locate()?.environment["PATH"], "/usr/bin:/bin")

        XCTAssertEqual(calls.count, 1, "a resolved Ghostscript must not be looked up twice")
    }

    func testFailedResolutionIsNotRetriedInsideTheTTL() {
        let calls = CallCounter()
        var now: TimeInterval = 1_000
        let cache = GhostscriptResolutionCache(failureTTL: 30, clock: { now }, resolve: {
            calls.record()
            return nil
        })

        XCTAssertNil(cache.locate())
        XCTAssertNil(cache.locate())
        now += 15
        XCTAssertNil(cache.locate())
        now += 14.999
        XCTAssertNil(cache.locate())

        XCTAssertEqual(calls.count, 1, "a hanging or rejected candidate must cost one probe per window")
    }

    func testFailedResolutionIsRetriedOnceTheTTLExpiresAndThenCached() {
        let calls = CallCounter()
        var now: TimeInterval = 1_000
        var installed: GhostscriptLocator.Ghostscript?
        let cache = GhostscriptResolutionCache(failureTTL: 30, clock: { now }, resolve: {
            calls.record()
            return installed
        })

        XCTAssertNil(cache.locate())
        XCTAssertEqual(calls.count, 1)

        // Ghostscript appears after launch; the window has to expire first.
        installed = ghostscript("/usr/local/bin/gs")
        now += 29
        XCTAssertNil(cache.locate(), "still inside the window")
        XCTAssertEqual(calls.count, 1)

        now += 1
        XCTAssertEqual(cache.locate()?.executablePath, "/usr/local/bin/gs")
        XCTAssertEqual(calls.count, 2)

        // And the late success is now cached like any other.
        now += 86_400
        XCTAssertEqual(cache.locate()?.executablePath, "/usr/local/bin/gs")
        XCTAssertEqual(calls.count, 2)
    }

    func testConcurrentCallersShareOneSlowResolution() {
        let calls = CallCounter()
        let results = ResultCollector()
        let callers = 8
        let cache = GhostscriptResolutionCache(failureTTL: 30,
                                               clock: { ProcessInfo.processInfo.systemUptime },
                                               resolve: {
            calls.record()
            // Stands in for `gs --version`: slow enough that every other
            // caller is inside `locate()` while this one resolves.
            Thread.sleep(forTimeInterval: 0.1)
            return GhostscriptLocator.Ghostscript(executablePath: "/opt/local/bin/gs", environment: [:])
        })

        DispatchQueue.concurrentPerform(iterations: callers) { _ in
            results.append(cache.locate()?.executablePath)
        }

        XCTAssertEqual(calls.count, 1, "parallel renders must spawn one version probe, not one each")
        let collected = results.collected
        XCTAssertEqual(collected.count, callers)
        XCTAssertTrue(collected.allSatisfy { $0 == "/opt/local/bin/gs" },
                      "every caller must receive the single resolution, got \(collected)")
    }

    // MARK: - Version floor

    private let minimum = (major: 9, minor: 50)

    func testVersionsAtOrAboveTheFloorAreAccepted() {
        XCTAssertTrue(GhostscriptLocator.versionString("9.50", meetsMinimum: minimum))
        XCTAssertTrue(GhostscriptLocator.versionString("9.56", meetsMinimum: minimum))
        XCTAssertTrue(GhostscriptLocator.versionString("10.02.1", meetsMinimum: minimum))
        XCTAssertTrue(GhostscriptLocator.versionString("10.00", meetsMinimum: minimum))
    }

    func testVersionsBelowTheFloorAreRejected() {
        XCTAssertFalse(GhostscriptLocator.versionString("9.49", meetsMinimum: minimum))
        XCTAssertFalse(GhostscriptLocator.versionString("8.99", meetsMinimum: minimum))
        // Existing, intentional behaviour: the minor field is compared as
        // printed, so a one-digit minor reads as 5, not 50.
        XCTAssertFalse(GhostscriptLocator.versionString("9.5", meetsMinimum: minimum))
    }

    func testUnparseableVersionsAreRejected() {
        XCTAssertFalse(GhostscriptLocator.versionString("10", meetsMinimum: minimum))
        XCTAssertFalse(GhostscriptLocator.versionString("abc", meetsMinimum: minimum))
        XCTAssertFalse(GhostscriptLocator.versionString("", meetsMinimum: minimum))
        XCTAssertFalse(GhostscriptLocator.versionString("GPL Ghostscript 9.55", meetsMinimum: minimum))
    }

    // MARK: - Ownership and permission vetting

    /// Creates `<temp>/<uuid>/gs` and returns its path, with both the file and
    /// its containing directory set to the given modes. Owned by this process
    /// either way — a test cannot hand itself a file owned by a third user, so
    /// only the permission half is driven through a real file. With
    /// `binaryIsDirectory`, `gs` is a directory instead of a file.
    private func candidate(fileMode: Int, directoryMode: Int, binaryIsDirectory: Bool = false) throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gs-vetting-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let binary = directory.appendingPathComponent("gs")
        if binaryIsDirectory {
            try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: false)
        } else {
            try Data("#!/bin/sh\n".utf8).write(to: binary)
        }
        try FileManager.default.setAttributes([.posixPermissions: fileMode],
                                              ofItemAtPath: binary.path)
        try FileManager.default.setAttributes([.posixPermissions: directoryMode],
                                              ofItemAtPath: directory.path)
        return binary.path
    }

    func testOwnerOnlyWritableCandidateIsAccepted() throws {
        let path = try candidate(fileMode: 0o755, directoryMode: 0o755)
        XCTAssertTrue(GhostscriptLocator.hasTrustworthyOwnership(path))
    }

    func testWorldWritableCandidateIsRejected() throws {
        let path = try candidate(fileMode: 0o777, directoryMode: 0o755)
        XCTAssertFalse(GhostscriptLocator.hasTrustworthyOwnership(path))
    }

    func testGroupWritableCandidateIsRejected() throws {
        let path = try candidate(fileMode: 0o775, directoryMode: 0o755)
        XCTAssertFalse(GhostscriptLocator.hasTrustworthyOwnership(path))
    }

    func testCandidateInAWorldWritableDirectoryIsRejected() throws {
        // The binary itself is fine; anyone could still replace it wholesale.
        let path = try candidate(fileMode: 0o755, directoryMode: 0o777)
        XCTAssertFalse(GhostscriptLocator.hasTrustworthyOwnership(path))
    }

    func testMissingCandidateIsRejected() {
        XCTAssertFalse(GhostscriptLocator.hasTrustworthyOwnership(
            NSTemporaryDirectory() + "gs-does-not-exist-" + UUID().uuidString))
    }

    func testRootAcceptsAConsoleUserOwnedBinaryWithASafeMode() {
        // Reproduces `sudo scripts/install.sh` against a Homebrew gs owned by
        // the console user (uid 501), not root — must not be rejected just
        // because the acting uid (root) differs from the owner.
        XCTAssertTrue(GhostscriptLocator.isWritableOnlyByOwner(owner: 501, currentUID: 0, mode: 0o755))
    }

    func testRootStillRejectsAWorldWritableBinaryRegardlessOfOwner() {
        XCTAssertFalse(GhostscriptLocator.isWritableOnlyByOwner(owner: 501, currentUID: 0, mode: 0o777))
    }

    func testNonRootStillRejectsAThirdPartyOwnedBinary() {
        // Unchanged pre-existing behaviour: a same-uid attacker is the threat
        // this guards against for an ordinary (non-root) caller.
        XCTAssertFalse(GhostscriptLocator.isWritableOnlyByOwner(owner: 999, currentUID: 501, mode: 0o755))
    }

    func testNonRootAcceptsItsOwnSafeBinary() {
        XCTAssertTrue(GhostscriptLocator.isWritableOnlyByOwner(owner: 501, currentUID: 501, mode: 0o755))
    }

    func testOnlyGroupAndWorldWriteBitsDisqualifyAMode() {
        XCTAssertTrue(GhostscriptLocator.isWritableOnlyByOwner(mode: 0o755))
        XCTAssertTrue(GhostscriptLocator.isWritableOnlyByOwner(mode: 0o700))
        XCTAssertTrue(GhostscriptLocator.isWritableOnlyByOwner(mode: 0o555))
        XCTAssertFalse(GhostscriptLocator.isWritableOnlyByOwner(mode: 0o775), "group-writable")
        XCTAssertFalse(GhostscriptLocator.isWritableOnlyByOwner(mode: 0o757), "world-writable")
        XCTAssertFalse(GhostscriptLocator.isWritableOnlyByOwner(mode: 0o777))
    }

    // MARK: - Sandbox-safe presence check (host app's status window)

    func testPresenceCheckAcceptsAnOwnerOnlyWritableCandidate() throws {
        let path = try candidate(fileMode: 0o755, directoryMode: 0o755)
        XCTAssertTrue(GhostscriptLocator.anySystemCandidateIsPresent([path]))
    }

    func testPresenceCheckIgnoresExecutability() throws {
        // The whole point of this entry point: the host app is sandboxed, and
        // the sandbox fails `access(X_OK)` with EPERM even for a gs that is
        // really there and really executable. So a candidate that carries no
        // execute bit at all must still read as present — the executability
        // question is the render service's, and it runs unsandboxed.
        let path = try candidate(fileMode: 0o644, directoryMode: 0o755)
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: path))
        XCTAssertTrue(GhostscriptLocator.anySystemCandidateIsPresent([path]))
    }

    func testPresenceCheckStillAppliesOwnershipVetting() throws {
        // Metadata reads survive the sandbox, so this half of the vetting is
        // kept rather than dropped along with the exec probe.
        let path = try candidate(fileMode: 0o777, directoryMode: 0o755)
        XCTAssertFalse(GhostscriptLocator.anySystemCandidateIsPresent([path]))
    }

    func testPresenceCheckRejectsAnEmptyOrAllMissingCandidateList() {
        XCTAssertFalse(GhostscriptLocator.anySystemCandidateIsPresent([]))
        XCTAssertFalse(GhostscriptLocator.anySystemCandidateIsPresent(
            [NSTemporaryDirectory() + "gs-does-not-exist-" + UUID().uuidString]))
    }

    func testPresenceCheckScansPastAMissingCandidate() throws {
        let path = try candidate(fileMode: 0o755, directoryMode: 0o755)
        XCTAssertTrue(GhostscriptLocator.anySystemCandidateIsPresent(
            [NSTemporaryDirectory() + "gs-does-not-exist-" + UUID().uuidString, path]))
    }

    func testPresenceCheckRejectsADirectoryAtTheCandidatePath() throws {
        // A directory named `gs` passes the existence and ownership checks, but
        // the render service would never accept it as an executable.
        let path = try candidate(fileMode: 0o755, directoryMode: 0o755, binaryIsDirectory: true)
        XCTAssertTrue(GhostscriptLocator.hasTrustworthyOwnership(path))
        XCTAssertFalse(GhostscriptLocator.anySystemCandidateIsPresent([path]))
    }

    private let fakeBundled = GhostscriptLocator.Ghostscript(executablePath: "/bundled/gs", environment: [:])

    func testLikelyInstalledWhenOnlyTheBundledCopyIsPresent() {
        // A downloaded release with no Homebrew gs must not show the
        // "brew install ghostscript" warning.
        XCTAssertTrue(GhostscriptLocator.isLikelyInstalled(bundled: { self.fakeBundled }, candidates: []))
    }

    func testLikelyInstalledWhenOnlyASystemCandidateIsPresent() throws {
        let path = try candidate(fileMode: 0o755, directoryMode: 0o755)
        XCTAssertTrue(GhostscriptLocator.isLikelyInstalled(bundled: { nil }, candidates: [path]))
    }

    func testNotLikelyInstalledWhenNeitherIsPresent() {
        XCTAssertFalse(GhostscriptLocator.isLikelyInstalled(
            bundled: { nil },
            candidates: [NSTemporaryDirectory() + "gs-does-not-exist-" + UUID().uuidString]))
    }

    // MARK: - Forcing a system Ghostscript

    func testForcesSystemGhostscriptWhenTheFlagFileExists() throws {
        let path = NSTemporaryDirectory() + "force-system-gs-" + UUID().uuidString
        try Data().write(to: URL(fileURLWithPath: path))
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertTrue(GhostscriptLocator.forcesSystemGhostscript(flagPath: path))
    }

    func testDoesNotForceSystemGhostscriptWhenTheFlagFileIsAbsent() {
        XCTAssertFalse(GhostscriptLocator.forcesSystemGhostscript(
            flagPath: NSTemporaryDirectory() + "force-system-gs-does-not-exist-" + UUID().uuidString))
    }
}
