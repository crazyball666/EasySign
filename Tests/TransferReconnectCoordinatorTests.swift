import Foundation

@main
struct TransferReconnectCoordinatorTests {
    typealias Coordinator = TransferReconnectCoordinator
    static let peer = TransferAutoReconnect.PeerRef(deviceId: "peer-B", fingerprint: "fp-B")

    static func main() {
        var c = Coordinator()
        c.connected(to: peer, endpointKey: "ep-1")

        let first = c.unexpectedDrop(pathSatisfied: true, canDial: true, endpointKey: "ep-1")
        guard case let .dial(t0) = first else { fail("断线后应立即拨号") }
        expect(t0.attempt == 0, "首次 attempt 应为 0")
        expect(t0.peer == peer && t0.endpointKey == "ep-1",
               "token 必须绑定预期设备与本轮 endpoint")

        let second = c.attemptFailed(t0)
        guard case let .schedule(t1, delay) = second else { fail("首次失败应安排第二次") }
        expect(t1.attempt == 1 && delay == 2, "第二次应延迟 2 秒")
        expect(c.delayElapsed(t1) == .dial(t1), "2 秒到点后应拨号")

        guard case let .schedule(t2, d2) = c.attemptFailed(t1) else { fail("第二次失败应继续") }
        expect(t2.attempt == 2, "第三次 attempt 应为 2")
        expect(d2 == 5, "第三次应延迟 5 秒")
        expect(c.delayElapsed(t2) == .dial(t2), "第三次到点后应拨号")
        guard case let .schedule(t3, d3) = c.attemptFailed(t2) else { fail("第三次失败应继续") }
        expect(t3.attempt == 3, "第四次 attempt 应为 3")
        expect(d3 == 10, "第四次应延迟 10 秒")
        expect(c.delayElapsed(t3) == .dial(t3), "第四次到点后应拨号")
        expect(c.attemptFailed(t3) == .waitForEvent, "四次失败后必须停止定时重试")

        let fresh = c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1")
        guard case let .dial(freshToken) = fresh else { fail("新的恢复事件应重开周期") }
        expect(freshToken.generation != t0.generation, "新周期必须换 generation")

        let duplicate = c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1")
        expect(duplicate == .none, "活动周期内重复事件不能重置次数")

        var waitingDuplicate = Coordinator()
        waitingDuplicate.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(w0) = waitingDuplicate.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(w1, _) = waitingDuplicate.attemptFailed(w0)
        else { fail("需要一个有效的 waiting token") }
        expect(
            waitingDuplicate.recoveryEvent(
                pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1"
            ) == .none,
            "waiting 阶段同 endpoint 的恢复事件不能重置次数"
        )
        expect(waitingDuplicate.delayElapsed(w1) == .dial(w1),
               "waiting 去重后原延迟 token 仍应有效")

        c.explicitlyConnecting(to: peer)
        expect(!c.accepts(freshToken), "用户手动连接必须立即使旧自动 token 失效")

        var manualRace = Coordinator()
        manualRace.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(r0) = manualRace.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(r1, _) = manualRace.attemptFailed(r0)
        else { fail("需要一个等待中的自动任务") }
        manualRace.explicitlyConnecting(to: peer)
        expect(manualRace.delayElapsed(r1) == .none,
               "用户手动连接后旧延迟任务不得醒来拨号")

        var networkRace = Coordinator()
        networkRace.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(n0) = networkRace.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(n1, _) = networkRace.attemptFailed(n0)
        else { fail("网络中断测试需要一个有效的 waiting token") }
        let waitingGeneration = networkRace.generation
        networkRace.networkUnavailable()
        expect(networkRace.generation != waitingGeneration, "网络中断必须推进 generation")
        expect(!networkRace.accepts(n1), "网络中断后旧 waiting token 必须失效")
        expect(networkRace.delayElapsed(n1) == .none,
               "网络中断后旧延迟任务不得醒来拨号")

        c.networkUnavailable()
        let restored = c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1")
        guard case .dial = restored else { fail("网络恢复应重新拨号") }

        c.userDisconnected(from: peer)
        expect(!c.allowsInbound(peer), "主动断开后应拒绝免码入站")
        expect(c.recoveryEvent(pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1") == .none,
               "主动断开后恢复事件不得重连")
        c.explicitlyConnecting(to: peer)
        expect(c.allowsInbound(peer), "本机显式连接后解除抑制")

        c.connected(to: peer, endpointKey: "ep-1")
        let old = c.unexpectedDrop(pathSatisfied: true, canDial: true, endpointKey: "ep-1")
        guard case let .dial(oldToken) = old else { fail("需要旧 token") }
        let endpointChanged = c.recoveryEvent(
            pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-2"
        )
        guard case let .dial(newToken) = endpointChanged else { fail("endpoint 变化后应立即拨新 endpoint") }
        expect(newToken.endpointKey == "ep-2", "新 token 必须绑定变化后的 endpoint")
        expect(newToken.generation != oldToken.generation, "endpoint 变化必须开启新 generation")
        expect(!c.accepts(oldToken), "endpoint 变化后旧连接/超时回调必须失效")

        var cannotDial = Coordinator()
        cannotDial.connected(to: peer, endpointKey: "ep-2")
        expect(cannotDial.unexpectedDrop(pathSatisfied: true, canDial: false, endpointKey: "ep-2") == .waitForEvent,
               "deviceId 较大的一端只能等待拨入")

        var missingEndpoint = Coordinator()
        missingEndpoint.connected(to: peer, endpointKey: "ep-2")
        expect(missingEndpoint.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: nil as String?
        ) == .waitForEvent, "没有 endpoint 时必须等待新事件")

        print("ALL PASS")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
