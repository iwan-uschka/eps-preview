import Foundation

/// XPC interface between the (sandboxed) Quick Look / Thumbnail extensions
/// and the (unsandboxed) RenderService.
///
/// IMPORTANT: we pass an open, read-only *descriptor* for the EPS file, not
/// its path. The extension is the process that the system grants read access
/// to the previewed file (including files in TCC-protected locations like
/// ~/Downloads, ~/Desktop, ~/Documents). The separate RenderService process
/// has no such grant, so it must never resolve the original path itself — it
/// copies what it can read through the descriptor into its own temp file and
/// runs Ghostscript on that.
///
/// NSXPC transfers a `FileHandle` by duplicating the underlying descriptor
/// into the receiving process, which keeps that property while avoiding the
/// full-size message copy that sending the bytes as `Data` cost on every
/// render.
///
/// DO NOT change this to a path- or URL-based API (e.g. "just pass the
/// file's URL, why duplicate a descriptor"). That is a real security
/// regression, not a cleanup: RenderService has no TCC grant for protected
/// folders, so it would silently fail to open the path — or, if it were ever
/// launched with broader privileges down the line, it would open a file the
/// user only authorized the extension to read. This can't be caught by CI or
/// a same-machine smoke test, because the developer's own machine already has
/// broad TCC grants; it only breaks on an end user's machine. See the
/// README's "How it works" section and
/// https://github.com/iwan-uschka/eps-preview/issues/13.
@objc protocol RenderProtocol {
    func renderEPSToPDF(input: FileHandle, withReply reply: @escaping (Data?, NSNumber?) -> Void)
}

/// Why a render failed, in the categories a caller can act on differently:
/// a missing Ghostscript is the user's to fix, a malformed file is nobody's,
/// a timeout or a busy service is worth retrying.
///
/// Crosses XPC as its raw value rather than as an object: NSXPC only carries
/// `NSSecureCoding` types, and an integer code needs no coder, no class
/// allow-listing, and no pre-formatted English sentence on the wire. Display
/// text is authored here, in `message`, so that nothing a caller draws in a
/// system-provided panel can originate in the file being rendered.
enum RenderFailure: Int, Error {
    /// No usable interpreter: absent, or rejected by `GhostscriptLocator` as
    /// too old or not exclusively owner-writable. One case, because the
    /// locator reports only whether it found one.
    case ghostscriptNotFound = 1
    case inputTooLarge = 2
    case inputUnreadable = 3
    /// Ghostscript rejected the file, or made nothing out of it.
    case malformedInput = 4
    case timedOut = 5
    case outputTooLarge = 6
    case serviceUnavailable = 7
    /// Admission refused because too many renders are already in flight.
    case busy = 8
    case internalError = 9

    var message: String {
        switch self {
        case .ghostscriptNotFound:
            return "Ghostscript not found. Install it with: brew install ghostscript"
        case .inputTooLarge:
            return "This EPS file is larger than the "
                + "\(RenderLimits.maxInputBytes / (1024 * 1024)) MB preview limit."
        case .inputUnreadable:
            return "This EPS file could not be read."
        case .malformedInput:
            return "Ghostscript could not render this EPS file."
        case .timedOut:
            return "Rendering this EPS file took longer than "
                + "\(Int(RenderLimits.renderTimeout))s and was stopped."
        case .outputTooLarge:
            return "The rendered preview is larger than the "
                + "\(RenderLimits.maxOutputBytes / (1024 * 1024)) MB output limit."
        case .serviceUnavailable:
            return "The render service is unavailable."
        case .busy:
            return "Too many previews at once. Try again in a moment."
        case .internalError:
            return "Could not render this EPS file."
        }
    }
}

extension RenderFailure {
    init(xpcCode: NSNumber?) {
        self = (xpcCode?.intValue).flatMap(RenderFailure.init(rawValue:)) ?? .internalError
    }

    var xpcCode: NSNumber { NSNumber(value: rawValue) }

    /// For the callbacks that hand macOS an `Error` and nothing else
    /// (QuickLookThumbnailing): distinct codes in one domain, so the category
    /// survives even where only an `NSError` fits.
    var nsError: NSError {
        NSError(domain: BundleIdentifiers.app,
                code: rawValue,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
