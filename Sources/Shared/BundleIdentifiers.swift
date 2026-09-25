/// Bundle identifiers the app's parts use to find each other at runtime.
///
/// These have to stay in lockstep with `project.yml`'s
/// `PRODUCT_BUNDLE_IDENTIFIER` values and with the identifier literals in
/// `scripts/install.sh` and `scripts/uninstall.sh`, and nothing in the Swift
/// build can see those files — so renaming one side compiles and links cleanly
/// and fails only at runtime, as an unexplained "Render service connection
/// failed". `scripts/check-bundle-identifiers.sh` asserts the sides still agree.
enum BundleIdentifiers {
    static let app = "com.zhangyanbo.EPSPreview"
    static let quickLookExtension = app + ".QuickLook"
    static let thumbnailExtension = app + ".Thumbnail"
    /// Also the XPC service's bundle identifier, which is what
    /// `NSXPCConnection(serviceName:)` looks up in the embedding bundle's XPCServices.
    static let renderService = app + ".RenderService"
}
