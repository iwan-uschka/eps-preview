import Foundation
import os
import PDFKit
import QuickLookThumbnailing

/// Finder / Spotlight thumbnail extension. Renders the EPS to PDF (via the
/// embedded RenderService) and draws its first page straight into the context
/// Quick Look hands us.
final class ThumbnailProvider: QLThumbnailProvider {

    private static let log = Logger(subsystem: BundleIdentifiers.app,
                                    category: "thumbnail")

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        RenderClient.render(fileURL: request.fileURL) { result in
            func fail(_ failure: RenderFailure, _ reason: String) {
                Self.log.error("Thumbnail failed: \(reason, privacy: .public)")
                handler(nil, failure.nsError)
            }

            let output: RenderOutput
            switch result {
            case .success(let value):
                output = value
            case .failure(let failure):
                handler(nil, failure.nsError)
                return
            }

            guard let document = PDFDocument(data: output.pdf),
                  let firstPage = document.page(at: 0) else {
                fail(.malformedInput, "rendered PDF has no usable first page")
                return
            }

            let pageSize = PDFPageGeometry.displaySize(of: firstPage)
            guard pageSize.width > 0, pageSize.height > 0 else {
                fail(.malformedInput, "first page has an empty display box")
                return
            }

            let layout = ThumbnailGeometry.layout(pageSize: pageSize,
                                         maximumSize: request.maximumSize,
                                         minimumSize: request.minimumSize)
            let pageRect = layout.pageRect

            let scale = request.scale
            let interpolate = output.wantsInterpolation

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
