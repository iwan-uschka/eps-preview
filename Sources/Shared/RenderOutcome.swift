import Foundation

/// How a Ghostscript child ended, in exactly the terms the reply depends on.
/// Lifted out of `Process` so the outcome rules below can be exercised without
/// launching an interpreter — `Process` offers no way to fabricate a signal
/// death or a specific exit status.
struct RenderTermination {
    /// True when the child died from a signal rather than returning a status
    /// (`Process.terminationReason == .uncaughtSignal`).
    let killedBySignal: Bool
    /// The exit status, or — when `killedBySignal` — the signal number.
    let status: Int32
    /// Whether *our* watchdog is what fired; a child can be signalled for
    /// other reasons (the `ulimit -f` SIGXFSZ below among them).
    let timedOut: Bool
}

/// Turns an exited Ghostscript into the reply the extensions show. Lives in
/// `Sources/Shared` rather than next to the process plumbing in
/// `RenderService` so the branch-per-outcome logic is reachable from tests.
enum RenderOutcome {

    /// Ghostscript's stderr is drained continuously, but only its head is
    /// reported back: enough for the message, bounded so a chatty file cannot
    /// grow the reply without limit.
    static let maxErrorMessageCharacters = 600

    /// `timedOut` alone never decides the outcome: a render that finished on
    /// its own in the instant the watchdog fired still exited normally, and
    /// its result is used.
    static func result(for termination: RenderTermination,
                       errorOutput: Data,
                       outputPath: String) -> (pdf: Data?, error: String?) {
        let outputLimitMB = RenderLimits.maxOutputBytes / (1024 * 1024)

        if termination.killedBySignal {
            if termination.timedOut {
                return (nil, "Ghostscript timed out after \(Int(RenderLimits.renderTimeout))s "
                    + "and was terminated.")
            }
            if termination.status == SIGXFSZ {
                return (nil, "The rendered PDF exceeds the \(outputLimitMB) MB preview output limit.")
            }
        }

        guard termination.status == 0 else {
            return (nil, "Ghostscript exited with status \(termination.status). "
                + diagnostic(errorOutput))
        }

        // Check the size before reading: `pdfwrite` output is bounded by the
        // child's rlimit, which is a coarse backstop, not this limit.
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath)
        guard let size = attributes?[.size] as? Int, size > 0 else {
            return (nil, "Ghostscript reported success but produced no PDF output.")
        }
        guard size <= RenderLimits.maxOutputBytes else {
            return (nil, "The rendered PDF exceeds the \(outputLimitMB) MB preview output limit.")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)), !data.isEmpty else {
            return (nil, "Ghostscript reported success but produced no PDF output.")
        }
        return (data, nil)
    }

    /// Ghostscript's diagnostics are not guaranteed UTF-8 — font and DSC
    /// warnings routinely carry 8-bit bytes taken from the file itself.
    /// Latin-1 maps every byte 1:1 and never fails (the same fallback
    /// `wantsInterpolation` relies on), so the real message is never replaced
    /// by "unknown error".
    static func diagnostic(_ errorOutput: Data) -> String {
        let text = String(data: errorOutput, encoding: .utf8)
            ?? String(data: errorOutput, encoding: .isoLatin1)
            ?? "unknown error"
        return String(text.prefix(maxErrorMessageCharacters))
    }
}
