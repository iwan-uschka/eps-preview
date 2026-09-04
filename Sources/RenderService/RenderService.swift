import Foundation

/// Does the actual EPS → PDF conversion by shelling out to Ghostscript.
///
/// Runs inside the *unsandboxed* XPC service. It receives the EPS *bytes*
/// (not a path) from the extension and writes them to its own temp file —
/// this keeps it from ever touching the user's original file location (which
/// it has no TCC grant for), while still giving Ghostscript a real, seekable
/// file (needed for binary DOS-EPS files that carry a preview header).
///
/// Where Ghostscript comes from is `GhostscriptLocator`'s job.
final class RenderService: NSObject, RenderProtocol {

    /// Finder asks for a whole folder of thumbnails at once, and every render
    /// is a separate unsandboxed Ghostscript process with its own time
    /// budget. Admission is therefore bounded twice: at most
    /// `maxConcurrentRenders` interpreters run together, and a request that
    /// arrives past `maxInFlightRenders` is refused straight away instead of
    /// queueing behind renders that may each take the full timeout.
    private static let maxConcurrentRenders = 3
    private static let maxInFlightRenders = 8

    private static let renderSlots = DispatchSemaphore(value: maxConcurrentRenders)
    private static let inFlightRenders = Atomic(0)
    private static let renderQueue = DispatchQueue(
        label: "com.zhangyanbo.EPSPreview.RenderService.render",
        attributes: .concurrent)

    /// Ghostscript's stderr is drained continuously, but only its head is
    /// retained: enough for the message we report back, bounded so a chatty
    /// file cannot grow the service's memory.
    private static let maxRetainedErrorBytes = 64 * 1024
    private static let maxErrorMessageCharacters = 600

    /// Grace period between SIGTERM and SIGKILL for a render that overran.
    private static let terminationGracePeriod: TimeInterval = 2

    func renderEPSToPDF(epsData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        guard epsData.count <= RenderLimits.maxInputBytes else {
            let limitMB = RenderLimits.maxInputBytes / (1024 * 1024)
            reply(nil, "EPS file exceeds the \(limitMB) MB preview size limit.")
            return
        }

        guard Self.reserveInFlightSlot() else {
            reply(nil, "Too many previews at once. Try again in a moment.")
            return
        }

        // Nothing below may run on the queue NSXPC delivered this message on:
        // it waits for a render slot and then for Ghostscript, and the service
        // has to stay able to accept (and refuse) further requests meanwhile.
        Self.renderQueue.async {
            Self.renderSlots.wait()
            self.render(epsData: epsData) { pdf, error in
                Self.renderSlots.signal()
                Self.releaseInFlightSlot()
                reply(pdf, error)
            }
        }
    }

    private static func reserveInFlightSlot() -> Bool {
        inFlightRenders.withLock { count in
            guard count < maxInFlightRenders else { return false }
            count += 1
            return true
        }
    }

    private static func releaseInFlightSlot() {
        inFlightRenders.withLock { $0 -= 1 }
    }

    // MARK: - Running Ghostscript

