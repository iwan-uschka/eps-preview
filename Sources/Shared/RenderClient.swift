import Foundation
import os

/// Shared with RenderService (Sources/Shared is compiled into every target,
/// including RenderService) so client and service cannot drift apart.
enum RenderLimits {
    /// Quick Look previews are meant for figures, not multi-hundred-MB print
    /// jobs. Cap input size so a huge or hostile file can't tie up disk/memory
    /// before Ghostscript even runs.
    static let maxInputBytes = 100 * 1024 * 1024

    /// Nothing bounds what `pdfwrite` emits from a valid input, so cap the
    /// rendered PDF too — well below the input limit, since it is read into
    /// memory and handed across XPC.
    static let maxOutputBytes = 64 * 1024 * 1024

    /// Upper bound on how long a single render may run. `-dSAFER` restricts
    /// Ghostscript's file/IO access but not CPU use, so a pathological EPS
    /// (e.g. an infinite loop in its PostScript body) could otherwise hang
    /// the service indefinitely.
    static let renderTimeout: TimeInterval = 20

    /// How the service admits work: at most `maxConcurrentRenders`
    /// Ghostscript processes run together, and a request that arrives past
    /// `maxInFlightRenders` is refused straight away instead of queueing
    /// behind renders that may each take the full timeout. Here rather than in
    /// RenderService because the client's deadline has to be derived from
    /// them — a client that gives up while its request is still queued would
    /// report a timeout for a render the service has not even started.
    static let maxConcurrentRenders = 3
    static let maxInFlightRenders = 8

    /// Worst case, in whole render timeouts, for an *accepted* request: the
    /// queue ahead of it drains `maxConcurrentRenders` at a time, so the last
    /// of `maxInFlightRenders` only starts in the final wave.
    static let worstCaseRenderWaves =
        (maxInFlightRenders + maxConcurrentRenders - 1) / maxConcurrentRenders

    /// The client outwaits the service's whole worst case — queue wait
    /// included — by half a render budget, so the service's specific
    /// `RenderFailure` wins whenever it does arrive, rather than being
    /// flattened into the client's own `.timedOut`. A proportion rather than
    /// a fixed few seconds: the margin has to cover the service's own
    /// SIGTERM→SIGKILL grace *and* marshalling a reply that may be
    /// `maxOutputBytes` large across XPC on a loaded machine — otherwise a
    /// slow transfer turns a successful render into a spurious timeout at the
    /// client.
    static let clientDeadline: TimeInterval =
        renderTimeout * (TimeInterval(worstCaseRenderWaves) + 0.5)
}

/// A finished render.
///
/// `wantsInterpolation` is read from the *source* EPS rather than from the
/// PDF, because Ghostscript drops the `/Interpolate` flag when writing one.
/// It mirrors the source's intent so cellular-automata / pixel figures stay
/// crisp while images that explicitly ask for interpolation are smoothed.
struct RenderOutput {
    let pdf: Data
    let wantsInterpolation: Bool
}

/// Thin client used by both extensions to talk to the embedded
/// RenderService over XPC. A fresh connection is opened per render — Quick
/// Look requests are infrequent, and a per-request connection keeps the
/// lifecycle trivial.
enum RenderClient {

    private static let log = Logger(subsystem: BundleIdentifiers.app,
                                    category: "render-client")

    /// `completion` runs here: serial, off the caller's queue, and never
    /// inline. Callers that touch UI still have to hop to the main queue.
    private static let callbackQueue = DispatchQueue(
        label: BundleIdentifiers.app + ".RenderClient.callback")

