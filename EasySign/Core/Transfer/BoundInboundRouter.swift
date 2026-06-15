import Foundation

/// 已绑定(按已配对关系直接判为 `.connected`)连接上的入站消息路由。
///
/// 背景:互传的「重连」与「配对」是两条各自独立判定、互不协商的路径,状态不同步时会角色错位——
/// 一端在跑配对握手(发 hello / pairOffer / pairProof),另一端却因认得对端证书指纹直接 bindConnected
/// 绑成 `.connected`,其数据流处理器把这些配对帧丢进 `default` → 发起方一句应答都收不到 → 配对超时(死锁)。
///
/// 本路由让已绑定连接对配对消息保持容忍:对端一旦在该连接上(重新)发起配对,就地补一个应答方握手;
/// 其余数据帧照常交给 `onData`。普通重连不发配对消息,永不触发 `makePairing`,行为与原先完全一致。
///
/// 线程:与原 `onMessage` 一样在连接的网络队列上被调用。`makePairing` 只读调用方在绑定时(主线程)
/// 捕获好的不可变量来构造 `PairingManager`,不触碰可变服务状态;`PairingManager` 的 `onOutcome` 自行
/// 跳回主线程处理服务状态。故本类内部无需加锁。
final class BoundInboundRouter {
    /// 惰性构造应答方配对管理器(内部已把 `send` 接到本连接、`onOutcome` 接回服务)。
    /// 返回 `nil` = 当前无法配对(如身份未就绪),忽略该次配对请求。
    private let makePairing: () -> PairingManager?
    private var rePair: PairingManager?

    /// 非配对消息(剪贴板 / 文件控制帧 / pairResult 等)出口,由调用方接管原数据处理。
    var onData: ((WireMessage) -> Void)?

    init(makePairing: @escaping () -> PairingManager?) { self.makePairing = makePairing }

    func handle(_ msg: WireMessage) {
        switch msg {
        case .hello, .pairOffer, .pairProof:
            if rePair == nil {
                guard let pm = makePairing() else { return }
                rePair = pm
                pm.begin()          // 先发我方 hello+pairOffer,再喂入本条消息(顺序同 startPairing)
            }
            rePair?.handle(msg)
        default:
            onData?(msg)            // pairResult 与数据帧:交回原处理(原 switch 的 default 会忽略 pairResult)
        }
    }
}
