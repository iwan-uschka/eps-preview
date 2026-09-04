import Foundation
import XCTest

/// `RenderFailure`'s raw value is a wire format: it is what actually crosses
/// XPC, in place of the pre-formatted English string the reply used to carry.
/// These tests pin the round trip and the decoding of anything unexpected,
/// because a mismatch here is silent — the caller just shows the wrong reason.
final class RenderFailureTests: XCTestCase {

    private static let allCases: [RenderFailure] = [
        .ghostscriptNotFound, .inputTooLarge, .inputUnreadable, .malformedInput,
        .timedOut, .outputTooLarge, .serviceUnavailable, .busy, .internalError,
    ]

    func testEveryCaseSurvivesTheRoundTripThroughItsXPCCode() {
        for failure in Self.allCases {
            XCTAssertEqual(RenderFailure(xpcCode: failure.xpcCode), failure,
                           "\(failure) did not survive the round trip")
        }
    }

    func testTheRawValuesAreTheOnesBothSidesAgreedOn() {
        // Pinned rather than derived: the service and the extensions are
        // separate binaries, and a renumbering that only one of them ships
        // would turn "Ghostscript not found" into "too large" with no error.
        XCTAssertEqual(Self.allCases.map(\.rawValue), [1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    func testAMissingCodeDecodesAsAnInternalError() {
        // A reply with no PDF *and* no code is a service that answered wrong;
        // the caller still has to show something.
        XCTAssertEqual(RenderFailure(xpcCode: nil), .internalError)
    }

    func testAnUnknownCodeDecodesAsAnInternalError() {
        // A newer service reporting a case this build has never heard of.
        XCTAssertEqual(RenderFailure(xpcCode: NSNumber(value: 9999)), .internalError)
    }

    func testEveryCaseHasItsOwnDisplayText() {
        let messages = Set(Self.allCases.map(\.message))
        XCTAssertEqual(messages.count, Self.allCases.count,
                       "two categories sharing one sentence make them indistinguishable to the user")
        for failure in Self.allCases {
            XCTAssertFalse(failure.message.isEmpty, "\(failure) has no display text")
        }
    }

    func testTheNSErrorKeepsTheCategoryAndTheText() {
        // QuickLookThumbnailing's callback takes an `Error` and nothing else,
        // so the category has to survive as the NSError's code.
        for failure in Self.allCases {
            let error = failure.nsError
            XCTAssertEqual(error.code, failure.rawValue)
            XCTAssertEqual(error.domain, "com.zhangyanbo.EPSPreview")
            XCTAssertEqual(error.localizedDescription, failure.message)
        }
    }

    func testTheSizeLimitsAreNamedInTheTextTheUserSees() {
        // The numbers come from RenderLimits, so raising a limit must not
        // leave a stale figure on screen.
        XCTAssertTrue(RenderFailure.inputTooLarge.message
            .contains("\(RenderLimits.maxInputBytes / (1024 * 1024)) MB"))
        XCTAssertTrue(RenderFailure.outputTooLarge.message
            .contains("\(RenderLimits.maxOutputBytes / (1024 * 1024)) MB"))
    }
}
