import Foundation
import XCTest

/// The negative XPC peer-rejection test from issue #11: a second,
/// separately ad-hoc signed fixture process attempts to be treated as a
/// trusted peer, and is expected to be refused. `PeerTrust.swift`'s
/// extraction out of `main.swift` (which has top-level executable
/// statements and so cannot be linked into a test target) is what makes this
/// reachable at all -- no real XPC connection or launchd registration is
/// needed, since `isTrustedPeer` only needs a running process's pid.
final class PeerTrustTests: XCTestCase {
    private var workDir: URL!
    private var spawnedPeers: [Process] = []

    override func setUpWithError() throws {
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerTrustTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        // `realpath(3)`, not `URL.resolvingSymlinksInPath()`: the latter
        // special-cases `/tmp`, `/var` and `/etc` and leaves them
        // unresolved, but `SecCodeCopyPath` returns the peer's fully
        // resolved path (macOS's real temp dir is under `/private/var`,
        // `FileManager.temporaryDirectory` under the `/var` symlink to it)
        // -- without matching that, the comparison below fails even for a
        // legitimately-inside-the-bundle peer, for a reason that has
        // nothing to do with trust.
        workDir = URL(fileURLWithPath: try canonicalPath(candidate.path))
    }

    private func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    override func tearDown() {
        for peer in spawnedPeers where peer.isRunning {
            peer.terminate()
            peer.waitUntilExit()
        }
        spawnedPeers.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    func testPeerInsideTheAppBundleRootIsTrusted() throws {
        let appRoot = workDir.appendingPathComponent("Fixture.app")
        let pid = try spawnSignedPeer(at: "Fixture.app/Contents/MacOS/legit-peer",
                                       signingIdentifier: "com.example.eps-preview-tests.legit")

        XCTAssertTrue(PeerTrust.isTrustedPeer(pid: pid, ownAppRoot: appRoot.path))
    }

    func testPeerOutsideTheAppBundleRootIsRejected() throws {
        let appRoot = workDir.appendingPathComponent("Fixture.app")
        let pid = try spawnSignedPeer(at: "not-inside-any-app-bundle/evil-peer",
                                       signingIdentifier: "com.example.eps-preview-tests.evil")

        XCTAssertFalse(PeerTrust.isTrustedPeer(pid: pid, ownAppRoot: appRoot.path),
                        "a separately-signed peer outside our app bundle must be refused")
    }

    /// Builds a small, harmless, genuinely running process at `relativePath`
    /// (under `workDir`), ad-hoc signed with a distinct `signingIdentifier`
    /// -- modeled on `scripts/build.sh`'s own `sign()` helper -- and returns
    /// its pid so `PeerTrust` can inspect it via real `SecCode` APIs, the
    /// same way it inspects a real XPC peer.
    private func spawnSignedPeer(at relativePath: String, signingIdentifier: String) throws -> pid_t {
        let executable = workDir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)

        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", "--identifier", signingIdentifier, executable.path]
        try sign.run()
        sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0, "ad-hoc signing the fixture peer must succeed")

        let peer = Process()
        peer.executableURL = executable
        peer.arguments = ["30"]
        try peer.run()
        spawnedPeers.append(peer)
        return peer.processIdentifier
    }
}
