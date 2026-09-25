import Foundation
import Security

/// Decides which processes are allowed to drive a render.
///
/// Release builds are ad-hoc signed (no Apple Developer Team ID), so there is
/// no CA chain to anchor against and no shared Team ID to pin, the way a
/// notarized app would. The strongest identity actually enforceable is a
/// two-part check:
///
/// 1. A code-signing requirement pinning the peer's signing identifier to one
///    of the two extensions. `NSXPCConnection.setCodeSigningRequirement`
///    hands the same requirement to XPC, which re-evaluates it per message
///    against the connection's audit token — so it still holds if the peer
///    exits and its PID is recycled, which a PID-keyed lookup would not
///    notice.
/// 2. Containment: the peer's on-disk executable must live inside the same
///    `.app` bundle as this service, so an attacker has to write into the
///    installed bundle (breaking its outer seal) rather than run from
///    anywhere on disk.
///
/// Both rest on the peer binary not being hijackable in-process, which is why
/// every binary in the bundle is signed with the hardened runtime — without
/// it `DYLD_INSERT_LIBRARIES` yields an attacker-controlled process whose
/// signature and identifier still check out (see `scripts/build.sh`).
enum PeerTrust {
    /// Ad-hoc `codesign --sign -` derives the signing identifier from
    /// `CFBundleIdentifier`, so these are the extensions' bundle IDs. The host
    /// app is deliberately absent: it never opens a render connection.
    static let allowedSigningIdentifiers = [
        BundleIdentifiers.quickLookExtension,
        BundleIdentifiers.thumbnailExtension
    ]

    /// Requirement in the code-signing requirement language. Only reachable
    /// through `isTrustedPeer`, which returns false unless it compiles — so
    /// callers handing this to XPC cannot trip its malformed-requirement
    /// exception.
    static let codeSigningRequirement = allowedSigningIdentifiers
        .map { "identifier \"\($0)\"" }
        .joined(separator: " or ")

    private static let compiledRequirement: SecRequirement? = {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(codeSigningRequirement as CFString,
                                             [],
                                             &requirement) == errSecSuccess else {
            return nil
        }
        return requirement
    }()

    static func isTrustedPeer(pid: pid_t) -> Bool {
        guard let ownAppRoot = BundleLayout.enclosingAppBundlePath(for: Bundle.main.bundleURL),
              let requirement = compiledRequirement else {
            return false
        }

        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let peerCode = code else {
            return false
        }
        guard SecCodeCheckValidity(peerCode, [], requirement) == errSecSuccess else {
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
