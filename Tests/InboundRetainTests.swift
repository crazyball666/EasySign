import Foundation
import Network

/// 坐实根因:TransferServer 把入站连接经 onConnection 交给 acceptInbound 后,
/// 若只用 [weak conn] 装回调(原状),acceptInbound 一返回就无人强引用 → conn 被释放,
/// 握手完成时 .ready 落到已死 wrapper(stateUpdateHandler 的 [weak self] 为 nil)→ 永不进 app 层。
/// 跨机延迟下握手慢,这个释放窗口必中;本机环回握手极快,侥幸不复现。
///
/// 期望输出:  buggy → conn 已释放(复现 bug)    fixed(强持有)→ conn 仍存活(修复有效)

@main
struct InboundRetainTests {
    static func main() {
        let q = DispatchQueue(label: "retain.test")

        // —— 原状:全 weak,无强持有 ——
        weak var wBuggy: TransferConnection?
        autoreleasepool {
            let nw = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            let conn = TransferConnection(nw, queue: q)
            wBuggy = conn
            buggyAccept(conn)
        }
        Thread.sleep(forTimeInterval: 0.2)   // 等 onStateChange setter 的 queue.async 跑完(它会短暂强持有)
        let buggyReleased = (wBuggy == nil)

        // —— 修复:30s 超时闭包强捕获 conn ——
        weak var wFixed: TransferConnection?
        autoreleasepool {
            let nw = NWConnection(host: "127.0.0.1", port: 9, using: .tcp)
            let conn = TransferConnection(nw, queue: q)
            wFixed = conn
            fixedAccept(conn)
        }
        Thread.sleep(forTimeInterval: 0.2)
        let fixedAlive = (wFixed != nil)

        print("buggy(全 weak):acceptInbound 返回后 conn \(buggyReleased ? "已释放 ✗ —— 复现了根因" : "仍存活")")
        print("fixed(强持有):acceptInbound 返回后 conn \(fixedAlive ? "仍存活 ✓ —— 修复有效" : "已释放")")

        if buggyReleased && fixedAlive { print("ALL PASS") }
        else { FileHandle.standardError.write(Data("FAIL: 引用语义与预期不符\n".utf8)); exit(1) }
    }

    /// 复刻原 acceptInbound:onStateChange + 30s 超时全用 weak,无人强持有 conn。
    static func buggyAccept(_ conn: TransferConnection) {
        conn.onStateChange = { [weak conn] _ in _ = conn }
        let t = DispatchQueue(label: "t.buggy")
        t.asyncAfter(deadline: .now() + 30) { [weak conn] in _ = conn }
    }

    /// 修复:让 30s 超时闭包强捕获 conn,持有到绑定/超时,覆盖握手 + 配对窗口。
    static func fixedAccept(_ conn: TransferConnection) {
        conn.onStateChange = { [weak conn] _ in _ = conn }
        let t = DispatchQueue(label: "t.fixed")
        t.asyncAfter(deadline: .now() + 30) { _ = conn }   // 强捕获
    }
}
