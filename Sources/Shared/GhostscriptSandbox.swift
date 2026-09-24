import Foundation

/// Builds the `sandbox-exec` profile (SBPL) that confines the Ghostscript
/// child `RenderService` runs: read access to its own resource tree plus the
/// one scratch directory holding its staged input/output, write access to
/// that scratch directory only, network and everything-else-exec denied
/// outright.
///
/// This exists because `-dSAFER` is not enough on its own — it has a
/// repeated history of full bypasses (CVE-2023-36664, CVE-2024-29510 and
/// predecessors), and thumbnail generation is zero-click (viewing a folder in
/// Finder renders every EPS in it). The sandbox is the second, independent
/// layer: even a `gs` that has escaped `-dSAFER` entirely still cannot read
/// the user's other files, write outside its scratch directory, reach the
/// network, or exec anything.
///
/// `sandbox-exec` is documented as deprecated in favour of the App Sandbox
/// entitlement-based model — but that model confines an *app*, declared at
/// build time; it has no mechanism for a process to confine a *specific child
/// it is about to launch* with a profile computed from that child's
/// just-resolved path. `sandbox-exec` (a thin CLI over the same
/// `sandbox_init(3)` the entitlement model itself compiles down to) is still
/// the tool for that, still ships on every supported macOS version, and has
/// no replacement for this use case.
enum GhostscriptSandbox {

    /// Builds the profile text for `sandbox-exec -p`.
    ///
    /// - Parameters:
    ///   - gsExecutablePath: path to the interpreter, as given by
    ///     `GhostscriptLocator` — resolved internally, since `sandbox-exec`
    ///     matches `process-exec`/`file-map-executable` against the path the
    ///     kernel actually execs, not whatever symlink form was passed on
    ///     the command line (Homebrew's `/opt/homebrew/bin/gs` is one).
    ///   - readOnlyRoots: `GhostscriptLocator.Ghostscript.sandboxReadOnlyRoots`.
    ///   - scratchDirectory: the one directory the child may write to. Pass
    ///     `NSTemporaryDirectory()` — the same directory the caller staged
    ///     the input file into and will read the output file back from.
    ///     Ghostscript also creates further *unnamed* temp files of its own
    ///     alongside them, so the whole directory is allowed rather than
    ///     just those two paths.
    static func profile(gsExecutablePath: String,
                        readOnlyRoots: [String],
                        scratchDirectory: String) -> String {
        let resolvedGS = URL(fileURLWithPath: gsExecutablePath).resolvingSymlinksInPath().path
        let scratchVariants = canonicalPathVariants(scratchDirectory)
        // Reading or creating a file several components under a symlinked
        // ancestor (macOS's own temp dirs live under "/var", itself "/private/var")
        // needs the ancestor chain allowed too — `subpath` alone covers a
        // path *and its descendants*, not the separate lookups the kernel
        // does resolving each ancestor directory on the way down to it, which
        // Ghostscript's own temp-file creation (mkstemp-style, not the two
        // paths this file already knows about) exercises even though a plain
        // read of an already-known file under `readOnlyRoots` does not.
        let scratchAncestors = scratchVariants
            .flatMap(ancestorLiterals)
            .reduceToSortedUnique()
        let readRoots = readOnlyRoots
            .flatMap(canonicalPathVariants)
            .reduceToSortedUnique()

        var lines = [
            "(version 1)",
            "(deny default)",
            "(deny network*)",
            "",
            "(allow process-exec \(literal(resolvedGS)))",
            "(allow file-map-executable \(literal(resolvedGS)))",
            "",
            "(allow file-read*",
        ]
        lines += scratchAncestors.map { "  " + literal($0) }
        lines.append("  (subpath \"/System\")")
        lines.append("  (subpath \"/usr/lib\")")
        lines.append("  (subpath \"/private/etc\")")
        lines += readRoots.map { "  " + subpath($0) }
        lines.append("  (literal \"/dev/null\")")
        lines.append("  (literal \"/dev/urandom\")")
        lines.append("  (literal \"/dev/random\"))")
        lines.append("")
        lines += scratchVariants.map { "(allow file* \(subpath($0)))" }

        return lines.joined(separator: "\n")
    }

    // MARK: - Path helpers

    /// A path as given, and again with every symlink resolved, deduplicated —
    /// most macOS temp/prefix paths involve at least one symlinked ancestor
    /// ("/tmp" -> "/private/tmp", "/var" -> "/private/var"), and which spelling
    /// a given syscall is checked against is not worth relying on, so both are
    /// allowed.
    ///
    /// `resolvingSymlinksInPath()` cannot be trusted alone here: Apple
    /// documents that it deliberately does *not* resolve `/etc`, `/tmp` or
    /// `/var` themselves, precisely because they are symlinks into
    /// `/private` — exactly the prefixes `NSTemporaryDirectory()` results
    /// fall under. That case is handled by hand below; every other symlink
    /// (a `/opt/homebrew` install root, say) still goes through Foundation's
    /// resolution.
    private static func canonicalPathVariants(_ path: String) -> [String] {
        let raw = URL(fileURLWithPath: path).standardizedFileURL.path
        var variants = [raw]

        for special in ["/tmp", "/var", "/etc"] where raw == special || raw.hasPrefix(special + "/") {
            variants.append("/private" + raw)
        }

        let resolved = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        if resolved != raw { variants.append(resolved) }

        return variants
    }

    /// `path` itself, then each parent up to and including "/".
    private static func ancestorLiterals(of path: String) -> [String] {
        var literals: [String] = []
        var url = URL(fileURLWithPath: path)
        while true {
            literals.append(url.path)
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return literals
    }

    private static func literal(_ path: String) -> String {
        "(literal \"\(escaped(path))\")"
    }

    private static func subpath(_ path: String) -> String {
        "(subpath \"\(escaped(path))\")"
    }

    /// SBPL strings follow the same escaping as Scheme/Lisp string literals.
    private static func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

private extension Array where Element == String {
    func reduceToSortedUnique() -> [String] {
        Array(Set(self)).sorted()
    }
}
