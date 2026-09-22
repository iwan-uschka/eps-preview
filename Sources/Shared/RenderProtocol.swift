import Foundation

/// XPC interface between the (sandboxed) Quick Look / Thumbnail extensions
/// and the (unsandboxed) RenderService.
///
/// IMPORTANT: we pass the EPS file's *bytes*, not its path. The extension is
/// the process that the system grants read access to the previewed file
/// (including files in TCC-protected locations like ~/Downloads, ~/Desktop,
/// ~/Documents). The separate RenderService process has no such grant, so it
/// must never open the original path itself — it writes the bytes we hand it
/// to its own temp file and runs Ghostscript on that.
///
/// DO NOT change this to a path- or URL-based API (e.g. "just pass the
/// file's URL, why copy the bytes"). That is a real security regression, not
/// a cleanup: RenderService has no TCC grant for protected folders, so it
/// would silently fail to open the path — or, if it were ever launched with
/// broader privileges down the line, it would open a file the user only
/// authorized the extension to read. This can't be caught by CI or a
/// same-machine smoke test, because the developer's own machine already has
/// broad TCC grants; it only breaks on an end user's machine. See the
/// README's "How it works" section and
/// https://github.com/iwan-uschka/eps-preview/issues/13.
@objc protocol RenderProtocol {
    func renderEPSToPDF(epsData: Data, withReply reply: @escaping (Data?, String?) -> Void)
}
