import Foundation
import os

/// Accepts or refuses each incoming XPC connection to the render service.
///
/// Lives apart from `main.swift` (which has top-level executable statements
/// and so can never be linked into a test target) for the same reason
/// `PeerTrust` does: so `ServiceDelegateTests` can assert that a connection
/// from an untrusted peer is refused and never gets a `RenderService`
/// exported to it.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private static let log = Logger(subsystem: BundleIdentifiers.renderService,
                                    category: "xpc")

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard PeerTrust.isTrustedPeer(pid: newConnection.processIdentifier) else {
            Self.log.error(
                "Rejected XPC connection from untrusted peer pid \(newConnection.processIdentifier, privacy: .public)")
            return false
        }
        // Set before `resume`, and never on the service listener itself —
        // `setConnectionCodeSigningRequirement` asserts on the singleton
        // service listener, so the requirement goes on each connection.
        newConnection.setCodeSigningRequirement(PeerTrust.codeSigningRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: RenderProtocol.self)
        newConnection.exportedObject = RenderService()
        newConnection.resume()
        return true
    }
}
