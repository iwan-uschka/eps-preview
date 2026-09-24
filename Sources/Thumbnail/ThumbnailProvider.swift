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
                handler(nil, NSError(domain: BundleIdentifiers.app, code: 1,
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

            let layout = ThumbnailGeometry.layout(pageSize: pageSize,
                                         maximumSize: request.maximumSize,
                                         minimumSize: request.minimumSize)
            let pageRect = layout.pageRect

            let scale = request.scale

            handler(QLThumbnailReply(contextSize: layout.contextSize) { context in
                // The block runs after this method returns and PDFPage refers
                // to its document weakly, so the document — not just the page —
                // has to be captured to keep the page drawable.
                guard let page = document.page(at: 0) else { return false }

                // Every bit of the transform chain lives in ThumbnailDrawing,
                // which is where it can be unit-tested against a hand-built
                // bitmap context.
                ThumbnailDrawing.draw(page: page,
                                      pageSize: pageSize,
                                      contextSize: layout.contextSize,
                                      pageRect: pageRect,
                                      scale: scale,
                                      interpolate: interpolate,
                                      into: context)
                return true
            }, nil)
        }
    }
}
