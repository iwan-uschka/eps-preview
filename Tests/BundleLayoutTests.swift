import Foundation
import XCTest

final class BundleLayoutTests: XCTestCase {

    func testFindsAppRootFromEmbeddedRenderServiceExecutable() {
        let executable = URL(fileURLWithPath:
            "/Applications/EPSPreview.app/Contents/PlugIns/EPSThumbnail.appex"
            + "/Contents/XPCServices/RenderService.xpc/Contents/MacOS/RenderService")
        XCTAssertEqual(BundleLayout.enclosingAppBundlePath(for: executable),
                       "/Applications/EPSPreview.app")
    }

    func testAppBundleRootIsItsOwnEnclosingBundle() {
        let app = URL(fileURLWithPath: "/Applications/EPSPreview.app")
        XCTAssertEqual(BundleLayout.enclosingAppBundlePath(for: app),
                       "/Applications/EPSPreview.app")
    }

    func testReturnsNilForPathOutsideAnyAppBundle() {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/gs")
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: executable))
    }

    func testAppexIsNotMistakenForAnAppBundle() {
        let executable = URL(fileURLWithPath: "/tmp/EPSThumbnail.appex/Contents/MacOS/EPSThumbnail")
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: executable))
    }

    // MARK: - Symlink resolution against a real directory tree

    /// Creates a fresh temporary directory for one test and registers its
    /// removal as a teardown block, so each test owns (and cleans up) its own
    /// tree instead of sharing mutable state across tests.
    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func makeFile(_ url: URL) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
    }

    private func makeSymlink(at link: URL, to destination: URL) throws {
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    /// This is the property `PeerTrust.isTrustedPeer` relies on: it compares
    /// its own bundle's enclosing `.app` path against the peer's, and the two
    /// paths reach that comparison through different spellings (this
    /// process's own launch path vs. `SecCodeCopyPath`'s answer for the peer).
    func testSymlinkIntoAnAppBundleAndTheRealPathYieldTheIdenticalString() throws {
        let tempRoot = try makeTempRoot()
        let app = tempRoot.appendingPathComponent("Real.app", isDirectory: true)
        let executableDir = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try makeDirectory(executableDir)
        let realExecutable = executableDir.appendingPathComponent("Tool")
        try makeFile(realExecutable)

        let link = tempRoot.appendingPathComponent("Launcher")
        try makeSymlink(at: link, to: realExecutable)

        let viaSymlink = BundleLayout.enclosingAppBundlePath(for: link)
        let viaRealPath = BundleLayout.enclosingAppBundlePath(for: realExecutable)
        XCTAssertNotNil(viaRealPath)
        XCTAssertEqual(viaSymlink, viaRealPath)
    }

    func testASymlinkedDirectoryInTheMiddleOfThePathIsResolved() throws {
        let tempRoot = try makeTempRoot()
        let realDir = tempRoot.appendingPathComponent("RealDir", isDirectory: true)
        let app = realDir.appendingPathComponent("App2.app", isDirectory: true)
        let executableDir = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try makeDirectory(executableDir)
        let realExecutable = executableDir.appendingPathComponent("Tool2")
        try makeFile(realExecutable)

        let linkDir = tempRoot.appendingPathComponent("LinkDir", isDirectory: true)
        try makeSymlink(at: linkDir, to: realDir)
        let viaSymlinkedDir = linkDir
            .appendingPathComponent("App2.app/Contents/MacOS/Tool2")

        let expected = BundleLayout.enclosingAppBundlePath(for: realExecutable)
        XCTAssertNotNil(expected)
        XCTAssertEqual(BundleLayout.enclosingAppBundlePath(for: viaSymlinkedDir), expected)
    }

    /// A symlink whose own path sits inside an `.app` but whose target does
    /// not must not be mistaken for containment — `resolvingSymlinksInPath`
    /// is applied to the whole path, including its last component, before the
    /// walk ever starts.
    func testSymlinkTargetingOutsideAnyAppYieldsNilEvenInsideAnApp() throws {
        let tempRoot = try makeTempRoot()
        let outside = tempRoot.appendingPathComponent("Outside", isDirectory: true)
        try makeDirectory(outside)
        let payload = outside.appendingPathComponent("Payload")
        try makeFile(payload)

        let app = tempRoot.appendingPathComponent("App3.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try makeDirectory(resources)
        let linkInsideApp = resources.appendingPathComponent("Link3")
        try makeSymlink(at: linkInsideApp, to: payload)

        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: linkInsideApp))
    }

    // MARK: - Non-file and relative URLs

    func testNonFileURLYieldsNil() {
        let url = URL(string: "https://example.com/Fake.app/thing")!
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: url))
    }

    func testRelativeFileURLYieldsNil() {
        let url = URL(string: "file:relative/Fake.app")!
        XCTAssertTrue(url.isFileURL)
        XCTAssertFalse(url.path.hasPrefix("/"))
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: url))
    }

    // MARK: - Nesting

    func testNearestEnclosingAppWinsWhenAppsAreNested() throws {
        let tempRoot = try makeTempRoot()
        let outer = tempRoot.appendingPathComponent("Outer.app", isDirectory: true)
        let inner = outer.appendingPathComponent("Contents/PlugIns/Inner.app", isDirectory: true)
        let executableDir = inner.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try makeDirectory(executableDir)
        let executable = executableDir.appendingPathComponent("Tool")
        try makeFile(executable)

        let result = BundleLayout.enclosingAppBundlePath(for: executable)
        XCTAssertEqual(result, inner.resolvingSymlinksInPath().path)
        XCTAssertNotEqual(result, outer.resolvingSymlinksInPath().path)
    }

    // MARK: - Bounded walk with no `.app` component

    func testPathWithNoAppComponentReturnsNil() {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/gs")
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: executable))
    }

    func testRootPathReturnsNil() {
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: URL(fileURLWithPath: "/")))
    }

    func testEmptyPathReturnsNil() {
        // `URL(fileURLWithPath: "")` resolves against the process's current
        // directory, which for a test run is never inside an `.app`.
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: URL(fileURLWithPath: "")))
    }
}
