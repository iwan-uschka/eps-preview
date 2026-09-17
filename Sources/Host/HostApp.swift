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
                Text("已就绪。在访达中选中任意 .eps / .ps 文件，按 **空格键** 即可预览，"
                     + "图标也会显示真实缩略图。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                Text("还差一步：未检测到 Ghostscript。请在终端运行：")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Text("brew install ghostscript")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }

            Text("可以关闭此窗口，预览功能已在后台生效。")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(width: 460, height: 300)
    }
}
