import Foundation

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
    /// included — by half a render budget, so the service's specific message
    /// wins whenever it does answer. A proportion rather than a fixed few
    /// seconds: the margin has to cover the service's own SIGTERM→SIGKILL
    /// grace *and* marshalling a reply that may be `maxOutputBytes` large
    /// across XPC on a loaded machine — otherwise a slow transfer turns a
    /// successful render into a generic "did not respond" at the client.
    static let clientDeadline: TimeInterval =
        renderTimeout * (TimeInterval(worstCaseRenderWaves) + 0.5)
}

/// Thin client used by both extensions to talk to the embedded
/// RenderService over XPC. A fresh connection is opened per render — Quick
/// Look requests are infrequent, and a per-request connection keeps the
/// lifecycle trivial.
enum RenderClient {

    /// Result handed back to the extensions.
    /// - `pdf`: the rendered PDF bytes (nil on failure)
    /// - `interpolate`: whether embedded raster images should be drawn with
    ///   smoothing. This mirrors the source's intent (see `wantsInterpolation`)
    ///   so cellular-automata / pixel figures stay crisp while images that
    ///   explicitly ask for interpolation are smoothed.
    /// - `error`: human-readable message on failure
    static func render(fileURL: URL,
                       completion: @escaping (_ pdf: Data?, _ interpolate: Bool, _ error: String?) -> Void) {
        let scoped = fileURL.startAccessingSecurityScopedResource()

        // Reject oversized inputs from the file's metadata, before reading any
        // bytes — otherwise the cap in RenderService only fires after we've
        // already paid the read + scan + XPC cost for the whole file.
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > RenderLimits.maxInputBytes {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            let limitMB = RenderLimits.maxInputBytes / (1024 * 1024)
            completion(nil, false, "EPS file exceeds the \(limitMB) MB preview size limit.")
            return
        }

        let epsData: Data?
        do {
            epsData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            if scoped { fileURL.stopAccessingSecurityScopedResource() }
            completion(nil, false, "Could not read EPS file: \(error.localizedDescription)")
            return
        }
        if scoped { fileURL.stopAccessingSecurityScopedResource() }

        guard let data = epsData, !data.isEmpty else {
            completion(nil, false, "EPS file is empty or unreadable.")
            return
        }

        // Decide interpolation from the *source*, because Ghostscript drops
        // the /Interpolate flag when writing the PDF.
        let interpolate = wantsInterpolation(data)

        let connection = NSXPCConnection(serviceName: BundleIdentifiers.renderService)
        connection.remoteObjectInterface = NSXPCInterface(with: RenderProtocol.self)

        let didFinish = Atomic(false)
        let deadlineBox = Atomic<DispatchWorkItem?>(nil)
        func finish(_ pdf: Data?, _ error: String?) {
            if didFinish.swap(true) { return }
            deadlineBox.swap(nil)?.cancel()
            completion(pdf, interpolate, error)
            connection.invalidate()
        }

        // Without these, a service that accepts the connection and then dies
        // or never answers leaves `completion` uncalled forever — the Quick
        // Look panel spins and the connection leaks.
        connection.interruptionHandler = {
            finish(nil, "The render service stopped unexpectedly.")
        }
        connection.invalidationHandler = {
            finish(nil, "The render service is unavailable.")
        }

        let deadline = DispatchWorkItem {
            finish(nil, "The render service did not respond within "
                + "\(Int(RenderLimits.clientDeadline))s.")
        }
        deadlineBox.store(deadline)
        DispatchQueue.global().asyncAfter(deadline: .now() + RenderLimits.clientDeadline,
                                          execute: deadline)

        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
            finish(nil, "Render service connection failed: \(error.localizedDescription)")
        } as? RenderProtocol

        guard let proxy else {
            finish(nil, "Could not reach the render service.")
            return
        }

        proxy.renderEPSToPDF(epsData: data) { pdf, error in
            finish(pdf, error)
        }
    }

    /// Returns true only if the EPS *explicitly* asks for image interpolation
    /// (`Interpolate true` in the PostScript image dictionary).
    ///
    /// PostScript/PDF default for `Interpolate` is **false** (nearest-neighbour),
    /// which is what scientific raster figures (cellular automata, heatmaps,
    /// discrete grids) rely on and what Illustrator honors. So absence of the
    /// token — or `Interpolate false` — means "do not smooth". We only smooth
    /// when the source opted in.
    ///
    /// The scan is byte-based (Latin-1 maps every byte 1:1, never fails), so it
    /// works on binary DOS-EPS files whose PostScript body is still ASCII.
    static func wantsInterpolation(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .isoLatin1)?.lowercased() else {
            return false
        }
        var searchStart = text.startIndex
        while let range = text.range(of: "interpolate", range: searchStart..<text.endIndex) {
            let rest = text[range.upperBound...].drop {
                $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r"
            }
            if rest.hasPrefix("true") { return true }
            searchStart = range.upperBound
        }
        return false
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
