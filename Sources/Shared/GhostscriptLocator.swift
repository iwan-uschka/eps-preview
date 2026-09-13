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

    /// `scripts/lib/ghostscript-check.sh` mirrors this list, the ownership
    /// vetting and the version floor below in shell, because `scripts/install.sh`
    /// has to answer "is Ghostscript installed?" with the same rules the service
    /// will apply — otherwise the installer reports a green check for an
    /// interpreter every render then refuses. Change anything here and change it
    /// there too; `scripts/test-ghostscript-check.sh` pins that side.
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

    /// How long a *failed* lookup is remembered before it is attempted again.
    /// Long enough that a candidate which hangs until `versionProbeTimeout`
    /// cannot make every render pay for it, short enough that a Ghostscript
    /// installed while a Quick Look agent is already alive starts working
    /// without a logout.
    private static let failedResolutionTTL: TimeInterval = 30

    private static let resolutionCache = GhostscriptResolutionCache(
        failureTTL: failedResolutionTTL,
        clock: { ProcessInfo.processInfo.systemUptime },
        resolve: { bundledGhostscript() ?? systemGhostscript() })

    /// A successful resolution is cached for the life of the process: it costs
    /// several `stat`s plus a `--version` probe and sits on the path of every
    /// render. A *failed* one is cached for `failedResolutionTTL` only: a
    /// missing, hanging or too-old `gs` then costs one probe per window
    /// instead of one probe per render, while a Ghostscript installed after
    /// launch is still picked up — within that window rather than never.
    static func locate() -> Ghostscript? {
        resolutionCache.locate()
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
        return versionString(version, meetsMinimum: minimumSystemVersion)
    }

    /// Compares what `gs --version` printed against a floor. Split out from
    /// the probe so the comparison can be exercised without an interpreter on
    /// disk. Anything that does not read as `<major>.<minor>` is rejected
    /// rather than guessed at, a bare "10" included: a string we cannot parse
    /// is as likely to come from a substituted binary as from a real release.
    /// The minor field is compared exactly as printed, so "9.5" is *below*
    /// "9.50" — Ghostscript writes the two-digit form, and reading "9.5" as
    /// 9.50 would accept the pre-`-dSAFER` 9.05 line too.
    static func versionString(_ text: String, meetsMinimum minimum: (major: Int, minor: Int)) -> Bool {
        let fields = text.split(separator: ".").compactMap { Int($0) }
        guard fields.count >= 2 else { return false }
        if fields[0] != minimum.major { return fields[0] > minimum.major }
        return fields[1] >= minimum.minor
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

/// The caching policy in front of Ghostscript resolution, kept separate from
/// the lookup itself so it can be exercised with an injected clock and a fake
/// resolver instead of a real interpreter on disk.
///
/// The lock is held *across* the resolution, not merely around the cache
/// read/write, and that is deliberate: resolving spawns `gs --version` with a
/// multi-second bound, and a Finder folder fan-out asks several renders at
/// once. Serializing them means N concurrent callers spawn one probe and all
/// receive its result, rather than N probes racing to write the same answer.
final class GhostscriptResolutionCache {

    private let failureTTL: TimeInterval
    private let clock: () -> TimeInterval
    private let resolve: () -> GhostscriptLocator.Ghostscript?

    private let lock = NSLock()
    private var resolved: GhostscriptLocator.Ghostscript?
    private var failedAt: TimeInterval?

    /// - Parameters:
    ///   - failureTTL: how long a nil result is reused before resolving again.
    ///   - clock: seconds from an arbitrary origin. Production passes
    ///     `ProcessInfo.processInfo.systemUptime`, which — unlike a wall
    ///     clock — no time adjustment can move backwards mid-window.
    ///   - resolve: the actual lookup; run at most once per window.
    init(failureTTL: TimeInterval,
         clock: @escaping () -> TimeInterval,
         resolve: @escaping () -> GhostscriptLocator.Ghostscript?) {
        self.failureTTL = failureTTL
        self.clock = clock
        self.resolve = resolve
    }

    /// A success is answered from the cache for the life of the instance; a
    /// failure only until its window expires.
    func locate() -> GhostscriptLocator.Ghostscript? {
        lock.lock()
        defer { lock.unlock() }
        if let resolved { return resolved }
        if let failedAt, clock() < failedAt + failureTTL { return nil }
        guard let found = resolve() else {
            failedAt = clock()
            return nil
        }
        resolved = found
        failedAt = nil
        return found
    }
}
