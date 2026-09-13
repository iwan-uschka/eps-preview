import Foundation
import XCTest

/// The limits are plain constants, but the *relations* between them are what
/// the two sides of the XPC boundary rely on — and nothing else would fail if
/// one of them were edited out of order.
final class RenderLimitsTests: XCTestCase {

    func testTheClientOutwaitsTheServicesOwnBudget() {
        XCTAssertGreaterThan(RenderLimits.clientDeadline, RenderLimits.renderTimeout,
                             "the service's specific error must arrive before the client gives up")
    }

    func testTheClientsMarginCoversTheKillGraceAndAReplyTransfer() {
        // The service may spend its full worst case — the queue ahead of the
        // request plus its own render — then up to a couple of seconds
        // escalating SIGTERM→SIGKILL, before it can answer at all.
        XCTAssertGreaterThanOrEqual(RenderLimits.clientDeadline - worstCaseServiceBudget, 5,
                                    "too tight a margin turns a slow reply into a spurious timeout")
    }

    func testTheClientOutwaitsARequestThatQueuesBehindAFullAdmissionWindow() {
        // The service admits more requests than it runs at once, so an
        // accepted request can wait several whole render timeouts before its
        // own Ghostscript even starts. A deadline derived from one render
        // alone would report "did not respond" for a render still queued —
        // and invalidate the connection while the service holds its slot.
        XCTAssertGreaterThan(RenderLimits.clientDeadline, worstCaseServiceBudget)
    }

    func testTheQueueDepthAccountsForEveryAdmittedRequest() {
        // worstCaseRenderWaves is integer ceil(inFlight / concurrent); if it
        // rounded down, the last admitted requests would not be covered.
        XCTAssertGreaterThanOrEqual(
            RenderLimits.worstCaseRenderWaves * RenderLimits.maxConcurrentRenders,
            RenderLimits.maxInFlightRenders,
            "the waves the deadline budgets for must cover the whole admission window")
    }

    func testTheRenderedPDFLimitStaysBelowTheInputLimit() {
        // The output is read into memory and handed across XPC; the input is
        // only streamed to a temp file.
        XCTAssertLessThan(RenderLimits.maxOutputBytes, RenderLimits.maxInputBytes)
    }

    /// Longest a request the service *accepted* may legitimately take:
    /// `worstCaseRenderWaves` renders of `renderTimeout` each.
    private var worstCaseServiceBudget: TimeInterval {
        RenderLimits.renderTimeout * TimeInterval(RenderLimits.worstCaseRenderWaves)
    }
}
