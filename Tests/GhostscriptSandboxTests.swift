import Foundation
import XCTest

/// Covers the `sandbox-exec` profile text `GhostscriptSandbox` builds — the
/// second, independent confinement layer behind `-dSAFER`. These assertions
/// exist because the actual permission set was worked out empirically against
/// a real `sandbox-exec`/`gs`: several of them (the ancestor-directory
/// literals, the raw-*and*-resolved path pair) are not obvious from reading
/// the SBPL language alone, and a regression here would silently widen or
/// break the child's confinement.
final class GhostscriptSandboxTests: XCTestCase {

    private func profile(gs: String = "/opt/homebrew/bin/gs",
                         roots: [String] = ["/opt/homebrew"],
                         scratch: String = "/private/tmp/eps-preview-test") -> String {
        GhostscriptSandbox.profile(gsExecutablePath: gs, readOnlyRoots: roots, scratchDirectory: scratch)
    }

    func testDeniesEverythingByDefaultAndDeniesNetworkExplicitly() {
        let text = profile()
        XCTAssertTrue(text.contains("(deny default)"))
        XCTAssertTrue(text.contains("(deny network*)"))
    }

    func testAllowsExecOnlyOfTheResolvedInterpreterPath() throws {
        // A plain regular file (never a symlink) so this does not depend on
        // whether this machine happens to have a real Ghostscript install.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gs-sandbox-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let plainGS = directory.appendingPathComponent("gs")
        try Data("#!/bin/sh\n".utf8).write(to: plainGS)

        let text = profile(gs: plainGS.path)
        XCTAssertTrue(text.contains(#"(allow process-exec (literal "\#(plainGS.path)"))"#),
                     "a path with no symlinks to resolve must appear unchanged:\n\(text)")
        XCTAssertTrue(text.contains(#"(allow file-map-executable (literal "\#(plainGS.path)"))"#))
    }

    func testResolvesSymlinksInTheInterpreterPathForTheExecRule() throws {
        // Homebrew's `/opt/homebrew/bin/gs` is itself exactly this shape: a
        // symlink into a versioned Cellar path.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gs-sandbox-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let realTarget = directory.appendingPathComponent("real-gs")
        try Data("#!/bin/sh\n".utf8).write(to: realTarget)
        let symlinkedGS = directory.appendingPathComponent("gs")
        try FileManager.default.createSymbolicLink(at: symlinkedGS, withDestinationURL: realTarget)

        let text = profile(gs: symlinkedGS.path)
        XCTAssertTrue(text.contains(#"(allow process-exec (literal "\#(realTarget.path)"))"#),
                     "process-exec must match the resolved target the kernel actually execs, not the symlink:\n\(text)")
        XCTAssertFalse(text.contains(#"process-exec (literal "\#(symlinkedGS.path)")"#),
                       "the unresolved symlink form must not appear as an exec rule:\n\(text)")
    }

    func testAllowsReadOfEachResourceRootAsASubpath() {
        let text = profile(roots: ["/opt/homebrew", "/usr/local"])
        XCTAssertTrue(text.contains(#"(subpath "/opt/homebrew")"#))
        XCTAssertTrue(text.contains(#"(subpath "/usr/local")"#))
    }

    func testAllowsReadAndWriteOfTheScratchDirectoryAndItsAncestorsUpToRoot() {
        let text = profile(scratch: "/private/tmp/eps-preview-test")
        XCTAssertTrue(text.contains(#"(allow file* (subpath "/private/tmp/eps-preview-test"))"#),
                     "the scratch directory itself must be fully read/write:\n\(text)")
        // Traversing down to a several-components-deep scratch directory (and
        // Ghostscript's own mkstemp-style temp files inside it) needs every
        // ancestor directory allowed too, not just the scratch subtree —
        // `subpath` alone does not cover a read of an ancestor node itself.
        for ancestor in ["/", "/private", "/private/tmp"] {
            XCTAssertTrue(text.contains(#"(literal "\#(ancestor)")"#),
                         "missing ancestor literal for \(ancestor):\n\(text)")
        }
    }

    func testAllowsBothTheRawAndSymlinkResolvedFormsOfATempPath() {
        // "/tmp" -> "/private/tmp": Ghostscript's temp files, and the sandbox's
        // own checks, may use either spelling, so both must be covered.
        let text = profile(scratch: "/tmp/eps-preview-test")
        XCTAssertTrue(text.contains(#"(allow file* (subpath "/tmp/eps-preview-test"))"#))
        XCTAssertTrue(text.contains(#"(allow file* (subpath "/private/tmp/eps-preview-test"))"#))
        XCTAssertTrue(text.contains(#"(literal "/tmp")"#))
        XCTAssertTrue(text.contains(#"(literal "/private/tmp")"#))
    }

    func testAllowsTheDeviceFilesGhostscriptNeeds() {
        let text = profile()
        for device in ["/dev/null", "/dev/urandom", "/dev/random"] {
            XCTAssertTrue(text.contains(#"(literal "\#(device)")"#), "missing \(device):\n\(text)")
        }
    }

    func testEscapesQuotesAndBackslashesInPaths() {
        let text = profile(scratch: #"/private/tmp/weird "quoted" \path"#)
        XCTAssertTrue(text.contains(#"\"quoted\""#), "unescaped quote would break the SBPL string:\n\(text)")
        XCTAssertTrue(text.contains(#"\\path"#), "unescaped backslash would break the SBPL string:\n\(text)")
    }

    func testDoesNotAllowExecOfAnythingUnderTheScratchDirectory() {
        // The scratch directory is writable; an attacker who can write a
        // payload there must still not be able to run it, so no
        // process-exec/file-map-executable rule may name a scratch path.
        let text = profile(scratch: "/private/tmp/eps-preview-test")
        for line in text.split(separator: "\n") where line.contains("process-exec") || line.contains("file-map-executable") {
            XCTAssertFalse(line.contains("eps-preview-test"),
                          "scratch directory must never be exec-able: \(line)")
        }
    }
}
