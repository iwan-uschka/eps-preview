import Foundation
import Security

/// Decides which processes are allowed to drive a render.
///
/// Extracted out of `main.swift` (which has top-level executable statements
/// and so can never be linked into a test target) so this decision is
/// reachable by `PeerTrustTests`, which spawns a real, separately ad-hoc
/// signed second process and asserts it is refused. Behavior is unchanged
/// from the check this replaces: containment within the same on-disk `.app`
/// bundle as this service. No code-signing-identifier requirement is pinned
/// yet -- that hardening lives on the not-yet-merged
/// `audit-2026-09/xpc-trust-and-hardened-signing` branch.
enum PeerTrust {
    /// Restricts connections to processes that are part of *this same app
    /// bundle* (the host app and its two Quick Look extensions).
    ///
    /// - Parameter ownAppRoot: the enclosing `.app` bundle path a peer must
    ///   also live under to be trusted. Defaults to this process's own
    ///   bundle root; overridable so the check can be exercised against a
    ///   fixture root in tests without the test binary itself needing to run
    ///   from inside a real bundle copy.
    static func isTrustedPeer(pid: pid_t,
                              ownAppRoot: String? = BundleLayout.enclosingAppBundlePath(
                                for: Bundle.main.bundleURL)) -> Bool {
        guard let ownAppRoot else { return false }

        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let peerCode = code else {
            return false
        }
        guard SecCodeCheckValidity(peerCode, [], nil) == errSecSuccess else {
            return false
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(peerCode, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var pathRef: CFURL?
        guard SecCodeCopyPath(staticCode, [], &pathRef) == errSecSuccess,
              let peerPath = pathRef as URL? else {
            return false
        }
        guard let peerAppRoot = BundleLayout.enclosingAppBundlePath(for: peerPath) else {
            return false
        }
        return peerAppRoot == ownAppRoot
    }
}
