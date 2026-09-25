import Foundation
import XCTest

/// The negative XPC peer-rejection tests from issue #11, covering both halves
/// of `PeerTrust.isTrustedPeer`'s check: a second, separately ad-hoc signed
/// fixture process attempts to be treated as a trusted peer, and is expected
/// to be refused unless it both lives inside the app bundle root *and*
/// carries one of `PeerTrust.allowedSigningIdentifiers`. `PeerTrust.swift`'s
/// extraction out of `main.swift` (which has top-level executable
/// statements and so cannot be linked into a test target) is what makes this
/// reachable at all -- no real XPC connection or launchd registration is
/// needed, since `isTrustedPeer` only needs a running process's pid.
final class PeerTrustTests: XCTestCase {
    private var workDir = URL(fileURLWithPath: NSTemporaryDirectory())
    private var spawnedPeers: [Process] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeerTrustTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    /// The `ownAppRoot` every test hands to `isTrustedPeer`, canonicalized the
    /// same way production does (`BundleLayout.enclosingAppBundlePath`) rather
    /// than by a one-off `realpath(3)` call. `BundleLayout` deliberately uses
    /// `URL.resolvingSymlinksInPath()`, which special-cases `/tmp`, `/var` and
    /// `/etc` and leaves them unresolved -- but macOS's real temp dir is under
    /// `/private/var`, so a fully `realpath`-resolved root disagrees with
    /// what `BundleLayout` computes for the peer's own path (also under
    /// `/var/folders`) even for a legitimately-inside-the-bundle peer, for a
    /// reason that has nothing to do with trust. Routing both sides through
    /// the same function is what keeps them talking about the same string.
    private func trustedRoot(_ appRoot: URL) -> String {
        BundleLayout.enclosingAppBundlePath(for: appRoot) ?? appRoot.path
    }

    override func tearDown() {
        for peer in spawnedPeers where peer.isRunning {
            peer.terminate()
            peer.waitUntilExit()
        }
        spawnedPeers.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    func testPeerInADifferentAppBundleIsRejected() throws {
        let appRoot = workDir.appendingPathComponent("Fixture.app")
        let pid = try spawnSignedPeer(at: "Evil.app/Contents/MacOS/evil-peer",
                                       signingIdentifier: "com.example.eps-preview-tests.evil")

        XCTAssertFalse(PeerTrust.isTrustedPeer(pid: pid, ownAppRoot: trustedRoot(appRoot)),
                        "a peer inside a different app bundle must be refused")
    }

    func testPeerInsideTheAppBundleRootIsTrusted() throws {
        let appRoot = workDir.appendingPathComponent("Fixture.app")
        let pid = try spawnSignedPeer(at: "Fixture.app/Contents/MacOS/legit-peer",
                                       signingIdentifier: BundleIdentifiers.quickLookExtension)

        XCTAssertTrue(PeerTrust.isTrustedPeer(pid: pid, ownAppRoot: trustedRoot(appRoot)))
    }

    func testPeerInsideTheAppBundleRootWithADisallowedIdentifierIsRejected() throws {
        // Same location as the trusted case above -- only the signing
        // identifier differs -- so this isolates the requirement half of the
        // check from the containment half the other three tests cover.
        let appRoot = workDir.appendingPathComponent("Fixture.app")
        let pid = try spawnSignedPeer(at: "Fixture.app/Contents/MacOS/impostor-peer",
                                       signingIdentifier: "com.example.eps-preview-tests.evil")

        XCTAssertFalse(PeerTrust.isTrustedPeer(pid: pid, ownAppRoot: trustedRoot(appRoot)),
                        "a peer inside the app bundle root with an unpinned signing identifier must be refused")
    }

    func testPeerOutsideTheAppBundleRootIsRejected() throws {
        let appRoot = workDir.appendingPathComponent("Fixture.app")
        let pid = try spawnSignedPeer(at: "not-inside-any-app-bundle/evil-peer",
                                       signingIdentifier: "com.example.eps-preview-tests.evil")

        XCTAssertFalse(PeerTrust.isTrustedPeer(pid: pid, ownAppRoot: trustedRoot(appRoot)),
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
