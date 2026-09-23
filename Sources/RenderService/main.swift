import Foundation
import os

/// XPC service entry point. `NSXPCListener.service()` runs the service event
/// loop and never returns.
final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private static let log = Logger(subsystem: "com.zhangyanbo.EPSPreview.RenderService",
                                     category: "xpc")

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard PeerTrust.isTrustedPeer(pid: newConnection.processIdentifier) else {
            Self.log.error("Rejected XPC connection from untrusted peer pid \(newConnection.processIdentifier, privacy: .public)")
            return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: RenderProtocol.self)
        newConnection.exportedObject = RenderService()
        newConnection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
