import Foundation

/// Shared helper for locating the enclosing `.app` bundle from a path inside it
/// (an XPC service or extension's own bundle, or a resolved peer executable).
enum BundleLayout {
    /// Walks up from `url` to the nearest enclosing `.app` bundle root.
    ///
    /// Symlinks are resolved first so that two spellings of the same bundle
    /// (a firmlink or symlinked path vs. the real one) yield the same string —
    /// callers compare the result of two separate walks for equality. Anything
    /// that is not an absolute file path is rejected outright: the walk has no
    /// root to terminate at, and the bound below would silently return nil
    /// instead of the intended answer.
    static func enclosingAppBundlePath(for url: URL) -> String? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        var current = url.resolvingSymlinksInPath()
        for _ in 0..<current.pathComponents.count {
            if current.pathExtension == "app" { return current.path }
            current.deleteLastPathComponent()
        }
        return nil
    }
}
