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
                         execRoots: [String] = [],
                         scratch: String = "/private/tmp/eps-preview-test") -> String {
        GhostscriptSandbox.profile(gsExecutablePath: gs, readOnlyRoots: roots,
                                   executableRoots: execRoots, scratchDirectory: scratch)
    }

    /// The `(allow file-map-executable ...)` group as a standalone string —
    /// groups are blank-line-separated, so this covers only that rule, not
    /// any subpath/literal that happens to also appear in the `file-read*`
    /// or `file*` groups.
    private func fileMapExecutableBlock(in text: String) -> String? {
        text.components(separatedBy: "\n\n").first { $0.hasPrefix("(allow file-map-executable") }
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
        let mapExecutable = fileMapExecutableBlock(in: text)
        XCTAssertTrue(mapExecutable?.contains(#"(literal "\#(plainGS.path)")"#) ?? false,
                     "the interpreter itself must be file-map-executable:\n\(text)")
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
        // breaks-if: the `resolvingSymlinksInPath()` call producing resolvedGS is dropped and the raw gsExecutablePath goes into the process-exec rule.
        XCTAssertFalse(text.contains(#"process-exec (literal "\#(symlinkedGS.path)")"#),
                       "the unresolved symlink form must not appear as an exec rule:\n\(text)")
    }

    func testAllowsReadOfEachResourceRootAsASubpath() {
        let text = profile(roots: ["/opt/homebrew", "/usr/local"])
        XCTAssertTrue(text.contains(#"(subpath "/opt/homebrew")"#))
        XCTAssertTrue(text.contains(#"(subpath "/usr/local")"#))
    }

    func testAllowsReadOfPrivateEtcUnconditionally() {
        let text = profile(roots: [])
        XCTAssertTrue(text.contains(#"(subpath "/private/etc")"#),
                     "gs needs /etc config files readable even with no configured roots:\n\(text)")
    }

    func testResolvesSymlinksInAReadOnlyRootToASubpathToo() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gs-sandbox-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let realRoot = directory.appendingPathComponent("real-root")
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let symlinkedRoot = directory.appendingPathComponent("root-link")
        try FileManager.default.createSymbolicLink(at: symlinkedRoot, withDestinationURL: realRoot)

        let text = profile(roots: [symlinkedRoot.path])
        XCTAssertTrue(text.contains(#"(subpath "\#(symlinkedRoot.path)")"#), text)
        XCTAssertTrue(text.contains(#"(subpath "\#(realRoot.path)")"#), text)
    }

    // MARK: - file-map-executable for gs's own dylibs

    func testGrantsFileMapExecutableOnTheExecutableRootsAndSystemLibraryPaths() {
        // gs's dependent libraries are mapped executable by dyld to load —
        // a plain file-read* grant on their directory (still asserted above)
        // is not enough; without this, gs cannot start under the profile at
        // all (see GhostscriptSandboxIntegrationTests, which exercises this
        // against a real gs and a real sandbox-exec).
        let text = profile(roots: ["/opt/homebrew"], execRoots: ["/opt/homebrew/lib"])
        let mapExecutable = fileMapExecutableBlock(in: text)
        XCTAssertTrue(mapExecutable?.contains(#"(subpath "/opt/homebrew/lib")"#) ?? false,
                     "missing the resolved dylib root:\n\(text)")
        XCTAssertTrue(mapExecutable?.contains(#"(subpath "/System")"#) ?? false,
                     "missing the system library path dyld needs:\n\(text)")
        XCTAssertTrue(mapExecutable?.contains(#"(subpath "/usr/lib")"#) ?? false,
                     "missing the system library path dyld needs:\n\(text)")
    }

    func testGrantsSystemLibraryPathsFileMapExecutableEvenWithNoExecutableRoots() {
        // The bundled-copy and system-install resolution paths always pass at
        // least one executable root, but the profile builder itself should
        // not depend on that: /System and /usr/lib are needed by every gs.
        let text = profile(execRoots: [])
        let mapExecutable = fileMapExecutableBlock(in: text)
        XCTAssertTrue(mapExecutable?.contains(#"(subpath "/System")"#) ?? false)
        XCTAssertTrue(mapExecutable?.contains(#"(subpath "/usr/lib")"#) ?? false)
    }

    func testKeepsProcessExecRestrictedToGSItselfWhenGrantingFileMapExecutable() throws {
        // Widening file-map-executable to the dylib roots must not also
        // widen what may be exec'd as a process — that stays gs alone. A
        // synthetic, never-a-symlink path (rather than a hardcoded
        // "/opt/homebrew/bin/gs") so this does not depend on whether this
        // machine's own Homebrew gs happens to be a symlink into Cellar.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gs-sandbox-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let plainGS = directory.appendingPathComponent("gs")
        try Data("#!/bin/sh\n".utf8).write(to: plainGS)

        let text = profile(gs: plainGS.path, roots: ["/opt/homebrew"], execRoots: ["/opt/homebrew/lib"])
        let execLines = text.split(separator: "\n").filter { $0.contains("process-exec") }
        guard let execLine = execLines.first, execLines.count == 1 else {
            XCTFail("expected exactly one process-exec line, got \(execLines)")
            return
        }
        XCTAssertTrue(execLine.contains(#"(literal "\#(plainGS.path)")"#), "\(execLine)")
    }

    func testDoesNotWidenWriteScopeWhenGrantingFileMapExecutable() {
        // A plain, non-symlinked scratch path so exactly one `file*` grant is
        // expected (the raw-and-resolved doubling for /tmp-style paths is
        // covered separately by testAllowsBothTheRawAndSymlinkResolvedFormsOfATempPath).
        let text = profile(roots: ["/opt/homebrew"], execRoots: ["/opt/homebrew/lib"],
                           scratch: "/opt/eps-preview-scratch-test")
        let writeLines = text.split(separator: "\n").filter { $0.contains("(allow file*") }
        guard let writeLine = writeLines.first, writeLines.count == 1 else {
            XCTFail("only the scratch directory may be written:\n\(text)")
            return
        }
        XCTAssertTrue(writeLine.contains("eps-preview-scratch-test"), "\(writeLine)")
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

    // breaks-if: the `raw == special` half of canonicalPathVariants's condition is removed.
    func testAllowsBothFormsWhenTheScratchDirectoryIsExactlyTmp() {
        let text = profile(scratch: "/tmp")
        XCTAssertTrue(text.contains(#"(allow file* (subpath "/tmp"))"#), text)
        XCTAssertTrue(text.contains(#"(allow file* (subpath "/private/tmp"))"#), text)
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
        // process-exec/file-map-executable rule may name a scratch path —
        // checked against the whole (possibly multi-line) file-map-executable
        // group, not just its header line.
        let text = profile(roots: ["/opt/homebrew"], execRoots: ["/opt/homebrew/lib"],
                           scratch: "/private/tmp/eps-preview-test")
        for line in text.split(separator: "\n") where line.contains("process-exec") {
            // breaks-if: a scratch path is added to the `(allow process-exec ...)` rule alongside resolvedGS.
            XCTAssertFalse(line.contains("eps-preview-test"),
                          "scratch directory must never be exec-able: \(line)")
        }
        // breaks-if: scratchVariants (or scratchAncestors) are merged into execRoots, the file-map-executable group.
        XCTAssertFalse(fileMapExecutableBlock(in: text)?.contains("eps-preview-test") ?? true,
                      "scratch directory must never be file-map-executable:\n\(text)")
    }

    // breaks-if: the scratch `(deny file-map-executable ...)` rule is dropped or emitted before `(allow file* ...)`.
    func testTakesFileMapExecutableBackFromTheScratchDirectorysBroadFileGrant() {
        // SBPL's last matching rule wins, so the deny must follow the grant.
        // `(allow file* ...)` is an operation-class wildcard, so the dedicated
        // file-map-executable group above staying clean of the scratch path
        // is not enough on its own: the broad grant must be followed by an
        // explicit deny for every spelling of the scratch directory.
        let text = profile(scratch: "/tmp/eps-preview-test")
        let lines = text.split(separator: "\n").map(String.init)
        for scratch in ["/tmp/eps-preview-test", "/private/tmp/eps-preview-test"] {
            let grant = lines.firstIndex(of: #"(allow file* (subpath "\#(scratch)"))"#)
            let deny = lines.firstIndex(of: #"(deny file-map-executable (subpath "\#(scratch)"))"#)
            XCTAssertNotNil(grant, "missing the scratch grant for \(scratch):\n\(text)")
            XCTAssertNotNil(deny, "missing the file-map-executable deny for \(scratch):\n\(text)")
            if let grant, let deny {
                XCTAssertGreaterThan(deny, grant, "the deny must come after the grant it overrides:\n\(text)")
            }
        }
    }
}
