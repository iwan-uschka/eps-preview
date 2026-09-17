import Foundation
import XCTest

final class BundleLayoutTests: XCTestCase {

    func testFindsAppRootFromEmbeddedRenderServiceExecutable() {
        let executable = URL(fileURLWithPath:
            "/Applications/EPSPreview.app/Contents/PlugIns/EPSThumbnail.appex"
            + "/Contents/XPCServices/RenderService.xpc/Contents/MacOS/RenderService")
        XCTAssertEqual(BundleLayout.enclosingAppBundlePath(for: executable),
                       "/Applications/EPSPreview.app")
    }

    func testAppBundleRootIsItsOwnEnclosingBundle() {
        let app = URL(fileURLWithPath: "/Applications/EPSPreview.app")
        XCTAssertEqual(BundleLayout.enclosingAppBundlePath(for: app),
                       "/Applications/EPSPreview.app")
    }

    func testReturnsNilForPathOutsideAnyAppBundle() {
        let executable = URL(fileURLWithPath: "/opt/homebrew/bin/gs")
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: executable))
    }

    func testAppexIsNotMistakenForAnAppBundle() {
        let executable = URL(fileURLWithPath:
            "/tmp/EPSThumbnail.appex/Contents/MacOS/EPSThumbnail")
        XCTAssertNil(BundleLayout.enclosingAppBundlePath(for: executable))
    }
}
