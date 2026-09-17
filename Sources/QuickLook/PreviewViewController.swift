import Cocoa
import PDFKit
import Quartz

/// Quick Look preview extension. macOS instantiates this in a sandboxed
/// `com.apple.quicklook.preview` process when the user presses space on an
/// `.eps` / `.ps` file in Finder.
///
/// Rendering is delegated to the embedded (unsandboxed) RenderService, which
/// returns the figure as PDF data. We display it edge-to-edge in a PDFView.
final class PreviewViewController: NSViewController, QLPreviewingController {

    private let pdfView: PDFView = {
        let view = PDFView()
        view.autoScales = true
        view.displayBox = PDFPageGeometry.displayBox
        view.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private let errorLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.maximumNumberOfLines = 0
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        return label
    }()

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.addSubview(pdfView)
        root.addSubview(errorLabel)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: root.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, multiplier: 0.85),
        ])

        view = root
        preferredContentSize = NSSize(width: 1024, height: 768)
    }

    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        RenderClient.render(fileURL: url) { [weak self] data, interpolate, errorMessage in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, let document = PDFDocument(data: data) {
                    // A one-page EPS should fill the panel edge to edge, but a
                    // multi-page PostScript file has to scroll with visible page
                    // breaks — otherwise page 1 looks like the whole file.
                    let isMultiPage = document.pageCount > 1
                    self.pdfView.displayMode = isMultiPage ? .singlePageContinuous : .singlePage
                    self.pdfView.displaysPageBreaks = isMultiPage
                    // Honor the source's interpolation intent: nearest-neighbour
                    // by default (keeps pixel figures crisp), smoothing only when
                    // the EPS explicitly asked for it.
                    self.pdfView.interpolationQuality = interpolate ? .high : .none
                    self.pdfView.document = document
                    self.pdfView.isHidden = false
                    self.errorLabel.isHidden = true
                    handler(nil)
                } else {
                    // The reason (e.g. Ghostscript missing) is surfaced in the
                    // panel itself, and the handler still reports no error: its
                    // error argument tells Quick Look that no preview is
                    // available, which drops this view controller — and the
                    // message we just put in it — for a generic placeholder.
                    self.pdfView.isHidden = true
                    self.errorLabel.stringValue = errorMessage ?? "Could not render this EPS file."
                    self.errorLabel.isHidden = false
                    handler(nil)
                }
            }
        }
    }
}
