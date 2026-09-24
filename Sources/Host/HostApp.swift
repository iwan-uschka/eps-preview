import SwiftUI

@main
struct EPSPreviewApp: App {
    var body: some Scene {
        Window("EPS Preview", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    /// Asks the same locator the render service runs, rather than keeping a
    /// second copy of the candidate list here: this window is the only place a
    /// user is told whether previews will work.
    ///
    /// `isLikelyInstalled()` and not `locate()`, because this app is sandboxed:
    /// the sandbox denies both the `access(X_OK)` probe behind
    /// `isExecutableFile(atPath:)` and the `gs --version` exec that `locate()`
    /// needs, so `locate()` would report a working Homebrew install as missing.
    /// See that method's note for what the sandbox does and does not allow, and
    /// for why under-reporting was judged worse than over-reporting here.
    private var ghostscriptInstalled: Bool {
        GhostscriptLocator.isLikelyInstalled()
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: ghostscriptInstalled ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 52))
                .foregroundStyle(ghostscriptInstalled ? .green : .orange)

            Text("EPS Preview")
                .font(.title).bold()

            if ghostscriptInstalled {
                Text("Ready to go. Select any .eps / .ps file in Finder and press **Space** "
                     + "to preview it — icons will show the real thumbnail too.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("One more step: Ghostscript wasn't found. Run this in Terminal:")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("brew install ghostscript")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Text("You can close this window — previews already work in the background.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(width: 460, height: 300)
    }
}
