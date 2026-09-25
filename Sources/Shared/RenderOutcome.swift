import Foundation
import os

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

/// Turns an exited Ghostscript into the `RenderFailure` the extensions act on.
/// Lives in `Sources/Shared` rather than next to the process plumbing in
/// `RenderService` so the branch-per-outcome logic is reachable from tests.
enum RenderOutcome {

    /// Ghostscript's stderr is drained continuously, but only its head is
    /// logged: enough to debug from, bounded so a chatty file cannot grow the
    /// log entry without limit. It is never part of the reply — see
    /// `diagnostic`.
    static let maxErrorMessageCharacters = 600

    private static let log = Logger(subsystem: "com.zhangyanbo.EPSPreview.RenderService",
                                    category: "render")

    /// `timedOut` alone never decides the outcome: a render that finished on
    /// its own in the instant the watchdog fired still exited normally, and
    /// its result is used.
    ///
    /// Nothing Ghostscript wrote reaches the returned value. Its diagnostics
    /// are derived from the file being rendered, i.e. attacker-controlled
    /// text; they belong in the log for whoever debugs this, never in a reply
    /// a caller might draw in a panel the system provided. The caller gets a
    /// category it can branch on instead.
    static func result(for termination: RenderTermination,
                       errorOutput: Data,
                       outputPath: String) -> (pdf: Data?, failure: RenderFailure?) {
        if termination.killedBySignal {
            if termination.timedOut { return (nil, .timedOut) }
            if termination.status == SIGXFSZ { return (nil, .outputTooLarge) }
        }

        guard termination.status == 0 else {
            log.error("""
                Ghostscript exited with status \
                \(termination.status, privacy: .public): \
                \(diagnostic(errorOutput), privacy: .private)
                """)
            return (nil, .malformedInput)
        }

        // Check the size before reading: `pdfwrite` output is bounded by the
        // child's rlimit, which is a coarse backstop, not this limit.
        let attributes = try? FileManager.default.attributesOfItem(atPath: outputPath)
        guard let size = attributes?[.size] as? Int, size > 0 else {
            // Exit status 0 with nothing written is Ghostscript giving up on
            // the input quietly, not a fault of ours.
            log.error("Ghostscript reported success but produced no PDF output")
            return (nil, .malformedInput)
        }
        guard size <= RenderLimits.maxOutputBytes else {
            return (nil, .outputTooLarge)
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath)), !data.isEmpty else {
            // The file was there and non-empty a moment ago, so failing to
            // read it back is our own temp-directory problem, not the input's.
            log.error("Rendered PDF could not be read back from \(outputPath, privacy: .private)")
            return (nil, .internalError)
        }
        return (data, nil)
    }

    /// Ghostscript's diagnostics are not guaranteed UTF-8 — font and DSC
    /// warnings routinely carry 8-bit bytes taken from the file itself.
    /// Latin-1 maps every byte 1:1 and never fails, so the real message is
    /// never replaced by "unknown error" in the log.
    static func diagnostic(_ errorOutput: Data) -> String {
        let text = String(data: errorOutput, encoding: .utf8)
            ?? String(data: errorOutput, encoding: .isoLatin1)
            ?? "unknown error"
        return String(text.prefix(maxErrorMessageCharacters))
    }
}
