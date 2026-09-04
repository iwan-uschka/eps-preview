import Foundation
import PDFKit
import QuickLookThumbnailing

/// Finder / Spotlight thumbnail extension. Renders the EPS to PDF (via the
/// embedded RenderService) and draws its first page straight into the context
/// Quick Look hands us.
final class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        RenderClient.render(fileURL: request.fileURL) { data, interpolate, errorMessage in
            func fail(_ message: String) {
                handler(nil, NSError(domain: "com.zhangyanbo.EPSPreview", code: 1,
                                     userInfo: [NSLocalizedDescriptionKey: message]))
            }

            guard let data,
                  let document = PDFDocument(data: data),
                  let firstPage = document.page(at: 0) else {
                fail(errorMessage ?? "Thumbnail render failed")
                return
            }

            let pageSize = PDFPageGeometry.displaySize(of: firstPage)
            guard pageSize.width > 0, pageSize.height > 0 else { fail("Empty page"); return }

            // Fit into the requested maximum, preserving aspect. Quick Look
            // rejects a context smaller than the requested minimum, so a very
            // long or wide page is padded rather than squashed, and it scales
            // the context for the requested device scale itself.
            let maximum = request.maximumSize
            let fit = min(maximum.width / pageSize.width, maximum.height / pageSize.height)
            let fitted = CGSize(width: pageSize.width * fit, height: pageSize.height * fit)
            let contextSize = CGSize(width: max(fitted.width, request.minimumSize.width),
                                     height: max(fitted.height, request.minimumSize.height))
            let pageRect = CGRect(x: (contextSize.width - fitted.width) / 2,
                                  y: (contextSize.height - fitted.height) / 2,
                                  width: fitted.width, height: fitted.height)

            handler(QLThumbnailReply(contextSize: contextSize) { context in
                // The block runs after this method returns and PDFPage refers
                // to its document weakly, so the document — not just the page —
                // has to be captured to keep the page drawable.
                guard let page = document.page(at: 0) else { return false }

                // White page background (documents render on white).
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                context.fill(pageRect)

                // Honor the source's interpolation intent (see RenderClient).
                context.interpolationQuality = interpolate ? .high : .none

                context.translateBy(x: pageRect.origin.x, y: pageRect.origin.y)
                context.scaleBy(x: pageRect.width / pageSize.width,
                                y: pageRect.height / pageSize.height)
                page.draw(with: PDFPageGeometry.displayBox, to: context)
                return true
            }, nil)
        }
    }
}
