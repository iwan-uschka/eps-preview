import Foundation

/// Counts how many requests are in flight and refuses the ones past a cap.
///
/// Split out of `RenderService` so the reserve/release contract — refuse at
/// the cap, admit again once a slot comes back — can be exercised without
/// launching a Ghostscript per request. The check and the increment happen in
/// one locked step: as two steps, two callers at the cap boundary could both
/// see room and both take the last slot.
final class InFlightLimiter {

    private let limit: Int
    private let count = Atomic(0)

    init(limit: Int) {
        self.limit = limit
    }

    /// Takes a slot, or returns false when `limit` requests are already in
    /// flight. Every true must be paired with exactly one `release()`.
    func reserve() -> Bool {
        count.withLock { inFlight in
            guard inFlight < limit else { return false }
            inFlight += 1
            return true
        }
    }

    /// Hands a reserved slot back.
    func release() {
        count.withLock { $0 -= 1 }
    }

    /// How many slots are currently taken. For tests and diagnostics.
    var inFlight: Int { count.load() }
}
