import Cocoa
import QuickLookUI

/// Quick Look preview extension: Space in Finder on a splat / point cloud.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var splatView: SplatWebView?

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let webDir = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("web")
        let v = SplatWebView(webDir: webDir)
        splatView = v
        view = v
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        preferredContentSize = NSSize(width: 1200, height: 800)
        _ = view   // make sure loadView ran
        guard let v = splatView else {
            handler(nil)
            return
        }
        v.open(url)

        // Tell Quick Look we're ready once the viewer page is up (the page shows its own progress bar).
        var called = false
        let finish: () -> Void = {
            if called { return }
            called = true
            handler(nil)
        }
        if v.isPageLoaded {
            finish()
        } else {
            v.onPageLoaded = { [weak v] in
                v?.onPageLoaded = nil
                finish()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { finish() }
        }
    }
}
