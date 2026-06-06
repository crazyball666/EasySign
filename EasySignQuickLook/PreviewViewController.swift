//
//  PreviewViewController.swift
//  EasySignQuickLook
//

import Cocoa
import Quartz
import WebKit

final class PreviewViewController: NSViewController, QLPreviewingController {
    private var webView: WKWebView!

    override func loadView() {
        // 单个铺满的 WKWebView。用 autoresizingMask 跟随 QLPreviewPanel 尺寸，
        // 不用任何 Auto Layout 约束 —— 彻底避免之前 NSStackView 约束冲突。
        // HTML/CSS 负责所有排版、换行、滚动，响应式自适应面板宽度。
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 880))
        root.autoresizingMask = [.width, .height]

        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: root.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")  // 透明背景，跟随系统
        root.addSubview(webView)

        view = root
        preferredContentSize = NSSize(width: 820, height: 880)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let info = try IPAPreviewService().preview(url: url)
        let html = IPAPreviewHTMLRenderer.html(for: info)
        let title = info.appName.isEmpty ? info.fileName : info.appName

        await MainActor.run {
            self.title = title
            self.webView.loadHTMLString(html, baseURL: nil)
        }
    }
}
