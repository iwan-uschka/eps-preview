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
        GhostscriptLocator.Ghostscript(executablePath: path, environment: [:],
                                       sandboxReadOnlyRoots: [], sandboxExecutableRoots: [],
                                       sandboxProfile: "")
    }

    // MARK: - Caching

    func testSuccessfulResolutionIsCachedForever() {
        let calls = CallCounter()
        var now: TimeInterval = 1_000
        let cache = GhostscriptResolutionCache(failureTTL: 30, clock: { now }, resolve: {
            calls.record()
            return GhostscriptLocator.Ghostscript(executablePath: "/opt/homebrew/bin/gs",
                                                 environment: ["PATH": "/usr/bin:/bin"],
                                                 sandboxReadOnlyRoots: [], sandboxExecutableRoots: [],
                                                 sandboxProfile: "")
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
            return GhostscriptLocator.Ghostscript(executablePath: "/opt/local/bin/gs", environment: [:],
                                                 sandboxReadOnlyRoots: [], sandboxExecutableRoots: [],
                                                 sandboxProfile: "")
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

    // MARK: - Sandbox read root

    func testPrefixRootStripsTheBinGsSuffix() {
        XCTAssertEqual(GhostscriptLocator.prefixRoot(forSystemCandidate: "/opt/homebrew/bin/gs"),
                      "/opt/homebrew")
        XCTAssertEqual(GhostscriptLocator.prefixRoot(forSystemCandidate: "/usr/local/bin/gs"),
                      "/usr/local")
        XCTAssertEqual(GhostscriptLocator.prefixRoot(forSystemCandidate: "/opt/local/bin/gs"),
                      "/opt/local")
        XCTAssertEqual(GhostscriptLocator.prefixRoot(forSystemCandidate: "/usr/bin/gs"), "/usr")
    }

    func testPrefixRootComesOutWrongForACandidateNotShapedBinGs() {
        // breaks-if: this is read as a spec rather than as documentation of the
        // known gap — `prefixRoot` unconditionally drops the last 7 characters,
        // so a `systemCandidates` entry not ending in "/bin/gs" silently yields
        // a mangled prefix (here, a trailing slash) instead of failing loudly.
        XCTAssertEqual(GhostscriptLocator.prefixRoot(forSystemCandidate: "/opt/homebrew/bin/gsc"),
                      "/opt/homebrew/")
    }

    func testSystemExecutableRootIsThePrefixsLibDirectory() {
        XCTAssertEqual(GhostscriptLocator.sandboxExecutableRoot(forSystemPrefix: "/opt/homebrew"),
                       "/opt/homebrew/lib")
        XCTAssertEqual(GhostscriptLocator.sandboxExecutableRoot(forSystemPrefix: "/opt/local"),
                       "/opt/local/lib")
    }

    // MARK: - Bundled copy's sandbox roots

    /// Builds `<temp>/<uuid>/Fixture.app` with `Contents/Helpers/gs/converter`
    /// (executable unless `converterIsExecutable` is false) and an empty
    /// `Contents/Resources/ghostscript`, and returns the `.app` path.
    private func fixtureAppBundle(converterIsExecutable: Bool = true) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gs-bundle-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers/gs", isDirectory: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: app.appendingPathComponent("Contents/Resources/ghostscript", isDirectory: true),
            withIntermediateDirectories: true)
        let converter = helpers.appendingPathComponent("converter")
        try Data("#!/bin/sh\n".utf8).write(to: converter)
        try FileManager.default.setAttributes([.posixPermissions: converterIsExecutable ? 0o755 : 0o644],
                                              ofItemAtPath: converter.path)
        return app.path
    }

    func testBundledCopyReadsBothTreesButMapsExecutableOnlyFromHelpers() throws {
        let app = try fixtureAppBundle()
        let helpers = app + "/Contents/Helpers/gs"
        let resources = app + "/Contents/Resources/ghostscript"

        let gs = try XCTUnwrap(GhostscriptLocator.bundledGhostscript(appBundlePath: app))

        XCTAssertEqual(gs.executablePath, helpers + "/converter")
        XCTAssertEqual(gs.sandboxReadOnlyRoots, [helpers, resources])
        XCTAssertEqual(gs.sandboxExecutableRoots, [helpers])
        XCTAssertEqual(gs.sandboxProfile, GhostscriptSandbox.profile(
            gsExecutablePath: gs.executablePath,
            readOnlyRoots: [helpers, resources],
            executableRoots: [helpers],
            scratchDirectory: NSTemporaryDirectory()))
    }

    // breaks-if: bundledGhostscript(appBundlePath:) drops its isExecutableFile check on `converter`.
    func testBundledCopyIsIgnoredWhenTheConverterIsNotExecutable() throws {
        let app = try fixtureAppBundle(converterIsExecutable: false)

        XCTAssertNil(GhostscriptLocator.bundledGhostscript(appBundlePath: app))
    }

    func testBundledCopyIsFoundFromABundleNestedInsideTheApp() throws {
        let app = try fixtureAppBundle()
        let service = URL(fileURLWithPath: app)
            .appendingPathComponent("Contents/PlugIns/EPSThumbnail.appex/Contents/XPCServices/RenderService.xpc")

        let gs = try XCTUnwrap(GhostscriptLocator.bundledGhostscript(enclosing: service))

        XCTAssertEqual(gs.executablePath, app + "/Contents/Helpers/gs/converter")
    }

    // breaks-if: bundledGhostscript(enclosing:) falls back to the bundle's own path when no `.app` encloses it.
    func testBundledCopyIsIgnoredOutsideAnyAppBundle() throws {
        // The same Contents/Helpers/gs tree as the fixture `.app`, under a
        // directory that is not one: only the missing `.app` stops it.
        let app = try fixtureAppBundle()
        let notAnApp = URL(fileURLWithPath: app).deletingLastPathComponent().appendingPathComponent("NotAnApp")
        try FileManager.default.moveItem(atPath: app, toPath: notAnApp.path)

        XCTAssertNil(GhostscriptLocator.bundledGhostscript(enclosing: notAnApp))
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

    private let fakeBundled = GhostscriptLocator.Ghostscript(executablePath: "/bundled/gs", environment: [:],
                                                              sandboxReadOnlyRoots: [], sandboxExecutableRoots: [],
                                                              sandboxProfile: "")

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

    func testLikelyInstalledIgnoresABundledCopyWhenSystemIsForced() throws {
        // Forcing a system Ghostscript must not be masked by a bundled copy
        // that `locate()` itself will skip.
        let path = try candidate(fileMode: 0o755, directoryMode: 0o755)
        XCTAssertTrue(GhostscriptLocator.isLikelyInstalled(
            bundled: { self.fakeBundled }, candidates: [path], forcesSystem: true))
    }

    func testNotLikelyInstalledWhenSystemIsForcedAndNoSystemCandidateIsPresent() {
        // The bundled copy is present but forcing is on, so `locate()` returns
        // nil; the status window must agree rather than reporting it ready.
        XCTAssertFalse(GhostscriptLocator.isLikelyInstalled(
            bundled: { self.fakeBundled },
            candidates: [NSTemporaryDirectory() + "gs-does-not-exist-" + UUID().uuidString],
            forcesSystem: true))
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

    // MARK: - Resolution ordering (bundled vs. forced system)

    func testResolveGhostscriptSkipsAValidBundledCopyWhenForced() {
        XCTAssertEqual(
            GhostscriptLocator.resolveGhostscript(
                forcesSystem: true,
                bundled: { self.fakeBundled },
                system: { self.ghostscript("/opt/homebrew/bin/gs") }
            )?.executablePath,
            "/opt/homebrew/bin/gs")
    }

    func testResolveGhostscriptReturnsNilWhenForcedAndNoSystemCandidateResolves() {
        XCTAssertNil(GhostscriptLocator.resolveGhostscript(
            forcesSystem: true,
            bundled: { self.fakeBundled },
            system: { nil }))
    }

    func testResolveGhostscriptPrefersBundledWhenNotForced() {
        XCTAssertEqual(
            GhostscriptLocator.resolveGhostscript(
                forcesSystem: false,
                bundled: { self.fakeBundled },
                system: { self.ghostscript("/opt/homebrew/bin/gs") }
            )?.executablePath,
            fakeBundled.executablePath)
    }

    func testResolveGhostscriptFallsBackToSystemWhenNotForcedAndNoBundledCopy() {
        XCTAssertEqual(
            GhostscriptLocator.resolveGhostscript(
                forcesSystem: false,
                bundled: { nil },
                system: { self.ghostscript("/opt/homebrew/bin/gs") }
            )?.executablePath,
            "/opt/homebrew/bin/gs")
    }
}