    /// Renders `fileURL` to PDF through the embedded render service.
    ///
    /// `completion` is called exactly once and *always* asynchronously on
    /// `callbackQueue`, including for the failures decided here before any
    /// XPC message is sent. Callers therefore never have to guard against it
    /// running re-entrantly inside this call.
    static func render(fileURL: URL,
                       completion: @escaping (Result<RenderOutput, RenderFailure>) -> Void) {
        func fail(_ failure: RenderFailure) {
            callbackQueue.async { completion(.failure(failure)) }
        }

        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        // Reject oversized inputs from the file's metadata, before reading any
        // bytes — otherwise the cap in RenderService only fires after we've
        // already paid the read + scan cost for the whole file.
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > RenderLimits.maxInputBytes {
            fail(.inputTooLarge)
            return
        }

        let interpolate: Bool
        do {
            // Mapped rather than copied, and scoped to this block: the only
            // thing the extension needs the bytes for is the interpolation
            // scan. Ghostscript reads them through the descriptor below.
            let epsData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard !epsData.isEmpty else {
                fail(.inputUnreadable)
                return
            }
            interpolate = wantsInterpolation(epsData)
        } catch {
            log.error("Could not read EPS file: \(error.localizedDescription, privacy: .private)")
            fail(.inputUnreadable)
            return
        }

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: fileURL)
        } catch {
            log.error("Could not open EPS file: \(error.localizedDescription, privacy: .private)")
            fail(.inputUnreadable)
            return
        }

        let connection = NSXPCConnection(serviceName: BundleIdentifiers.renderService)
        connection.remoteObjectInterface = NSXPCInterface(with: RenderProtocol.self)

        let didFinish = Atomic(false)
        let deadlineBox = Atomic<DispatchWorkItem?>(nil)
        func finish(_ result: Result<RenderOutput, RenderFailure>) {
            if didFinish.swap(true) { return }
            deadlineBox.swap(nil)?.cancel()
            connection.invalidate()
            callbackQueue.async { completion(result) }
        }

        // Without these, a service that accepts the connection and then dies
        // or never answers leaves `completion` uncalled forever — the Quick
        // Look panel spins and the connection leaks.
        connection.interruptionHandler = {
            log.error("Render service stopped unexpectedly")
            finish(.failure(.serviceUnavailable))
        }
        connection.invalidationHandler = {
            finish(.failure(.serviceUnavailable))
        }

        let deadline = DispatchWorkItem {
            log.error("Render service did not answer within \(Int(RenderLimits.clientDeadline), privacy: .public)s")
            finish(.failure(.timedOut))
        }
        deadlineBox.store(deadline)
        DispatchQueue.global().asyncAfter(deadline: .now() + RenderLimits.clientDeadline,
                                          execute: deadline)

        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            log.error("Render service connection failed: \(error.localizedDescription, privacy: .public)")
            finish(.failure(.serviceUnavailable))
        } as? RenderProtocol

        guard let proxy else {
            finish(.failure(.serviceUnavailable))
            return
        }

        proxy.renderEPSToPDF(input: input) { pdf, code in
            try? input.close()
            guard let pdf, !pdf.isEmpty else {
                finish(.failure(RenderFailure(xpcCode: code)))
                return
            }
            finish(.success(RenderOutput(pdf: pdf, wantsInterpolation: interpolate)))
        }
    }

    // MARK: - Interpolation intent

    /// Returns true only if the EPS *explicitly* asks for image interpolation
    /// (`Interpolate true` in a PostScript image dictionary).
    ///
    /// PostScript/PDF default for `Interpolate` is **false** (nearest-neighbour),
    /// which is what scientific raster figures (cellular automata, heatmaps,
    /// discrete grids) rely on and what Illustrator honors. So absence of the
    /// token — or `Interpolate false` — means "do not smooth". We only smooth
    /// when the source opted in.
    ///
    /// Scanned as raw bytes rather than as a decoded string: the input is up
    /// to `RenderLimits.maxInputBytes`, and decoding it — twice, to lowercase
    /// it — to answer one boolean was the largest allocation on the preview
    /// path. Bytes also mean a binary DOS-EPS file, whose PostScript body is
    /// ASCII but whose preview section is not, needs no special case.
    ///
    /// The whole buffer is scanned rather than a leading window, because
    /// `/Interpolate` lives in the image dictionary — i.e. wherever in the
    /// page body the raster happens to be drawn — and a wrong answer is
    /// invisible (blurry instead of crisp, never an error). One
    /// allocation-free pass over mapped bytes costs a fraction of the
    /// Ghostscript run it precedes.
    static func wantsInterpolation(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            scanForInterpolateTrue(raw.bindMemory(to: UInt8.self))
        }
    }

    private static let interpolateToken = Array("interpolate".utf8)
    private static let trueToken = Array("true".utf8)

    private static func scanForInterpolateTrue(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "%"):
                index = endOfLine(bytes, from: index)
            case UInt8(ascii: "("):
                index = endOfStringLiteral(bytes, from: index)
            default:
                guard matchesToken(interpolateToken, bytes, at: index) else {
                    index += 1
                    continue
                }
                let value = index + interpolateToken.count
                if matchesToken(trueToken, bytes, at: skippingSeparators(bytes, from: value)) {
                    return true
                }
                index = value
            }
        }
        return false
    }

    /// Matches a whole PostScript token, case-insensitively. The boundary
    /// checks are what keep `/Interpolate` from also matching inside
    /// `/MyInterpolateHack`, and `Interpolatetrue` from reading as a request
    /// to smooth. `| 0x20` lowercases only letters — no other byte maps into
    /// the lowercase-letter range, and every token here is lowercase ASCII.
    private static func matchesToken(_ token: [UInt8],
                                     _ bytes: UnsafeBufferPointer<UInt8>,
                                     at index: Int) -> Bool {
        guard index + token.count <= bytes.count else { return false }
        if index > 0, !isSeparator(bytes[index - 1]) { return false }
        for offset in 0..<token.count where bytes[index + offset] | 0x20 != token[offset] {
            return false
        }
        let after = index + token.count
        return after == bytes.count || isSeparator(bytes[after])
    }

    /// PostScript's own token separators: the six white-space characters plus
    /// the self-delimiting ones (PLRM 3.1).
    private static func isSeparator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
            return true
        case UInt8(ascii: "("), UInt8(ascii: ")"),
             UInt8(ascii: "<"), UInt8(ascii: ">"),
             UInt8(ascii: "["), UInt8(ascii: "]"),
             UInt8(ascii: "{"), UInt8(ascii: "}"),
             UInt8(ascii: "/"), UInt8(ascii: "%"):
            return true
        default:
            return false
        }
    }

    /// White space and comments may both sit between the key and its value,
    /// so `/Interpolate % why not\n true` still counts.
    private static func skippingSeparators(_ bytes: UnsafeBufferPointer<UInt8>,
                                           from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            switch bytes[index] {
            case 0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20:
                index += 1
            case UInt8(ascii: "%"):
                index = endOfLine(bytes, from: index)
            default:
                return index
            }
        }
        return index
    }

    private static func endOfLine(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
            index += 1
        }
        return index
    }

    /// Skips a `(…)` string literal — nestable, with `\` escaping whatever
    /// follows — so a figure that merely *draws* the word "Interpolate true"
    /// as text is not mistaken for one that sets the flag.
    private static func endOfStringLiteral(_ bytes: UnsafeBufferPointer<UInt8>,
                                           from start: Int) -> Int {
        var index = start + 1
        var depth = 1
        while index < bytes.count, depth > 0 {
            switch bytes[index] {
            case UInt8(ascii: "\\"):
                index += 1
            case UInt8(ascii: "("):
                depth += 1
            case UInt8(ascii: ")"):
                depth -= 1
            default:
                break
            }
            index += 1
        }
        return index
    }
}

/// Minimal thread-safe box. Not private: RenderService reuses it for its own
/// one-shot render-watchdog flag instead of hand-rolling a second lock-box.
final class Atomic<Value> {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    /// Sets a new value and returns the previous one.
    func swap(_ newValue: Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
    /// Sets a new value, discarding the previous one.
    func store(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
    /// Reads the current value without changing it.
    func load() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    /// Reads and updates the value in one locked step, for the cases where
    /// `swap` would be a check-then-act race.
    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
