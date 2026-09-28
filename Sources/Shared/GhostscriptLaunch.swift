import Foundation

/// The exact `/bin/sh` → `sandbox-exec` → `gs` command line `RenderService`
/// launches for every render, and the rlimits it applies on the way.
///
/// Lives in `Sources/Shared` rather than next to the process plumbing in
/// `RenderService` (which the test target does not compile) so a test can run
/// this very script and argument order — including the `shift`/positional
/// wiring between the Swift array and the script's `$1`/`$2`/`$3` — instead of
/// a hand-built approximation that would keep passing if the two drifted.
///
/// Ghostscript runs behind `sh -c 'ulimit …; exec sandbox-exec -p "$profile" …'`
/// because Process offers no hook for setting a child's rlimits or for
/// confining it with a sandbox profile. Both `sh`'s `exec` and
/// `sandbox-exec`'s own launch of its target replace the running process image
/// rather than forking, so despite the two hops the process `RenderService`
/// tracks, signals and reaps is — throughout — Ghostscript's, once it starts.
///
/// RLIMIT_AS is deliberately not among the ulimits below: macOS refuses to
/// lower it for the calling process at all — setrlimit returns EINVAL for any
/// finite value, not just this shell's `ulimit -v` (which fails the identical
/// way, and is why it is not attempted here). Memory exhaustion is bounded
/// instead by what is already in place: RenderLimits.maxInputBytes, RLIMIT_CPU
/// below backing the render timeout, and RenderLimits.maxConcurrentRenders
/// capping how many interpreters can be inflating memory at once.
enum GhostscriptLaunch {

    static let shellPath = "/bin/sh"
    static let sandboxExecPath = "/usr/bin/sandbox-exec"

    /// The status the wrapper script exits with when one of its `ulimit`
    /// calls fails, before Ghostscript is ever started. `RenderOutcome` has
    /// no dedicated category for it: like any other non-zero, non-signalled
    /// exit it is reported as `.malformedInput`.
    static let limitFailureStatus: Int32 = 71

    /// Grace period between SIGTERM and SIGKILL for a render that overran.
    static let terminationGracePeriod: TimeInterval = 2

    /// The rlimits the wrapper applies, in the order the script reads them.
    struct Limits {
        /// `ulimit -f`, in the shell's own blocks.
        let outputBlocks: Int
        /// `ulimit -t`, in seconds of CPU time.
        let cpuSeconds: Int
        /// `ulimit -u`: RLIMIT_NPROC, a per-uid count checked at `fork()`.
        let processes: Int

        /// What every production render runs with.
        static let production = Limits(
            // `ulimit -f` counts blocks whose size differs between shells, so
            // this is a deliberately generous backstop; the exact cap is
            // enforced on the finished file.
            outputBlocks: RenderLimits.maxOutputBytes / 512,
            cpuSeconds: GhostscriptLaunch.cpuTimeLimitSeconds,
            processes: GhostscriptLaunch.processLimit)
    }

    /// Kernel-enforced backstop for a render that outlives the watchdog when
    /// the watchdog's own dispatch never ran (queue starved) and gs is still
    /// actively burning CPU. Does *not* cover a child stuck in an
    /// uninterruptible wait (see `RenderService`'s watchdog) — that case
    /// accrues no CPU time either. Comfortably above the watchdog's own
    /// timeout-then-SIGKILL sequence so it never preempts the normal path.
    static let cpuTimeLimitSeconds =
        Int(RenderLimits.renderTimeout) + Int(terminationGracePeriod) + 10

    /// Ghostscript run with `-dSAFER` has no legitimate reason to fork or
    /// exec anything, and the sandbox profile denies both outright; this is
    /// the same guarantee enforced independently by the kernel's own process
    /// accounting. 1 rather than 0: some libc paths assume a strictly-positive
    /// limit.
    static let processLimit = 1

    /// `$0` is a fixed placeholder; `$1`–`$3` are the three limits, `$4` the
    /// profile, and everything after it the command `sandbox-exec` runs.
    static let script = #"""
        ulimit -f "$1" || { echo "could not limit Ghostscript output size" >&2; exit \#(limitFailureStatus); }
        ulimit -t "$2" || { echo "could not limit Ghostscript CPU time" >&2; exit \#(limitFailureStatus); }
        ulimit -u "$3" || { echo "could not limit Ghostscript process count" >&2; exit \#(limitFailureStatus); }
        shift 3
        profile="$1"; shift
        exec \#(sandboxExecPath) -p "$profile" "$@"
        """#

    /// The `/bin/sh` arguments that apply `limits`, then replace the shell
    /// with `command` confined by `sandboxProfile`. Split from
    /// `arguments(for:inputPath:outputPath:limits:)` so a test can run the
    /// wrapper around a command other than Ghostscript and observe which limit
    /// actually landed where.
    static func wrapperArguments(limits: Limits,
                                 sandboxProfile: String,
                                 command: [String]) -> [String] {
        [
            "-c", script,
            "gs-sandbox",
            String(limits.outputBlocks),
            String(limits.cpuSeconds),
            String(limits.processes),
            sandboxProfile,
        ] + command
    }

    /// Ghostscript's own flags for one EPS → PDF conversion.
    static func ghostscriptArguments(inputPath: String, outputPath: String) -> [String] {
        [
            "-dNOPAUSE", "-dBATCH", "-dQUIET",
            "-dSAFER",                 // sandbox Ghostscript's own file/IO ops
            "-dEPSCrop",               // crop to the EPS BoundingBox
            "-dAutoRotatePages=/None", // keep the figure's authored orientation
            "-sstdout=%stderr",        // gs reports errors on stdout; merge them
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.4",
            "-sOutputFile=" + outputPath,
            inputPath,
        ]
    }

    /// The full `/bin/sh` argument list for rendering `inputPath` into
    /// `outputPath` with `gs`, confined by `gs.sandboxProfile`.
    static func arguments(for gs: GhostscriptLocator.Ghostscript,
                          inputPath: String,
                          outputPath: String,
                          limits: Limits = .production) -> [String] {
        wrapperArguments(limits: limits,
                         sandboxProfile: gs.sandboxProfile,
                         command: [gs.executablePath]
                            + ghostscriptArguments(inputPath: inputPath, outputPath: outputPath))
    }
}
