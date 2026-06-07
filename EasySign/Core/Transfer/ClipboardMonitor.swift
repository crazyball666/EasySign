import Foundation
import AppKit

/// 轮询剪贴板变化(文本)。回环防护:记住自己写入的内容哈希与 changeCount。
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastHandledHash: String?

    var onLocalText: ((_ text: String, _ hash: String) -> Void)?

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start() {
        stop()
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// 应用入站文本到本地剪贴板;不触发回环。
    func applyIncoming(text: String, hash: String) {
        lastHandledHash = hash
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        let cc = pasteboard.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc
        let types = pasteboard.types?.map { $0.rawValue } ?? []
        if ClipboardCodec.shouldSkip(typeIdentifiers: types) { return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        let hash = ClipboardCodec.hash(text: text)
        if hash == lastHandledHash { return }
        lastHandledHash = hash
        onLocalText?(text, hash)
    }
}
