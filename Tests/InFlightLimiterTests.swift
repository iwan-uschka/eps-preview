import Foundation
import XCTest

/// Covers the admission bookkeeping the render service refuses requests with:
/// a slot is handed out until the cap is reached, and a released slot becomes
/// available again. A leak here would starve the service silently rather than
/// crash, so the pairing is asserted explicitly.
final class InFlightLimiterTests: XCTestCase {

    func testRequestsPastTheCapAreRefused() {
        let limiter = InFlightLimiter(limit: 3)

        XCTAssertTrue(limiter.reserve())
        XCTAssertTrue(limiter.reserve())
        XCTAssertTrue(limiter.reserve())
        XCTAssertEqual(limiter.inFlight, 3)

        XCTAssertFalse(limiter.reserve(), "the cap must refuse rather than queue")
        XCTAssertFalse(limiter.reserve())
        XCTAssertEqual(limiter.inFlight, 3, "a refused request must not take a slot")
    }

    func testAReleasedSlotIsHandedOutAgain() {
        let limiter = InFlightLimiter(limit: 2)

        XCTAssertTrue(limiter.reserve())
        XCTAssertTrue(limiter.reserve())
        XCTAssertFalse(limiter.reserve())

        limiter.release()
        XCTAssertEqual(limiter.inFlight, 1)
        XCTAssertTrue(limiter.reserve(), "a finished render must free its slot")
        XCTAssertFalse(limiter.reserve())
    }

    func testEveryReservationReleasedLeavesNothingInFlight() {
        let limiter = InFlightLimiter(limit: 4)

        for _ in 0..<4 { XCTAssertTrue(limiter.reserve()) }
        for _ in 0..<4 { limiter.release() }

        XCTAssertEqual(limiter.inFlight, 0)
        XCTAssertTrue(limiter.reserve(), "the limiter must recover completely")
    }

    func testConcurrentCallersAdmitExactlyTheCap() {
        let limit = 8
        let limiter = InFlightLimiter(limit: limit)
        let admitted = Atomic(0)

        // Far more callers than slots, all racing the check-then-act the
        // limiter has to keep atomic — a Finder folder fan-out in miniature.
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if limiter.reserve() { admitted.withLock { $0 += 1 } }
        }

        XCTAssertEqual(admitted.load(), limit, "the cap must hold under concurrent admission")
        XCTAssertEqual(limiter.inFlight, limit)
    }
}
