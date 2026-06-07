import Foundation

/// 把文件/图片字节以二进制 WS 帧分块发送/接收(走已配对连接)。
final class FileTransferManager {
    struct Progress: Identifiable, Equatable {
        let id: String
        let name: String
        let direction: TransferDirection
        var bytes: Int
        let total: Int
    }
    static let chunkSize = 64 * 1024

    var onProgress: ((Progress) -> Void)?
    /// 收齐一个文件后回调(localURL 落在 inbox)。isImage 时 name 由调用方处理。
    var onReceived: ((_ id: String, _ name: String, _ url: URL, _ isImage: Bool) -> Void)?

    private let ioQueue = DispatchQueue(label: "transfer.file.io")
    private let sendQueue = DispatchQueue(label: "transfer.file.send")

    // —— 接收状态(单活跃)——
    private var recvId: String?
    private var recvName: String?
    private var recvIsImage = false
    private var recvTotal = 0
    private var recvBytes = 0
    private var recvLastEmit = 0
    private var recvHandle: FileHandle?
    private var recvURL: URL?

    // 控制帧入口(由 TransferService 把 .fileOffer/.fileComplete/.clipboardImageOffer 转进来)
    func handleOffer(id: String, name: String, size: Int, isImage: Bool) {
        ioQueue.async {
            self.finishRecvCleanup()
            let url = TransferPaths.uniqueInboxURL(for: name.isEmpty ? "\(isImage ? "image.png" : "file")" : name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.recvHandle = try? FileHandle(forWritingTo: url)
            if self.recvHandle == nil {
                self.finishRecvCleanup()
                return
            }
            self.recvId = id; self.recvName = name; self.recvIsImage = isImage
            self.recvTotal = size; self.recvBytes = 0; self.recvLastEmit = 0; self.recvURL = url
        }
    }
    func handleBinary(_ data: Data) {
        ioQueue.async {
            guard let h = self.recvHandle else { return }
            h.write(data)
            self.recvBytes += data.count
            // 每块都落盘,但进度回调按 ~512KB 或收齐时节流,避免高频刷 UI。
            let done = self.recvTotal > 0 && self.recvBytes >= self.recvTotal
            if self.recvBytes - self.recvLastEmit >= 512 * 1024 || done {
                self.recvLastEmit = self.recvBytes
                if let id = self.recvId, let name = self.recvName {
                    let p = Progress(id: id, name: name, direction: .incoming, bytes: self.recvBytes, total: self.recvTotal)
                    self.onProgress?(p)
                }
            }
        }
    }
    func handleComplete(id: String) {
        ioQueue.async {
            guard self.recvId == id, let url = self.recvURL, let name = self.recvName else { return }
            try? self.recvHandle?.close()
            let isImage = self.recvIsImage
            self.recvHandle = nil; self.recvId = nil; self.recvURL = nil
            self.onReceived?(id, name, url, isImage)
        }
    }
    private func finishRecvCleanup() {
        try? recvHandle?.close()
        recvHandle = nil; recvId = nil; recvURL = nil
        recvName = nil; recvIsImage = false
        recvBytes = 0; recvTotal = 0; recvLastEmit = 0
    }

    /// 连接断开时调用:关闭半截接收、删除残留分块文件、清空接收状态。
    func reset() {
        ioQueue.async {
            try? self.recvHandle?.close()
            if let url = self.recvURL { try? FileManager.default.removeItem(at: url) }
            self.recvHandle = nil; self.recvId = nil; self.recvURL = nil
            self.recvName = nil; self.recvIsImage = false
            self.recvBytes = 0; self.recvTotal = 0; self.recvLastEmit = 0
        }
    }

    // —— 发送 ——
    /// 发送一个文件。`offer` 闭包负责发 .fileOffer/.clipboardImageOffer 控制帧;
    /// `sendBinary` 发二进制块;`complete` 发 .fileComplete。
    func send(id: String, name: String, fileURL: URL, isImage: Bool,
              offer: @escaping (_ id: String, _ name: String, _ size: Int) -> Void,
              sendBinary: @escaping (_ data: Data, _ done: @escaping () -> Void) -> Void,
              complete: @escaping (_ id: String) -> Void,
              done: @escaping () -> Void) {
        sendQueue.async {
            let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let size = (attrs?[.size] as? Int) ?? 0
            offer(id, name, size)
            guard let handle = try? FileHandle(forReadingFrom: fileURL) else { done(); return }
            let sem = DispatchSemaphore(value: 0)
            var sent = 0
            var lastEmit = 0
            while true {
                let chunk = handle.readData(ofLength: Self.chunkSize)
                if chunk.isEmpty { break }
                sendBinary(chunk) { sem.signal() }
                sem.wait()                 // 背压:等本块被 socket 接收后再读下一块
                sent += chunk.count
                if sent - lastEmit >= 512 * 1024 || sent >= size {   // 进度节流
                    lastEmit = sent
                    self.onProgress?(Progress(id: id, name: name, direction: .outgoing, bytes: sent, total: size))
                }
            }
            try? handle.close()
            complete(id)
            done()
        }
    }
}
