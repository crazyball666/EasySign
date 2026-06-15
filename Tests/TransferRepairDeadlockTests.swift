import Foundation

/// 坐实并防回归:互传「一端在配对、另一端已绑定」的角色错位死锁。
///
/// 死锁场景:两台已配对设备重连时,认得对端证书指纹的一方直接 bindConnected 绑成 `.connected`,
/// 其数据流处理器把对端发来的 hello / pairOffer / pairProof 丢进 `default` → 发起配对方一句应答都收不到,
/// 12s 后报「配对超时」。详见 TransferService.bindConnected 与 BoundInboundRouter。
///
/// 本测试不依赖 Network.framework / TLS / SecIdentity SPI:用一个内存 FIFO(`MemLink`)把两端的
/// `send` 解耦成「逐条投递」,忠实模拟真实连接「一次处理一条消息」的语义(避免 send 直接递归 handle
/// 造成乱序),即可在纯逻辑层复现死锁并验证修复。
///
///   负向对照:已绑定方照搬原 bindConnected 的数据流 switch(丢弃配对帧)→ 发起方拿不到 `.success`(死锁)。
///   正向    :已绑定方改用真正的 `BoundInboundRouter` 应答 → 双方都 `.success`,且配对握手帧不漏进数据通道。
///
/// 期望输出:全部断言通过则 `ALL PASS`;否则 `FAIL: ...` 到 stderr 并 exit(1)。

/// 内存传输:把两端的 send 解耦成 FIFO,逐条投递,模拟真实连接「一次处理一条消息」的语义。
/// 0 = A(发起方),1 = B(已绑定方)。
final class MemLink {
    private var queue: [(to: Int, msg: WireMessage)] = []
    var handlers: [Int: (WireMessage) -> Void] = [:]
    func send(to: Int, _ msg: WireMessage) { queue.append((to, msg)) }
    /// 排空队列:逐条交付,每条 handle 完整跑完后再取下一条(交付过程中新产生的消息追加到队尾)。
    func pump() {
        while !queue.isEmpty {
            let (to, msg) = queue.removeFirst()
            handlers[to]?(msg)
        }
    }
}

@main
struct TransferRepairDeadlockTests {
    // 两个稳定的假指纹(真实指纹为 64 hex;MAC 只关心字符串一致与排序,无需真证书)。
    static let fpA = String(repeating: "a", count: 64)
    static let fpB = String(repeating: "b", count: 64)
    static let code = "123456"

    static func main() {
        negativeControl_buggyBoundSinkDeadlocks()
        positive_routerCompletesRepair()
        print("ALL PASS")
    }

    /// 发起方 A:对应 TransferService.outboundReady → startPairing(用户带码主动连)。
    static func makeInitiator(link: MemLink, outcome: @escaping (PairingManager.Outcome) -> Void) -> PairingManager {
        let pm = PairingManager(code: code, selfFingerprint: fpA, selfDeviceId: "device-A",
                                selfName: "DeviceA", peerFingerprint: fpB)
        pm.send = { link.send(to: 1, $0) }   // A → B
        pm.onOutcome = outcome
        return pm
    }

    // MARK: - 负向对照:旧的已绑定数据流 switch 丢弃配对帧 → 发起方死锁

    static func negativeControl_buggyBoundSinkDeadlocks() {
        let link = MemLink()
        var aOutcome: PairingManager.Outcome?
        let initiator = makeInitiator(link: link) { aOutcome = $0 }
        link.handlers[0] = { initiator.handle($0) }
        // 已绑定方 B:照搬原 bindConnected 的 onMessage —— 只认数据帧,配对帧落 default 被丢弃。
        link.handlers[1] = { msg in
            switch msg {
            case .clipboardText, .fileOffer, .clipboardImageOffer, .fileComplete:
                break   // 数据帧:本测试不关心
            default:
                break   // hello / pairOffer / pairProof 一并被丢弃 —— 正是死锁根因
            }
        }

        initiator.begin()   // A 发 hello+pairOffer,等 B 应答……B 永不回
        link.pump()

        expect(aOutcome == nil,
               "负向对照:已绑定方丢弃配对帧时,发起方不应拿到任何结果(死锁复现),实际 \(String(describing: aOutcome))")
        log("negative ok: 旧数据流 switch 丢弃配对帧 → 发起方无应答(死锁已复现)")
    }

    // MARK: - 正向:BoundInboundRouter 应答 → 双方配对成功,配对帧零泄漏

    static func positive_routerCompletesRepair() {
        let link = MemLink()
        var aOutcome: PairingManager.Outcome?
        var bOutcome: PairingManager.Outcome?
        var pairingFramesLeaked = 0

        let initiator = makeInitiator(link: link) { aOutcome = $0 }

        // 已绑定方 B:真正的 BoundInboundRouter。makePairing 惰性造应答方 pmB,send 回程喂给 A。
        let router = BoundInboundRouter(makePairing: {
            let pmB = PairingManager(code: code, selfFingerprint: fpB, selfDeviceId: "device-B",
                                     selfName: "DeviceB", peerFingerprint: fpA)
            pmB.send = { link.send(to: 0, $0) }   // B → A
            pmB.onOutcome = { bOutcome = $0 }
            return pmB
        })
        router.onData = { msg in
            switch msg {
            case .hello, .pairOffer, .pairProof: pairingFramesLeaked += 1   // 配对握手帧绝不应漏进数据通道
            default: break                                                  // pairResult 等:与原 default 一致,忽略
            }
        }

        link.handlers[0] = { initiator.handle($0) }
        link.handlers[1] = { router.handle($0) }

        initiator.begin()
        link.pump()

        guard case .success? = aOutcome else {
            return fail("正向:发起方 A 应 .success,实际 \(String(describing: aOutcome))")
        }
        guard case .success? = bOutcome else {
            return fail("正向:已绑定应答方 B 应 .success,实际 \(String(describing: bOutcome))")
        }
        expect(pairingFramesLeaked == 0, "正向:配对握手帧不应漏进数据通道 onData(漏了 \(pairingFramesLeaked) 帧)")
        log("positive ok: BoundInboundRouter 应答 → 双方 .success,配对握手帧零泄漏")
    }

    // MARK: - Helpers

    static func log(_ m: String) { FileHandle.standardError.write(Data("• \(m)\n".utf8)) }
    static func expect(_ c: Bool, _ m: String) { if !c { fail(m) } }
    static func fail(_ m: String) {
        FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8))
        exit(1)
    }
}
