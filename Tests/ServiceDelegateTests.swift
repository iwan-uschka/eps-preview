import Foundation
import XCTest

/// `ServiceDelegate`'s refusal half: a connection whose peer `PeerTrust`
/// does not trust is turned away before anything is exported on it. The
/// connection is never resumed, so its `processIdentifier` is 0 — no process
/// that could pass `PeerTrust`'s checks — and no XPC service has to exist.
/// The acceptance half needs a real extension connecting from inside the
/// installed bundle: `PeerTrustTests` covers the trust decision itself, and
/// any preview appearing in MANUAL-TESTING.md's Quick Look steps proves the
/// connection was accepted.
///
/// The refusal is coarse on purpose: it holds for any reason `isTrustedPeer`
/// says no (under XCTest `Bundle.main` is likely not inside an `.app`, so the
/// own-root guard may be what refuses), so this pins the delegate consulting
/// the check, while `PeerTrustTests` pins each reason.
final class ServiceDelegateTests: XCTestCase {

    // breaks-if: ServiceDelegate stops consulting PeerTrust.isTrustedPeer before exporting RenderService.
    func testConnectionFromAnUntrustedPeerIsRefusedAndGetsNothingExported() {
        let connection = NSXPCConnection(serviceName: "com.example.eps-preview-tests.no-such-service")
        defer { connection.invalidate() }
        XCTAssertEqual(connection.processIdentifier, 0)

        let accepted = ServiceDelegate().listener(NSXPCListener.anonymous(),
                                                  shouldAcceptNewConnection: connection)

        XCTAssertFalse(accepted)
        XCTAssertNil(connection.exportedObject, "a refused connection must not be handed a RenderService")
        XCTAssertNil(connection.exportedInterface)
    }
}
