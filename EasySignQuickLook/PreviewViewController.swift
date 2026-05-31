//
//  PreviewViewController.swift
//  EasySignQuickLook
//

import Cocoa
import Quartz
import WebKit

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let webView = WKWebView()

    override func loadView() {
        webView.navigationDelegate = self
        webView.allowsMagnification = true
        view = webView
        preferredContentSize = NSSize(width: 680, height: 760)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let info = try IPAPreviewService().preview(url: url)
        let html = IPAPreviewHTMLRenderer.html(for: info)
        let title = info.appName.isEmpty ? info.fileName : info.appName

        await MainActor.run {
            self.title = title
            self.preferredContentSize = NSSize(width: 680, height: 760)
            self.webView.loadHTMLString(html, baseURL: nil)
        }
    }
}

extension PreviewViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }
}
