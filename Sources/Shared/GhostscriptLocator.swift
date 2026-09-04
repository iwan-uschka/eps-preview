import Foundation

/// Finds the Ghostscript interpreter and builds the environment it may run
/// with. Shared so the render service (which executes `gs`) and the host app
/// (which only reports whether a usable `gs` exists) can never disagree about
/// what counts as an installed Ghostscript.
///
/// Ghostscript is located in this order:
///   1. a self-contained copy bundled in the host app's `Contents/Helpers/gs`
///      (used by downloaded release builds — no Homebrew required), then
///   2. a system install (Homebrew / MacPorts), for build-from-source users.
enum GhostscriptLocator {

    /// A resolved Ghostscript: the executable plus the environment it needs
    /// (the bundled copy needs GS_LIB pointing at its resource files).
    struct Ghostscript {
        let executablePath: String
        let environment: [String: String]
    }

    private static let systemCandidates = [
        "/opt/homebrew/bin/gs",   // Apple-silicon Homebrew
        "/usr/local/bin/gs",      // Intel Homebrew
        "/opt/local/bin/gs",      // MacPorts
        "/usr/bin/gs",
    ]

    /// Oldest system Ghostscript we are willing to execute. 9.50 is the
    /// release that made `-dSAFER` the enforced default and rewrote its
    /// file-access controls — older builds predate the sandbox every render
    /// relies on, and we have no way to re-add it from the outside.
    private static let minimumSystemVersion = (major: 9, minor: 50)

    /// A substituted `gs` can hang instead of printing a version, and the
    /// probe runs before any render, so it needs its own bound.
    private static let versionProbeTimeout: TimeInterval = 5

    private static let cacheLock = NSLock()
    private static var cachedGhostscript: Ghostscript?

    /// A successful resolution is cached for the life of the process: it costs
    /// several `stat`s plus a `--version` probe and sits on the path of every
    /// render. A *failed* resolution is deliberately not cached, so a
    /// long-lived caller still notices a Ghostscript installed after launch.
    static func locate() -> Ghostscript? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedGhostscript { return cachedGhostscript }
        let resolved = bundledGhostscript() ?? systemGhostscript()
        cachedGhostscript = resolved
        return resolved
    }

    /// The environment a Ghostscript child is allowed to see. Built from
    /// scratch rather than inherited: `gs` honors GS_OPTIONS (prepended as if
    /// typed on the command line), GS_FONTPATH and `-I` grants, and dyld
    /// honors DYLD_*. Inheriting our own environment would let anything that
    /// can set a user/launchd variable once reconfigure every later render.
    static func childEnvironment(gsLib: String? = nil) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        if let gsLib { environment["GS_LIB"] = gsLib }
        return environment
    }

    /// Looks for a self-contained Ghostscript at `<HostApp>.app/Contents/Helpers/gs/`.
    private static func bundledGhostscript() -> Ghostscript? {
        guard let appPath = BundleLayout.enclosingAppBundlePath(for: Bundle.main.bundleURL) else {
            return nil
        }
        let url = URL(fileURLWithPath: appPath)

        let binary = url.appendingPathComponent("Contents/Helpers/gs/converter")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }

        // Resources live under Contents/Resources/ (codesign refuses to seal a
        // big loose data tree that sits alongside Mach-O binaries).
        let share = url.appendingPathComponent("Contents/Resources/ghostscript", isDirectory: true)
        let gsLib = [
            share.appendingPathComponent("Resource/Init").path,
            share.appendingPathComponent("lib").path,
            share.appendingPathComponent("Resource/Font").path,
        ].joined(separator: ":")

        // The bundled copy is version-pinned at package time and sealed by the
        // app's signature, so it needs neither ownership nor version vetting.
        return Ghostscript(executablePath: binary.path, environment: childEnvironment(gsLib: gsLib))
    }

    private static func systemGhostscript() -> Ghostscript? {
        for path in systemCandidates
        where FileManager.default.isExecutableFile(atPath: path)
            && hasTrustworthyOwnership(path)
            && meetsMinimumVersion(path) {
            return Ghostscript(executablePath: path, environment: childEnvironment())
        }
        return nil
    }

    /// Rejects a candidate that some *other* unprivileged account could have
    /// swapped out: a group/world-writable binary or parent directory, or a
    /// binary owned by a third user.
    ///
    /// We deliberately do not require root ownership even though the audited
    /// remediation suggested it — Homebrew's prefix is owned by the console
    /// user, so root-only would reject the documented build-from-source
    /// install path entirely. A same-uid attacker can replace anything this
    /// process is allowed to read, and no check made *by* this process can
    /// change that.
    private static func hasTrustworthyOwnership(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return isWritableOnlyByOwner(resolved.path)
            && isWritableOnlyByOwner(resolved.deletingLastPathComponent().path)
    }

    private static func isWritableOnlyByOwner(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let owner = attributes[.ownerAccountID] as? NSNumber,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return false
        }
        guard owner.uint32Value == 0 || owner.uint32Value == getuid() else { return false }
        return permissions.int32Value & 0o022 == 0
    }

    private static func meetsMinimumVersion(_ path: String) -> Bool {
        guard let version = probeVersion(path) else { return false }
        let fields = version.split(separator: ".").compactMap { Int($0) }
        guard fields.count >= 2 else { return false }
        if fields[0] != minimumSystemVersion.major { return fields[0] > minimumSystemVersion.major }
        return fields[1] >= minimumSystemVersion.minor
    }

    private static func probeVersion(_ path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.environment = childEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + versionProbeTimeout, execute: deadline)
        // `gs --version` prints one short line, so reading to EOF cannot fill
        // the pipe buffer; the work item above bounds a candidate that hangs
        // instead of answering.
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()

        guard process.terminationStatus == 0,
              let text = String(data: output, encoding: .utf8) else {
            return nil
        }
        return text.split(whereSeparator: \.isNewline).first.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }
}
