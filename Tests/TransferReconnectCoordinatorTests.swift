// swiftc -module-cache-path /tmp/easysign-swift-module-cache EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift Tests/TransferReconnectCoordinatorTests.swift -o /tmp/transfer-reconnect-coordinator
// /tmp/transfer-reconnect-coordinator

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
        expect(!c.accepts(t0), "进入下一 attempt 后旧 t0 必须失效")
        expect(c.accepts(t1), "waiting 状态必须接受当前 t1")
        expect(c.delayElapsed(t1) == .dial(t1), "2 秒到点后应拨号")
        expect(c.accepts(t1), "delayElapsed 后 dialing 状态仍应接受当前 t1")

        guard case let .schedule(t2, d2) = c.attemptFailed(t1) else { fail("第二次失败应继续") }
        expect(!c.accepts(t1), "进入 t2 后旧 t1 必须失效")
        expect(c.accepts(t2), "waiting 状态必须接受当前 t2")
        expect(t2.attempt == 2, "第三次 attempt 应为 2")
        expect(d2 == 5, "第三次应延迟 5 秒")
        expect(c.delayElapsed(t2) == .dial(t2), "第三次到点后应拨号")
        guard case let .schedule(t3, d3) = c.attemptFailed(t2) else { fail("第三次失败应继续") }
        expect(t3.attempt == 3, "第四次 attempt 应为 3")
        expect(d3 == 10, "第四次应延迟 10 秒")
        expect(c.delayElapsed(t3) == .dial(t3), "第四次到点后应拨号")
        expect(c.attemptFailed(t3) == .waitForEvent, "四次失败后必须停止定时重试")
        expect(!c.accepts(t3), "进入 waitingForEvent 后最后一个 token 必须失效")

        var duplicateDrop = Coordinator()
        duplicateDrop.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(d0) = duplicateDrop.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("首次 drop 应开启恢复周期") }
        let activeGeneration = duplicateDrop.generation
        expect(duplicateDrop.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) == .none, "活动恢复周期内重复 drop 必须幂等")
        expect(duplicateDrop.generation == activeGeneration, "重复 drop 不得推进 generation")
        expect(duplicateDrop.accepts(d0), "重复 drop 后首个 token 必须仍有效")

        var deferred = Coordinator()
        deferred.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(deferredToken) = deferred.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("deferred 测试需要 current dialing token") }
        expect(deferred.deferDial(deferredToken),
               "current dialing token 应进入 deferred phase")
        expect(deferred.phase == .deferred(deferredToken),
               "deferred phase 必须保存 exact token")
        expect(deferred.accepts(deferredToken),
               "deferred token 必须保持 generation/token 有效")
        for _ in 0..<(Coordinator.delays.count + 3) {
            expect(deferred.recoveryEvent(
                pathSatisfied: true, canDial: true, busy: true, endpointKey: "ep-1"
            ) == .none, "持续 busy 不得消耗网络重试次数")
        }
        expect(deferred.deferredToken?.attempt == 0,
               "超过旧 0/2/5/10 窗口后 attempt 仍应为 0")
        guard case let .dial(resumedDeferredToken) = deferred.resumeDeferredRecovery(
            deferredToken,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("临时 blocker 释放后应产生一次 coordinated recovery") }
        expect(resumedDeferredToken.attempt == 0,
               "deferred release 不得消耗实际拨号预算")
        expect(resumedDeferredToken.generation != deferredToken.generation,
               "deferred release 应换 generation 隔离旧 session 回调")
        expect(deferred.resumeDeferredRecovery(
            deferredToken,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) == .none, "同一个 deferred token 不得恢复两次")

        var deferredBudget = Coordinator()
        deferredBudget.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(budget0) = deferredBudget.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(budget1, budgetDelay1) = deferredBudget.attemptFailed(budget0),
              deferredBudget.delayElapsed(budget1) == .dial(budget1)
        else { fail("预算测试必须先产生已真实失败后的 attempt 1") }
        expect(budgetDelay1 == 2 && budget1.attempt == 1,
               "attempt 0 真实失败后应进入 2s/attempt 1")
        expect(deferredBudget.deferDial(budget1),
               "attempt 1 到点遇 busy 应进入 deferred")
        guard case let .dial(resumedBudget1) = deferredBudget.resumeDeferredRecovery(
            budget1,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("attempt 1 blocker 释放后应恢复") }
        expect(resumedBudget1.attempt == 1,
               "同 endpoint deferred release 必须保留 attempt 1")
        expect(resumedBudget1.generation != budget1.generation,
               "保留 attempt 时仍必须换 generation 拒绝迟到回调")

        expect(deferredBudget.deferDial(resumedBudget1),
               "同一 attempt 再次遇 blocker 仍可 deferred")
        guard case let .dial(repeatedBudget1) = deferredBudget.resumeDeferredRecovery(
            resumedBudget1,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("重复 blocker 释放后应恢复同一 attempt") }
        expect(repeatedBudget1.attempt == 1,
               "重复 defer/release 不得刷新 attempt 预算")

        guard case let .schedule(budget2, budgetDelay2) = deferredBudget.attemptFailed(repeatedBudget1),
              deferredBudget.delayElapsed(budget2) == .dial(budget2)
        else { fail("attempt 1 真实失败后应进入 attempt 2") }
        expect(budgetDelay2 == 5 && budget2.attempt == 2,
               "第二个真实失败应进入 5s/attempt 2")
        expect(deferredBudget.deferDial(budget2), "attempt 2 应可 deferred")
        guard case let .dial(resumedBudget2) = deferredBudget.resumeDeferredRecovery(
            budget2,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("attempt 2 blocker 释放后应恢复") }
        expect(resumedBudget2.attempt == 2,
               "同 endpoint deferred release 必须保留 attempt 2")

        guard case let .schedule(budget3, budgetDelay3) = deferredBudget.attemptFailed(resumedBudget2),
              deferredBudget.delayElapsed(budget3) == .dial(budget3)
        else { fail("attempt 2 真实失败后应进入 attempt 3") }
        expect(budgetDelay3 == 10 && budget3.attempt == 3,
               "第三个真实失败应进入 10s/attempt 3")
        expect(deferredBudget.deferDial(budget3), "attempt 3 应可 deferred")
        guard case let .dial(resumedBudget3) = deferredBudget.resumeDeferredRecovery(
            budget3,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("attempt 3 blocker 释放后应恢复") }
        expect(resumedBudget3.attempt == 3,
               "同 endpoint deferred release 必须保留 attempt 3")
        expect(deferredBudget.attemptFailed(resumedBudget3) == .waitForEvent,
               "attempt 3 真实失败后必须 exhausted，不得由 blocker 刷新预算")
        expect(deferredBudget.phase == .waitingForEvent,
               "有限周期耗尽后必须等待外部恢复事件")

        var deferredStopped = Coordinator()
        deferredStopped.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(stoppedDeferredToken) = deferredStopped.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("deferred stop 测试需要 token") }
        expect(deferredStopped.deferDial(stoppedDeferredToken), "stop 前应成功 deferred")
        deferredStopped.stop()
        expect(deferredStopped.resumeDeferredRecovery(
            stoppedDeferredToken,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) == .none, "stop 后 deferred release 不得恢复")

        var deferredBound = Coordinator()
        deferredBound.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(boundDeferredToken) = deferredBound.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("deferred bind 测试需要 token") }
        expect(deferredBound.deferDial(boundDeferredToken), "bind 前应成功 deferred")
        deferredBound.connected(to: peer, endpointKey: "ep-1")
        expect(deferredBound.resumeDeferredRecovery(
            boundDeferredToken,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) == .none, "成功 bind 后 deferred token 必须 stale，不得自动拨号")

        var deferredExplicit = Coordinator()
        deferredExplicit.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(explicitDeferredToken) = deferredExplicit.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("deferred explicit 测试需要 token") }
        expect(deferredExplicit.deferDial(explicitDeferredToken),
               "显式连接前应成功 deferred")
        deferredExplicit.explicitlyConnecting(to: peer)
        expect(deferredExplicit.resumeDeferredRecovery(
            explicitDeferredToken,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) == .none, "用户显式会话必须使 deferred token stale")

        var deferredArbitration = Coordinator()
        deferredArbitration.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(arbitrationDeferredToken) = deferredArbitration.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("deferred arbitration 测试需要 token") }
        expect(deferredArbitration.deferDial(arbitrationDeferredToken),
               "arbitration 变化前应成功 deferred")
        expect(deferredArbitration.resumeDeferredRecovery(
            arbitrationDeferredToken,
            pathSatisfied: true,
            canDial: false,
            endpointKey: "ep-1"
        ) == .waitForEvent, "release 不得绕过当前单向拨号仲裁")
        expect(deferredArbitration.phase == .waitingForEvent,
               "不可拨一端必须等待入站事件")

        var deferredEndpoint = Coordinator()
        deferredEndpoint.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(endpointAttempt0) = deferredEndpoint.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(endpointDeferredToken, _) = deferredEndpoint.attemptFailed(endpointAttempt0),
              deferredEndpoint.delayElapsed(endpointDeferredToken) == .dial(endpointDeferredToken)
        else { fail("deferred endpoint 测试需要 token") }
        expect(endpointDeferredToken.attempt == 1,
               "endpoint 变化测试必须从非零 attempt 开始")
        expect(deferredEndpoint.deferDial(endpointDeferredToken),
               "endpoint 变化前应成功 deferred")
        guard case let .dial(latestEndpointToken) = deferredEndpoint.resumeDeferredRecovery(
            endpointDeferredToken,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-2"
        ) else { fail("release 必须经 coordinator 切换到最新 endpoint") }
        expect(latestEndpointToken.endpointKey == "ep-2",
               "deferred release 不得拨旧 endpoint")
        expect(latestEndpointToken.attempt == 0,
               "endpoint 变化才应开启 attempt 0 新周期")

        let replacementPeer = TransferAutoReconnect.PeerRef(
            deviceId: "peer-C",
            fingerprint: "fp-C"
        )
        var deferredTarget = Coordinator()
        deferredTarget.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(oldTarget0) = deferredTarget.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(oldTarget1, _) = deferredTarget.attemptFailed(oldTarget0),
              deferredTarget.delayElapsed(oldTarget1) == .dial(oldTarget1)
        else { fail("target 变化测试需要 deferred attempt 1") }
        expect(deferredTarget.deferDial(oldTarget1), "target 变化前应成功 deferred")
        deferredTarget.connected(to: replacementPeer, endpointKey: "ep-C")
        expect(deferredTarget.resumeDeferredRecovery(
            oldTarget1,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-C"
        ) == .none, "target 变化后旧 deferred token 必须 stale")
        guard case let .dial(replacementTarget0) = deferredTarget.unexpectedDrop(
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-C"
        ) else { fail("新 target 应开启独立恢复周期") }
        expect(replacementTarget0.peer == replacementPeer
               && replacementTarget0.attempt == 0,
               "target 变化后的新周期必须从 attempt 0 开始")

        let exhaustedGeneration = c.generation
        expect(c.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) == .none, "重试耗尽后重复 drop 不得重开预算")
        expect(c.generation == exhaustedGeneration, "耗尽后的重复 drop 不得推进 generation")
        expect(c.phase == .waitingForEvent, "耗尽后的重复 drop 必须保留 waitingForEvent")

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

        var explicitlyDisconnected = Coordinator()
        explicitlyDisconnected.connected(to: peer, endpointKey: "ep-1")
        let generationBeforeDisconnect = explicitlyDisconnected.generation
        explicitlyDisconnected.userDisconnected(from: peer)
        expect(explicitlyDisconnected.generation != generationBeforeDisconnect,
               "主动断开必须推进 generation")
        expect(!explicitlyDisconnected.allowsInbound(peer),
               "bye 丢失后仍必须拒绝已主动断开 peer 的免码入站")
        expect(explicitlyDisconnected.recoveryEvent(
            pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1"
        ) == .none, "wake/discovery 事件不得解除主动断开抑制")
        explicitlyDisconnected.networkUnavailable()
        expect(explicitlyDisconnected.recoveryEvent(
            pathSatisfied: true, canDial: true, busy: false, endpointKey: "ep-1"
        ) == .none, "network restored 事件不得解除主动断开抑制")
        explicitlyDisconnected.connected(to: peer, endpointKey: "ep-1")
        expect(!explicitlyDisconnected.allowsInbound(peer),
               "未请求的 inbound/automatic bind 不得解除本机 suppression")
        explicitlyDisconnected.explicitlyConnecting(to: peer)
        expect(explicitlyDisconnected.allowsInbound(peer),
               "只有本机显式 Connect/Retry 才能解除对应 peer 抑制")

        var clearedPeer = Coordinator()
        clearedPeer.connected(to: peer, endpointKey: "ep-1")
        clearedPeer.userDisconnected(from: peer)
        clearedPeer.clearPeer(peer)
        expect(clearedPeer.allowsInbound(peer),
               "清除配对设备必须同时清除对应 suppression")

        var disconnectRace = Coordinator()
        disconnectRace.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(disconnectAttempt) = disconnectRace.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ), case let .schedule(disconnectToken, _) = disconnectRace.attemptFailed(disconnectAttempt)
        else { fail("主动断开前应有可失效的排程 token") }
        disconnectRace.userDisconnected(from: peer)
        expect(!disconnectRace.accepts(disconnectToken),
               "主动断开必须使已排程 token 失效")
        expect(disconnectRace.delayElapsed(disconnectToken) == .none,
               "主动断开后旧排程 work 不得醒来拨号")

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
        let changedGeneration = c.generation
        expect(c.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) == .none, "endpoint 切换后迟到的旧 drop 不得破坏新周期")
        expect(c.generation == changedGeneration, "迟到 drop 不得推进新周期 generation")
        expect(c.accepts(newToken), "迟到 drop 后新 endpoint token 必须仍有效")

        var cannotDial = Coordinator()
        cannotDial.connected(to: peer, endpointKey: "ep-2")
        expect(cannotDial.unexpectedDrop(pathSatisfied: true, canDial: false, endpointKey: "ep-2") == .waitForEvent,
               "deviceId 较大的一端只能等待拨入")

        var connectedBusyEvent = Coordinator()
        connectedBusyEvent.connected(to: peer, endpointKey: "ep-2")
        expect(connectedBusyEvent.recoveryEvent(
            pathSatisfied: true, canDial: true, busy: true, endpointKey: "ep-2"
        ) == .none, "已连接时的恢复事件不得开启自动恢复周期")
        guard case .dial = connectedBusyEvent.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-2"
        ) else { fail("忙碌恢复事件不得吞掉随后真实 unexpectedDrop") }

        var missingEndpoint = Coordinator()
        missingEndpoint.connected(to: peer, endpointKey: "ep-2")
        expect(missingEndpoint.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: nil as String?
        ) == .waitForEvent, "没有 endpoint 时必须等待新事件")

        var unavailable = Coordinator()
        unavailable.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(unavailableToken) = unavailable.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("peer 消失测试需要有效 token") }
        let unavailableGeneration = unavailable.generation
        unavailable.peerBecameUnavailable()
        expect(unavailable.generation != unavailableGeneration, "peer 消失必须推进 generation")
        expect(unavailable.target == peer, "peer 消失后必须保留恢复 target")
        expect(unavailable.endpointKey == nil, "peer 消失后必须清除 endpoint")
        expect(unavailable.phase == .waitingForEvent, "peer 消失后必须等待新事件")
        expect(!unavailable.accepts(unavailableToken), "peer 消失后旧 token 必须失效")
        expect(unavailable.recoveryEvent(
            pathSatisfied: true, canDial: false, busy: false, endpointKey: nil
        ) == .waitForEvent, "peer 消失且无可拨 endpoint 时恢复事件必须继续等待")

        var saidBye = Coordinator()
        saidBye.connected(to: peer, endpointKey: "ep-1")
        saidBye.peerSaidBye(peer)
        expect(saidBye.target == nil && saidBye.endpointKey == nil,
               "peer .bye 必须清除对应 target 与 endpoint")
        expect(saidBye.phase == .inactive, "peer .bye 后自动恢复必须 inactive")
        expect(saidBye.allowsInbound(peer), "peer .bye 不得加入本机 suppression")

        var cancelled = Coordinator()
        cancelled.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(cancelledToken) = cancelled.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("取消自动恢复测试需要有效 token") }
        cancelled.cancelAutomaticRecovery()
        expect(!cancelled.accepts(cancelledToken), "取消自动恢复后旧 token 必须失效")
        expect(cancelled.phase == .inactive, "取消自动恢复后 phase 必须 inactive")
        expect(cancelled.target == peer && cancelled.endpointKey == "ep-1",
               "取消自动恢复不得清除 target 或 endpoint")

        var stopped = Coordinator()
        stopped.connected(to: peer, endpointKey: "ep-1")
        guard case let .dial(stoppedToken) = stopped.unexpectedDrop(
            pathSatisfied: true, canDial: true, endpointKey: "ep-1"
        ) else { fail("stop 测试需要有效 token") }
        stopped.stop()
        expect(stopped.target == nil && stopped.endpointKey == nil,
               "stop 必须清除 target 与 endpoint")
        expect(stopped.phase == .inactive, "stop 后 phase 必须 inactive")
        expect(!stopped.accepts(stoppedToken), "stop 后旧 token 必须失效")

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
