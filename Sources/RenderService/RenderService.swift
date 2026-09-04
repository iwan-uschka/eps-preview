import Foundation
import os

/// Does the actual EPS → PDF conversion by shelling out to Ghostscript.
///
/// Runs inside the *unsandboxed* XPC service. It receives an open descriptor
/// for the EPS (not a path) from the extension and copies it into its own
/// temp file — this keeps it from ever resolving the user's original file
/// location (which it has no TCC grant for), while still giving Ghostscript a
/// real, seekable file (needed for binary DOS-EPS files that carry a preview
/// header).
///
/// Where Ghostscript comes from is `GhostscriptLocator`'s job.
final class RenderService: NSObject, RenderProtocol {

    private static let log = Logger(subsystem: "com.zhangyanbo.EPSPreview.RenderService",
                                    category: "render")

    /// Finder asks for a whole folder of thumbnails at once, and every render
    /// is a separate unsandboxed Ghostscript process with its own time
    /// budget. Admission is therefore bounded twice, by the two limits in
    /// `RenderLimits`: at most `maxConcurrentRenders` interpreters run
    /// together, and a request that arrives past `maxInFlightRenders` is
    /// refused straight away instead of queueing behind renders that may each
    /// take the full timeout. Both live there, not here, because the client's
    /// deadline is computed from them.
    private static let renderSlots = DispatchSemaphore(value: RenderLimits.maxConcurrentRenders)
    private static let admission = InFlightLimiter(limit: RenderLimits.maxInFlightRenders)
    /// Hosts both halves of a render that block: the wait for a `renderSlots`
    /// permit and, once the child is up, its stderr drain. A request is in one
    /// or the other, never both, so the peak cost is `maxInFlightRenders`
    /// worker threads parked in waits rather than doing work — cheap at these
    /// limits, but it scales with `maxInFlightRenders` rather than with
    /// `maxConcurrentRenders`, so raising that far would be the point to
    /// replace the blocking gate with an async-friendly one.
    private static let renderQueue = DispatchQueue(
        label: "com.zhangyanbo.EPSPreview.RenderService.render",
        attributes: .concurrent)

    /// Ghostscript's stderr is drained continuously, but only its head is
    /// retained: enough for the diagnostic we log, bounded so a chatty file
    /// cannot grow the service's memory. None of it crosses XPC — the reply
    /// carries a `RenderFailure` code and nothing the file authored; how much
    /// of that head reaches the log is `RenderOutcome`'s business.
    private static let maxRetainedErrorBytes = 64 * 1024

    /// Grace period between SIGTERM and SIGKILL for a render that overran.
    private static let terminationGracePeriod: TimeInterval = 2

    /// Chunk size for copying the caller's descriptor into our staging file,
    /// so a 100 MB input never becomes a 100 MB allocation here either.
    private static let stagingChunkBytes = 1 << 20

    func renderEPSToPDF(input: FileHandle, withReply reply: @escaping (Data?, NSNumber?) -> Void) {
        func refuse(_ failure: RenderFailure) {
            try? input.close()
            reply(nil, failure.xpcCode)
        }

        // The size is taken from the descriptor rather than from a path or a
        // number the caller passed alongside it: `fstat` cannot disagree with
        // what we are actually about to read.
        guard let size = Self.regularFileSize(of: input), size > 0 else {
            refuse(.inputUnreadable)
            return
        }
        guard size <= RenderLimits.maxInputBytes else {
            refuse(.inputTooLarge)
            return
        }

        guard Self.admission.reserve() else {
            refuse(.busy)
            return
        }

        // Nothing below may run on the queue NSXPC delivered this message on:
        // it waits for a render slot and then for Ghostscript, and the service
        // has to stay able to accept (and refuse) further requests meanwhile.
        Self.renderQueue.async {
            Self.renderSlots.wait()
            self.render(input: input) { pdf, failure in
                Self.renderSlots.signal()
                Self.admission.release()
                reply(pdf, failure?.xpcCode)
            }
        }
    }

    /// `nil` for anything that is not a regular file: a pipe or socket
    /// descriptor has no size to check against the input limit and is not
    /// seekable, which is precisely what a binary DOS-EPS preview header
    /// needs it to be.
    private static func regularFileSize(of handle: FileHandle) -> Int? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            return nil
        }
        return Int(info.st_size)
    }

    // MARK: - Running Ghostscript

    /// Copies the caller's descriptor into our own temp file, in bounded
    /// chunks. Reading starts at offset 0 explicitly: NSXPC handed us a
    /// duplicate of the extension's descriptor, so the two share a file
    /// offset and neither side may assume where the other left it.
    ///
    /// The copy is capped as well as the `fstat` that precedes it, because a
    /// file on a volume someone else controls can grow between the two.
    private static func stage(_ input: FileHandle, atPath path: String) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? output.close() }
        try input.seek(toOffset: 0)
        var copied = 0
        while let chunk = try input.read(upToCount: stagingChunkBytes), !chunk.isEmpty {
            copied += chunk.count
            guard copied <= RenderLimits.maxInputBytes else {
                throw RenderFailure.inputTooLarge
            }
            try output.write(contentsOf: chunk)
        }
    }

    /// Launches Ghostscript and returns immediately; `completion` runs once,
    /// on a background queue, when the child has exited *and* its diagnostics
    /// have been read to EOF.
    private func render(input: FileHandle, completion: @escaping (Data?, RenderFailure?) -> Void) {
        // The descriptor is needed only to stage the bytes; everything past
        // that runs against our own copy, so it can go as soon as we return.
        defer { try? input.close() }

        guard let gs = GhostscriptLocator.locate() else {
            completion(nil, .ghostscriptNotFound)
            return
        }

        let stem = UUID().uuidString
        let inputPath = NSTemporaryDirectory() + "eps-in-" + stem + ".eps"
        let outputPath = NSTemporaryDirectory() + "eps-out-" + stem + ".pdf"

        let isFinished = Atomic(false)
        let watchdogBox = Atomic<DispatchWorkItem?>(nil)
        func finish(_ pdf: Data?, _ failure: RenderFailure?) {
            if isFinished.swap(true) { return }
            watchdogBox.swap(nil)?.cancel()
            try? FileManager.default.removeItem(atPath: inputPath)
            try? FileManager.default.removeItem(atPath: outputPath)
            completion(pdf, failure)
        }

        do {
            try Self.stage(input, atPath: inputPath)
        } catch {
            Self.log.error("Could not stage EPS for rendering: \(error.localizedDescription, privacy: .public)")
            finish(nil, error as? RenderFailure ?? .internalError)
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
            let termination = RenderTermination(
                killedBySignal: exited.terminationReason == .uncaughtSignal,
                status: exited.terminationStatus,
                timedOut: didTimeOut.load())
            let result = RenderOutcome.result(for: termination,
                                              errorOutput: errorOutput.load(),
                                              outputPath: outputPath)
            finish(result.pdf, result.failure)
        }

        process.terminationHandler = { settle($0) }

        do {
            try process.run()
        } catch {
            Self.log.error("Failed to launch Ghostscript: \(error.localizedDescription, privacy: .public)")
            finish(nil, .internalError)
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
            // Both guards are needed: `isFinished` only flips once *both*
            // settle events have landed, so between the child exiting and its
            // stderr reaching EOF it is still false while the PID is already
            // reaped — and may already belong to someone else.
            guard !isFinished.load(), process.isRunning else { return }
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

}
