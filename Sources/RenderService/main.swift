import Foundation

/// XPC service entry point. `NSXPCListener.service()` runs the service event
/// loop and never returns. Which connections are accepted is
/// `ServiceDelegate`'s decision, kept out of this file so it can be tested.
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