    /// Launches Ghostscript and returns immediately; `completion` runs once,
    /// on a background queue, when the child has exited *and* its diagnostics
    /// have been read to EOF.
    private func render(epsData: Data, completion: @escaping (Data?, String?) -> Void) {
        guard let gs = GhostscriptLocator.locate() else {
            completion(nil, "Ghostscript not found. Install it with: brew install ghostscript")
            return
        }

        let stem = UUID().uuidString
        let inputPath = NSTemporaryDirectory() + "eps-in-" + stem + ".eps"
        let outputPath = NSTemporaryDirectory() + "eps-out-" + stem + ".pdf"

        let isFinished = Atomic(false)
        let watchdogBox = Atomic<DispatchWorkItem?>(nil)
        func finish(_ pdf: Data?, _ error: String?) {
            if isFinished.swap(true) { return }
            watchdogBox.swap(nil)?.cancel()
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
            completion(pdf, error)
        }

        do {
            try epsData.write(to: URL(fileURLWithPath: inputPath))
        } catch {
            finish(nil, "Could not stage EPS for rendering: \(error.localizedDescription)")
            return
        }

        let process = Process()
        // Ghostscript runs behind `sh -c 'ulimit …; exec …'` because Process
        // offers no hook for setting a child rlimit, and nothing else caps how
        // much PDF `pdfwrite` may emit. `exec` replaces the shell, so the
        // process we track, signal and reap is still Ghostscript itself.
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.environment = gs.environment
        process.arguments = [
            "-c",
            #"ulimit -f "$1" || { echo "could not limit Ghostscript output size" >&2; exit 71; }; shift; exec "$@""#,
            "gs-output-limit",
            // `ulimit -f` counts blocks whose size differs between shells, so
            // this is a deliberately generous backstop; the exact cap is
            // enforced on the finished file.
            String(RenderLimits.maxOutputBytes / 512),
            gs.executablePath,
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

        let errorPipe = Pipe()
        process.standardError = errorPipe
        // `-sstdout=%stderr` moves everything gs writes — including whatever
        // the PostScript body `print`s — onto the drained pipe above, so
        // nothing is left to consume on fd 1. /dev/null rather than a second
        // Pipe() because an *unread* pipe is what deadlocks a render: the
        // ~64KB kernel buffer fills, gs blocks in write() and never exits.
        process.standardOutput = FileHandle.nullDevice

        // The child exiting and its stderr reaching EOF are independent
        // events, and the reply needs both — whichever lands second builds it.
        // The exited process is passed in rather than captured, so the
        // termination handler does not retain the process that owns it.
        let pendingEvents = Atomic(2)
        let errorOutput = Atomic(Data())
        let didTimeOut = Atomic(false)
        func settle(_ exited: Process) {
            let isLast = pendingEvents.withLock { pending -> Bool in
                pending -= 1
                return pending == 0
            }
            guard isLast else { return }
            let result = Self.result(for: exited,
                                     timedOut: didTimeOut.load(),
                                     errorOutput: errorOutput.load(),
                                     outputPath: outputPath)
            finish(result.pdf, result.error)
        }

        process.terminationHandler = { settle($0) }

        do {
            try process.run()
        } catch {
            finish(nil, "Failed to launch Ghostscript: \(error.localizedDescription)")
            return
        }

        // Drained on its own thread *while* gs runs, so a long diagnostic can
        // never block the child; capped so it cannot grow without bound.
        Self.renderQueue.async {
            let handle = errorPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                errorOutput.withLock { collected in
                    let room = Self.maxRetainedErrorBytes - collected.count
                    if room > 0 { collected.append(chunk.prefix(room)) }
                }
            }
            settle(process)
        }

        let watchdog = DispatchWorkItem {
            guard !isFinished.load() else { return }
            didTimeOut.store(true)
            process.terminate()                       // SIGTERM: let gs clean up
            // A child stuck in an uninterruptible wait ignores SIGTERM, and it
            // holds a render slot until it dies, so escalate.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationGracePeriod) {
                // Re-check right before signalling: once Foundation has reaped
                // the child, its PID may already belong to another process.
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        watchdogBox.store(watchdog)
        DispatchQueue.global().asyncAfter(deadline: .now() + RenderLimits.renderTimeout,
                                          execute: watchdog)
    }

    // MARK: - Interpreting the outcome

    /// Turns an exited Ghostscript into the reply. `timedOut` alone never
    /// decides the outcome: a render that finished on its own in the instant
    /// the watchdog fired still exited normally, and its result is used.
    private static func result(for process: Process,
                               timedOut: Bool,
                               errorOutput: Data,
                               outputPath: String) -> (pdf: Data?, error: String?) {
        let killedBySignal = process.terminationReason == .uncaughtSignal
        let outputLimitMB = RenderLimits.maxOutputBytes / (1024 * 1024)

        if killedBySignal {
            if timedOut {
                return (nil, "Ghostscript timed out after \(Int(RenderLimits.renderTimeout))s "
                    + "and was terminated.")
            }
            if process.terminationStatus == SIGXFSZ {
                return (nil, "The rendered PDF exceeds the \(outputLimitMB) MB preview output limit.")
            }
        }

        guard process.terminationStatus == 0 else {
            return (nil, "Ghostscript exited with status \(process.terminationStatus). "
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
    private static func diagnostic(_ errorOutput: Data) -> String {
        let text = String(data: errorOutput, encoding: .utf8)
            ?? String(data: errorOutput, encoding: .isoLatin1)
            ?? "unknown error"
        return String(text.prefix(maxErrorMessageCharacters))
    }
}
