/// Bundle identifiers the app's parts use to find each other at runtime.
///
/// These have to stay in lockstep with `project.yml`'s
/// `PRODUCT_BUNDLE_IDENTIFIER` values, and nothing in the Swift build can see
/// that file — so renaming one side compiles and links cleanly and fails only
/// at runtime, as an unexplained "Render service connection failed".
/// `scripts/check-bundle-identifiers.sh` asserts the two sides still agree.
enum BundleIdentifiers {
    static let app = "com.zhangyanbo.EPSPreview"
    static let quickLookExtension = app + ".QuickLook"
    static let thumbnailExtension = app + ".Thumbnail"
    /// Doubles as the mach service name `NSXPCConnection(serviceName:)` resolves.
    static let renderService = app + ".RenderService"
}
