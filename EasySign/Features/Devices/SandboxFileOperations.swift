//
//  SandboxFileOperations.swift
//  EasySign
//
//  设备文件批处理(下载/上传/复制/移动/删除)的业务逻辑,从 SandboxBrowserView 抽出。
//  View 只负责 UI(进度条 @State、冲突 sheet),通过 SandboxTransferCallbacks 把这些交互
//  以闭包形式注入;这里只跑 AFC 循环。行为与原 View 内联实现逐字一致。
//

import Foundation

/// View 侧交互回调集合。闭包捕获 SwiftUI View(struct),@State 变更经其反射到共享存储,
/// 与原先在 View 里内联 DispatchQueue.global 捕获 self 的值语义一致。
struct SandboxTransferCallbacks {
    /// 按当前 source 建 AFC 客户端(在后台线程调用)。
    let makeClient: () throws -> AFCClient
    /// 开始一次批处理(主线程,带动画)。
    let start: (_ kind: TransferKind, _ name: String, _ index: Int, _ total: Int) -> Void
    /// 更新进度。
    let update: (_ kind: TransferKind, _ name: String, _ index: Int, _ total: Int, _ bytes: UInt64, _ total64: UInt64?) -> Void
    /// 批处理完成(processed==0 时内部会转为取消)。
    let complete: (_ kind: TransferKind, _ processed: Int, _ firstName: String) -> Void
    /// 失败,file 为出错文件名(仅多文件时提供)。
    let fail: (_ error: Error, _ file: String?) -> Void
    /// 用户在冲突提示里选择取消。
    let cancel: () -> Void
    /// 阻塞式冲突解析(后台线程 → 主线程 sheet → 后台线程);remembered 跨整批记住「应用于全部」。
    let resolveConflict: (_ name: String, _ remaining: Int, _ remembered: inout ConflictResolution?) -> ConflictResolution
    /// 完成后刷新当前目录。
    let reload: () -> Void
}

enum SandboxFileOperations {
    /// 下载:无冲突(单文件走保存面板、多文件走目录选择,均由 View 预先决定落地路径)。
    static func download(files: [(FileNode, URL)], callbacks: SandboxTransferCallbacks) {
        guard !files.isEmpty else { return }
        let total = files.count
        callbacks.start(.download, files[0].0.name, 1, total)

        DispatchQueue.global().async {
            var currentName = files[0].0.name
            do {
                let client = try callbacks.makeClient()
                for (i, (node, url)) in files.enumerated() {
                    currentName = node.name
                    let throttle = TransferProgressThrottle()
                    callbacks.update(.download, node.name, i + 1, total, 0, nil)
                    try client.streamFile(at: node.path, to: url) { written, t in
                        guard throttle.shouldFire(written: written, total: t) else { return }
                        callbacks.update(.download, node.name, i + 1, total, written, t)
                    }
                }
                callbacks.complete(.download, files.count, files[0].0.name)
            } catch {
                callbacks.fail(error, total > 1 ? currentName : nil)
            }
        }
    }

    /// 上传:逐文件预检冲突,支持覆盖/跳过/重命名/取消。
    static func upload(localURLs: [URL], destDir: String, callbacks: SandboxTransferCallbacks) {
        guard !localURLs.isEmpty else { return }
        let total = localURLs.count
        let firstName = localURLs[0].lastPathComponent
        callbacks.start(.upload, firstName, 1, total)

        DispatchQueue.global().async {
            var currentName = firstName
            do {
                let client = try callbacks.makeClient()
                var rememberedChoice: ConflictResolution?
                var processed = 0

                for (i, url) in localURLs.enumerated() {
                    let name = url.lastPathComponent
                    currentName = name
                    let initialDest = (destDir as NSString).appendingPathComponent(name)
                    var destPath = initialDest

                    if client.exists(at: initialDest) {
                        let resolution = callbacks.resolveConflict(name, localURLs.count - i - 1, &rememberedChoice)
                        switch resolution {
                        case .cancel:
                            callbacks.cancel()
                            return
                        case .skip:
                            continue
                        case .overwrite:
                            break
                        case .rename:
                            destPath = ConflictRenamer.renamedPath(
                                directory: destDir,
                                originalName: name,
                                existsCheck: { client.exists(at: $0) }
                            )
                        }
                    }

                    let throttle = TransferProgressThrottle()
                    callbacks.update(.upload, name, i + 1, total, 0, nil)
                    try client.uploadFile(localURL: url, to: destPath) { written, t in
                        guard throttle.shouldFire(written: written, total: t) else { return }
                        callbacks.update(.upload, name, i + 1, total, written, t)
                    }
                    processed += 1
                }
                callbacks.complete(.upload, processed, firstName)
                callbacks.reload()
            } catch {
                callbacks.fail(error, total > 1 ? currentName : nil)
            }
        }
    }

