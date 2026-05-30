//
//  PreviewProvider.swift
//  EasySignQuickLook
//

import Cocoa
import Quartz
import UniformTypeIdentifiers

class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let info = try IPAPreviewService().preview(url: request.fileURL)
        let html = IPAPreviewHTMLRenderer.html(for: info)
        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 680, height: 760)) { previewReply in
            previewReply.stringEncoding = .utf8
            return Data(html.utf8)
        }
        reply.title = info.appName.isEmpty ? info.fileName : info.appName
        return reply
    }
}
