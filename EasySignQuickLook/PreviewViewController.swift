//
//  PreviewViewController.swift
//  EasySignQuickLook
//

import Cocoa
import Quartz
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        preferredContentSize = NSSize(width: 760, height: 820)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let result = try IPAPreviewService().previewFile(url: url)

        await MainActor.run {
            let rootView: AnyView
            switch result {
            case .app(let info):
                title = info.appName.isEmpty ? info.fileName : info.appName
                rootView = AnyView(AppPreviewRootView(info: info))
            case .provisioningProfile(let file):
                title = file.profile.name.isEmpty ? file.fileName : file.profile.name
                rootView = AnyView(ProfilePreviewRootView(file: file))
            }

            let hosting = NSHostingController(rootView: rootView)
            addChild(hosting)
            hosting.view.frame = view.bounds
            hosting.view.autoresizingMask = [.width, .height]
            view.addSubview(hosting.view)
        }
    }
}