    /// 设备内复制/移动的共享循环:逐文件预检冲突,跑 operation,报进度,完成刷新。
    static func runBatch(
        kind: TransferKind,
        nodes: [FileNode],
        destDir: String,
        operation: @escaping (AFCClient, FileNode, String, ((UInt64, UInt64?) -> Void)?) throws -> Void,
        callbacks: SandboxTransferCallbacks
    ) {
        guard !nodes.isEmpty else { return }
        let total = nodes.count
        let firstName = nodes[0].name
        callbacks.start(kind, firstName, 1, total)

        DispatchQueue.global().async {
            var currentName = firstName
            do {
                let client = try callbacks.makeClient()
                var rememberedChoice: ConflictResolution?
                var processed = 0

                for (i, node) in nodes.enumerated() {
                    currentName = node.name
                    let initialDest = (destDir as NSString).appendingPathComponent(node.name)
                    var destPath = initialDest

                    // 同目录同名 = noop(move 不提示,copy 也无害)
                    if initialDest == node.path && kind == .move {
                        continue
                    }

                    if client.exists(at: initialDest) {
                        let resolution = callbacks.resolveConflict(node.name, nodes.count - i - 1, &rememberedChoice)
                        switch resolution {
                        case .cancel:
                            callbacks.cancel()
                            return
                        case .skip:
                            continue
                        case .overwrite:
                            break
                        case .rename:
                            destPath = ConflictRenamer.renamedPath(
                                directory: destDir,
                                originalName: node.name,
                                existsCheck: { client.exists(at: $0) }
                            )
                        }
                    }

                    let throttle = TransferProgressThrottle()
                    callbacks.update(kind, node.name, i + 1, total, 0, nil)

                    let progressClosure: ((UInt64, UInt64?) -> Void)? = (kind == .copy) ? { written, t in
                        guard throttle.shouldFire(written: written, total: t) else { return }
                        callbacks.update(kind, node.name, i + 1, total, written, t)
                    } : nil

                    try operation(client, node, destPath, progressClosure)
                    processed += 1
                }
                callbacks.complete(kind, processed, firstName)
                callbacks.reload()
            } catch {
                callbacks.fail(error, total > 1 ? currentName : nil)
            }
        }
    }

    /// 删除:递归删除(目录先清空再删)。无冲突。
    static func delete(nodes: [FileNode], callbacks: SandboxTransferCallbacks) {
        guard !nodes.isEmpty else { return }
        let total = nodes.count
        let firstName = nodes[0].name
        callbacks.start(.delete, firstName, 1, total)

        DispatchQueue.global().async {
            var currentName = firstName
            do {
                let client = try callbacks.makeClient()
                var processed = 0
                for (i, node) in nodes.enumerated() {
                    currentName = node.name
                    callbacks.update(.delete, node.name, i + 1, total, 0, nil)
                    try client.deleteRecursive(at: node.path, isDirectory: node.isDirectory)
                    processed += 1
                }
                callbacks.complete(.delete, processed, firstName)
                callbacks.reload()
            } catch {
                callbacks.fail(error, total > 1 ? currentName : nil)
            }
        }
    }
}
