// swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -module-cache-path /tmp/easysign-swift-module-cache EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-execution-policy
// /tmp/transfer-reconnect-execution-policy

import Foundation
import Network

@main
struct TransferReconnectExecutionPolicyTests {
    typealias Coordinator = TransferReconnectCoordinator
    typealias Policy = TransferReconnectExecutionPolicy

    final class ConnectionProbe {}

    static let peerRef = TransferAutoReconnect.PeerRef(deviceId: "peer-B", fingerprint: "fp-B")
    static let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 5000)

    static func peer(_ deviceId: String = "peer-B",
                     _ fingerprint: String = "fp-B",
                     recoveryToken: String? = "ep-1") -> DiscoveredPeer {
        DiscoveredPeer(
            deviceId: deviceId,
            name: deviceId,
            fingerprint: fingerprint,
            endpoint: endpoint,
            recoveryToken: recoveryToken
        )
    }

    static func main() {
        var coordinator = Coordinator()
        coordinator.connected(to: peerRef, endpointKey: "ep-1")
        guard case let .dial(token) = coordinator.unexpectedDrop(
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("connected → unexpectedDrop 应产生 automatic token") }

        let automatic = TransferConnectionOrigin.automatic(token)
        expect(automatic.pairingCode(requested: "654321") == nil,
               "automatic 必须忽略用户配对码")
        expect(automatic.expectedFingerprint == peerRef.fingerprint,
               "automatic 必须固定 token 对端指纹")
        expect(TransferConnectionOrigin.user.pairingCode(requested: "654321") == "654321",
               "user 必须保留请求的配对码")
        expect(TransferConnectionOrigin.user.expectedFingerprint == nil,
               "user 不得隐式固定自动 token 指纹")

        var serviceGeneration = Policy.ServiceGeneration()
        let firstServiceGeneration = serviceGeneration.begin()
        expect(!serviceGeneration.accepts(firstServiceGeneration),
               "server setup 尚未完成时不得接受 inbound callback")
        expect(serviceGeneration.activate(firstServiceGeneration),
               "当前 setup generation 完成后应可激活")
        expect(serviceGeneration.isRunning
               && serviceGeneration.accepts(firstServiceGeneration),
               "运行中的 exact generation 应接受 inbound callback")
        serviceGeneration.stop()
        expect(!serviceGeneration.isRunning
               && !serviceGeneration.accepts(firstServiceGeneration),
               "stop 必须推进代次并拒绝已投递的旧 inbound callback")
        var staleInboundCancelled = false
        var staleInboundPresentation = ConnectionState.idle
        var staleInboundRecoveryRequests = 0
        if serviceGeneration.accepts(firstServiceGeneration) {
            staleInboundPresentation = .failed("stale inbound")
            staleInboundRecoveryRequests += 1
        } else {
            staleInboundCancelled = true
        }
        expect(staleInboundCancelled
               && staleInboundPresentation == .idle
               && staleInboundRecoveryRequests == 0,
               "stale inbound 必须只 cancel，不得污染 UI 或触发 recovery")
        let restartedServiceGeneration = serviceGeneration.begin()
        expect(restartedServiceGeneration != firstServiceGeneration,
               "restart 必须使用新 generation")
        expect(serviceGeneration.activate(restartedServiceGeneration),
               "restart setup 应能激活新 generation")
        expect(serviceGeneration.accepts(restartedServiceGeneration)
               && !serviceGeneration.accepts(firstServiceGeneration),
               "restart 只能接受新 generation，旧 server callback 必须静默失效")
        expect(!serviceGeneration.activate(firstServiceGeneration),
               "迟到旧 setup completion 不得覆盖当前 running generation")

        let peerA = TransferAutoReconnect.PeerRef(deviceId: "peer-A", fingerprint: "fp-A")
        let peerB = TransferAutoReconnect.PeerRef(deviceId: "peer-B", fingerprint: "fp-B")
        var crossPeerCoordinator = Coordinator()
        crossPeerCoordinator.connected(to: peerA, endpointKey: "ep-A")
        crossPeerCoordinator.userDisconnected(from: peerA)
        expect(Policy.inboundDecision(
            isPairedCodeless: true,
            locallyAllowed: crossPeerCoordinator.allowsInbound(peerA)
        ) == .rejectAndCancel,
        "用户断开 A 后，A 的免码入站必须继续按 peer 抑制")
        expect(Policy.inboundDecision(
            isPairedCodeless: true,
            locallyAllowed: crossPeerCoordinator.allowsInbound(peerB)
        ) == .acceptCodeless,
        "用户断开 A 不得污染 B 的免码入站")
        expect(Policy.allowsSessionActivity(
            servicesRunning: serviceGeneration.isRunning,
            stopRequested: false
        ), "运行中的服务应允许未被抑制的 B 绑定及恢复")
        crossPeerCoordinator.connected(to: peerB, endpointKey: "ep-B")
        expect(!crossPeerCoordinator.allowsInbound(peerA),
               "B 合法绑定后仍不得解除 A 的按 peer suppression")
        guard case .dial = crossPeerCoordinator.unexpectedDrop(
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-B"
        ) else { fail("A 断开后合法绑定 B，B 意外掉线仍必须恢复") }
        serviceGeneration.stop()
        crossPeerCoordinator.stop()
        expect(!Policy.allowsSessionActivity(
            servicesRunning: serviceGeneration.isRunning,
            stopRequested: true
        ), "完整 stop 必须阻止迟到 bind 与掉线恢复")
        var acceptedBindAfterStop = false
        var recoveryAfterStop = Coordinator.Command.none
        if Policy.allowsSessionActivity(
            servicesRunning: serviceGeneration.isRunning,
            stopRequested: true
        ) {
            acceptedBindAfterStop = true
            crossPeerCoordinator.connected(to: peerB, endpointKey: "ep-B")
            recoveryAfterStop = crossPeerCoordinator.unexpectedDrop(
                pathSatisfied: true,
                canDial: true,
                endpointKey: "ep-B"
            )
        }
        expect(!acceptedBindAfterStop && recoveryAfterStop == .none,
               "stop 后不得绑定 B，也不得为 B 创建掉线恢复命令")

        let userConnecting = Policy.discoverySessionDisposition(
            connectionState: .connecting,
            hasBoundConnection: false,
            activeOrigin: .user,
            hasActivePairingConnection: false
        )
        let userPairing = Policy.discoverySessionDisposition(
            connectionState: .pairing,
            hasBoundConnection: false,
            activeOrigin: .user,
            hasActivePairingConnection: true
        )
        let inboundPairing = Policy.discoverySessionDisposition(
            connectionState: .pairing,
            hasBoundConnection: false,
            activeOrigin: nil,
            hasActivePairingConnection: true
        )
        let boundSession = Policy.discoverySessionDisposition(
            connectionState: .connected(peerName: "B"),
            hasBoundConnection: true,
            activeOrigin: nil,
            hasActivePairingConnection: false
        )
        let idleSession = Policy.discoverySessionDisposition(
            connectionState: .idle,
            hasBoundConnection: false,
            activeOrigin: nil,
            hasActivePairingConnection: false
        )
        let automaticConnecting = Policy.discoverySessionDisposition(
            connectionState: .connecting,
            hasBoundConnection: false,
            activeOrigin: automatic,
            hasActivePairingConnection: false
        )
        expect(userConnecting == .manual && userPairing == .manual,
               "手动 connecting/pairing 必须归为 manual session")
        expect(inboundPairing == .transientBusy,
               "无 outbound origin 的 inbound pairing 必须归为 transient busy")
        expect(boundSession == .bound, "已绑定连接必须归为 bound session")
        expect(idleSession == .idle, "空闲状态必须归为 idle session")
        expect(automaticConnecting == .automatic,
               "automatic connecting 必须归为 automatic session，而非通用 busy")
        for disposition in [userConnecting, userPairing, inboundPairing, boundSession] {
            expect(disposition.preservesPresentation,
                   "manual/pairing/bound 遇到 peer 消失或 browser failure 必须保留 UI")
            expect(!disposition.allowsAutomaticRecovery,
                   "manual/pairing/bound 不得由 discovery 事件创建 automatic token")
        }
        for disposition in [idleSession, automaticConnecting] {
            expect(!disposition.preservesPresentation,
                   "idle/automatic discovery failure 应可呈现等待状态")
            expect(disposition.allowsAutomaticRecovery,
                   "idle/automatic session 应允许 discovery 驱动恢复")
        }

        let validStart = Policy.mayStartAutomatic(
            token: token,
            tokenAccepted: true,
            busy: false,
            hasActiveConnection: false,
            pathSatisfied: true,
            currentPeer: peerRef,
            currentEndpointKey: "ep-1"
        )
        expect(validStart, "全部快照与 token 匹配时才可自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: true, hasActiveConnection: false,
            pathSatisfied: true, currentPeer: peerRef, currentEndpointKey: "ep-1"
        ), "busy 时不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: false, hasActiveConnection: true,
            pathSatisfied: true, currentPeer: peerRef, currentEndpointKey: "ep-1"
        ), "已有活动连接时不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
            pathSatisfied: true,
            currentPeer: .init(deviceId: "peer-X", fingerprint: "fp-B"),
            currentEndpointKey: "ep-1"
        ), "错误 peer 不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
            pathSatisfied: true,
            currentPeer: .init(deviceId: "peer-B", fingerprint: "fp-X"),
            currentEndpointKey: "ep-1"
        ), "peer fingerprint 不完整匹配不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
            pathSatisfied: true, currentPeer: nil, currentEndpointKey: "ep-1"
        ), "nil peer 不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
            pathSatisfied: true, currentPeer: peerRef, currentEndpointKey: nil
        ), "nil endpoint 不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
            pathSatisfied: true, currentPeer: peerRef, currentEndpointKey: "ep-2"
        ), "错误 endpoint 不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: true, busy: false, hasActiveConnection: false,
            pathSatisfied: false, currentPeer: peerRef, currentEndpointKey: "ep-1"
        ), "path 不可用时不得自动拨号")
        expect(!Policy.mayStartAutomatic(
            token: token, tokenAccepted: false, busy: false, hasActiveConnection: false,
            pathSatisfied: true, currentPeer: peerRef, currentEndpointKey: "ep-1"
        ), "coordinator 不接受 token 时不得自动拨号")

        expect(Policy.readyPeerMatches(
            token: token,
            actual: PairedPeer(deviceId: "peer-B", name: "B", fingerprint: "fp-B")
        ), "ready 对端 deviceId + fingerprint 都匹配时应接受")
        expect(!Policy.readyPeerMatches(
            token: token,
            actual: PairedPeer(deviceId: "peer-X", name: "X", fingerprint: "fp-B")
        ), "只有 fingerprint 相同但 deviceId 不同必须拒绝")
        expect(!Policy.readyPeerMatches(
            token: token,
            actual: PairedPeer(deviceId: "peer-B", name: "B", fingerprint: "fp-X")
        ), "只有 deviceId 相同但 fingerprint 不同必须拒绝")

        expect(Policy.completionDecision(
            attemptMatches: false, connectionMatches: true, tokenAccepted: true
        ) == .ignore, "attempt 不匹配必须忽略旧完成回调")
        expect(Policy.completionDecision(
            attemptMatches: true, connectionMatches: false, tokenAccepted: true
        ) == .ignore, "connection 不匹配必须忽略旧完成回调")
        expect(Policy.completionDecision(
            attemptMatches: true, connectionMatches: true, tokenAccepted: false
        ) == .cleanupOnly, "token 失效仍必须清理本 attempt")
        expect(Policy.completionDecision(
            attemptMatches: true, connectionMatches: true, tokenAccepted: true
        ) == .cleanupAndRetry, "attempt/connection/token 全匹配才可清理并重试")

        var endpointRaceCoordinator = Coordinator()
        endpointRaceCoordinator.connected(to: peerRef, endpointKey: "ep-1")
        guard case let .dial(oldEndpointToken) = endpointRaceCoordinator.unexpectedDrop(
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("endpoint 竞态需要一个 ep-1 自动 attempt") }
        let endpointChangeActions = Policy.discoveryEndpointActions(
            oldEndpointKey: "ep-1",
            newEndpointKey: "ep-2",
            hasBoundConnection: false,
            hasActiveAutomaticAttempt: true
        )
        expect(endpointChangeActions == [
            .invalidateAutomaticRecovery,
            .cleanupAutomaticAttempt,
            .requestRecovery,
        ], "自动拨号中 endpoint 变化必须先失效、再收口旧 attempt、最后请求最新 endpoint")
        expect(Policy.discoveryEndpointActions(
            oldEndpointKey: "ep-1",
            newEndpointKey: "ep-2",
            hasBoundConnection: true,
            hasActiveAutomaticAttempt: false
        ) == [.recordBoundEndpoint, .requestRecovery],
        "bound connection 的 endpoint 变化应更新 coordinator，但不清理连接")
        expect(Policy.discoveryEndpointActions(
            oldEndpointKey: "ep-1",
            newEndpointKey: "ep-2",
            hasBoundConnection: false,
            hasActiveAutomaticAttempt: false
        ) == [.requestRecovery], "空闲/等待时 endpoint 变化直接请求新周期")
        expect(Policy.discoveryEndpointActions(
            oldEndpointKey: "ep-1",
            newEndpointKey: "ep-1",
            hasBoundConnection: false,
            hasActiveAutomaticAttempt: true
        ).isEmpty, "endpoint key 未变化不得打断当前 attempt")

        var automaticConnectionCount = 1
        var replacementCommand = Coordinator.Command.none
        for action in endpointChangeActions {
            switch action {
            case .invalidateAutomaticRecovery:
                endpointRaceCoordinator.peerBecameUnavailable()
                expect(!endpointRaceCoordinator.accepts(oldEndpointToken),
                       "处理 ep-2 前必须先使 ep-1 token 失效")
            case .cleanupAutomaticAttempt:
                expect(Policy.completionDecision(
                    attemptMatches: true,
                    connectionMatches: true,
                    tokenAccepted: endpointRaceCoordinator.accepts(oldEndpointToken)
                ) == .cleanupOnly, "旧 attempt 必须完成 identity cleanup，但不得续排 ep-1 retry")
                automaticConnectionCount -= 1
            case .recordBoundEndpoint:
                fail("未绑定的自动 attempt 不应走 bound endpoint 更新")
            case .requestRecovery:
                expect(automaticConnectionCount == 0,
                       "请求 ep-2 前旧 ep-1 connection 必须已经收口，禁止并发拨号")
                replacementCommand = endpointRaceCoordinator.recoveryEvent(
                    pathSatisfied: true,
                    canDial: true,
                    busy: false,
                    endpointKey: "ep-2"
                )
            }
        }
        guard case let .dial(newEndpointToken) = replacementCommand else {
            fail("旧 attempt 收口后必须立即拨最新 ep-2")
        }
        automaticConnectionCount += 1
        expect(newEndpointToken.endpointKey == "ep-2",
               "替代 token 必须绑定最新 endpoint")
        expect(newEndpointToken.generation != oldEndpointToken.generation,
               "endpoint 变化必须换 generation")
        expect(automaticConnectionCount == 1,
               "endpoint 切换全过程最多只能保留一个自动 connection")

        var busyDialCoordinator = Coordinator()
        busyDialCoordinator.connected(to: peerRef, endpointKey: "ep-1")
        guard case let .dial(busyToken0) = busyDialCoordinator.unexpectedDrop(
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("busy dial 竞态需要当前 dialing token") }

        let staleBusyToken = Coordinator.Token(
            generation: busyToken0.generation &- 1,
            attempt: busyToken0.attempt,
            peer: busyToken0.peer,
            endpointKey: busyToken0.endpointKey
        )
        let generationBeforeStale = busyDialCoordinator.generation
        expect(Policy.automaticDialDecision(
            token: staleBusyToken,
            tokenAccepted: busyDialCoordinator.accepts(staleBusyToken),
            busy: true,
            hasActiveConnection: true,
            pathSatisfied: true,
            currentPeer: nil,
            currentEndpointKey: nil
        ) == .ignore, "stale token 即使遇到 busy/activeConn 也只能忽略")
        expect(busyDialCoordinator.generation == generationBeforeStale
               && busyDialCoordinator.accepts(busyToken0),
               "stale token 决策不得污染当前 coordinator 状态")

        expect(Policy.automaticDialDecision(
            token: busyToken0,
            tokenAccepted: busyDialCoordinator.accepts(busyToken0),
            busy: true,
            hasActiveConnection: false,
            pathSatisfied: true,
            currentPeer: nil,
            currentEndpointKey: nil
        ) == .deferCurrentAttempt,
        "current token 被 pairing busy 阻挡时必须 deferred，不能消耗网络 attempt")
        expect(Policy.automaticDialDecision(
            token: busyToken0,
            tokenAccepted: busyDialCoordinator.accepts(busyToken0),
            busy: false,
            hasActiveConnection: true,
            pathSatisfied: true,
            currentPeer: peerRef,
            currentEndpointKey: "ep-1"
        ) == .deferCurrentAttempt,
        "current token 被临时 activeConn 阻挡时也必须 deferred")
        expect(Policy.automaticDialDecision(
            token: busyToken0,
            tokenAccepted: busyDialCoordinator.accepts(busyToken0),
            busy: false,
            hasActiveConnection: false,
            pathSatisfied: false,
            currentPeer: peerRef,
            currentEndpointKey: "ep-1"
        ) == .waitForEvent, "current token 遇到不可用 path 必须失效并等待网络事件")
        expect(Policy.automaticDialDecision(
            token: busyToken0,
            tokenAccepted: busyDialCoordinator.accepts(busyToken0),
            busy: false,
            hasActiveConnection: false,
            pathSatisfied: true,
            currentPeer: peerRef,
            currentEndpointKey: "ep-2"
        ) == .targetChanged, "同 peer 的非 nil 新 endpoint 必须立即切换新恢复周期")
        expect(Policy.automaticDialDecision(
            token: busyToken0,
            tokenAccepted: busyDialCoordinator.accepts(busyToken0),
            busy: false,
            hasActiveConnection: false,
            pathSatisfied: true,
            currentPeer: nil,
            currentEndpointKey: nil
        ) == .targetUnavailable, "peer/endpoint 真正缺失时必须等待新发现事件")

        expect(busyDialCoordinator.deferDial(busyToken0),
               "current dialing token 必须能进入 deferred phase")
        var startedAutomaticDials = 0
        for _ in 0..<(Coordinator.delays.count + 3) {
            expect(busyDialCoordinator.recoveryEvent(
                pathSatisfied: true,
                canDial: true,
                busy: true,
                endpointKey: "ep-1"
            ) == .none, "busy 超过全部旧退避窗口也不得产生 timer/dial")
            expect(busyDialCoordinator.deferredToken == busyToken0,
                   "busy 持续期间必须保留 exact deferred token")
            expect(busyDialCoordinator.deferredToken?.attempt == 0,
                   "未实际拨号不得消耗 attempt budget")
        }
        expect(startedAutomaticDials == 0, "busy 期间不得发起并发自动拨号")

        guard case let .dial(resumedBusyToken) = busyDialCoordinator.resumeDeferredRecovery(
            busyToken0,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) else { fail("pairing 失败释放后必须恢复一次") }
        startedAutomaticDials += 1
        expect(resumedBusyToken.attempt == 0,
               "deferred 释放后首次实际拨号仍必须是 attempt 0")
        expect(resumedBusyToken.generation != busyToken0.generation,
               "deferred 释放必须开启新 generation，隔离迟到回调")
        expect(busyDialCoordinator.resumeDeferredRecovery(
            busyToken0,
            pathSatisfied: true,
            canDial: true,
            endpointKey: "ep-1"
        ) == .none, "同一 release/token 只能恢复一次")
        expect(startedAutomaticDials == 1,
               "busy 失败释放后只能启动一个自动拨号")

        expect(Policy.mayResumeDeferredRecovery(
            tokenAccepted: true,
            servicesRunning: true,
            userStopped: false,
            busy: false,
            hasActiveConnection: false,
            hasActivePairing: false,
            hasActivePairingConnection: false,
            hasBoundConnection: false
        ), "未绑定临时会话完全释放后应允许消费 deferred token")
        expect(!Policy.mayResumeDeferredRecovery(
            tokenAccepted: false,
            servicesRunning: true,
            userStopped: false,
            busy: false,
            hasActiveConnection: false,
            hasActivePairing: false,
            hasActivePairingConnection: false,
            hasBoundConnection: false
        ), "stale deferred token 不得恢复")
        expect(!Policy.mayResumeDeferredRecovery(
            tokenAccepted: true,
            servicesRunning: false,
            userStopped: false,
            busy: false,
            hasActiveConnection: false,
            hasActivePairing: false,
            hasActivePairingConnection: false,
            hasBoundConnection: false
        ), "stop 后服务未运行不得恢复")
        expect(!Policy.mayResumeDeferredRecovery(
            tokenAccepted: true,
            servicesRunning: true,
            userStopped: true,
            busy: false,
            hasActiveConnection: false,
            hasActivePairing: false,
            hasActivePairingConnection: false,
            hasBoundConnection: false
        ), "用户 stop/disconnect 后不得恢复")
        expect(!Policy.mayResumeDeferredRecovery(
            tokenAccepted: true,
            servicesRunning: true,
            userStopped: false,
            busy: false,
            hasActiveConnection: true,
            hasActivePairing: false,
            hasActivePairingConnection: false,
            hasBoundConnection: true
        ), "成功 bound/active connection 必须由自身 drop 管理，不得恢复 deferred")
        expect(!Policy.mayResumeDeferredRecovery(
            tokenAccepted: true,
            servicesRunning: true,
            userStopped: false,
            busy: true,
            hasActiveConnection: false,
            hasActivePairing: true,
            hasActivePairingConnection: true,
            hasBoundConnection: false
        ), "pairing 尚未完全释放不得提前恢复")

        expect(Policy.actions(for: .pathUnavailable) == [
            .cancelRecovery,
            .invalidateForNetworkLoss,
            .cleanupCurrentConnection,
            .waitForEvent,
        ], "网络不可用动作顺序必须先失效、再清连接、最后等待")
        let restoreActions: [Policy.RecoveryAction] = [
            .repairListener,
            .reassertBonjour,
            .restartDiscovery,
            .requestRecovery,
        ]
        expect(Policy.actions(for: .pathRestored(reassertBonjour: true)) == restoreActions,
               "path restored 必须依次修 listener/广播/discovery/恢复")
        expect(Policy.actions(for: .initialSatisfied(reassertBonjour: true)) == restoreActions,
               "初始可用 path 必须走相同的恢复动作")
        let wakeWithoutReassert = Policy.actions(for: .wake(reassertBonjour: false))
        expect(wakeWithoutReassert.first == .repairListener,
               "wake 第一项必须修 listener")
        expect(wakeWithoutReassert.last == .requestRecovery,
               "wake 最后一项必须请求恢复")
        expect(!wakeWithoutReassert.contains(.reassertBonjour),
               "wake gate 未通过时不得重广播")
        expect(!wakeWithoutReassert.contains(.restartDiscovery),
               "wake gate 未通过时不得重启 discovery")

        expect(Policy.shouldReassertBonjour(last: nil, now: 100, minimumInterval: 3),
               "没有上次时间应允许重广播")
        expect(!Policy.shouldReassertBonjour(last: 100, now: 101, minimumInterval: 3),
               "未满最小间隔不得重广播")
        expect(Policy.shouldReassertBonjour(last: 100, now: 103, minimumInterval: 3),
               "达到最小间隔应允许重广播")

        expect(Policy.lifecycleActions(for: .stop, hasBoundConnection: true) == [
            .invalidateRecovery,
            .sendByeThenClose,
            .stopServices,
        ], "stop + bound 必须先失效恢复、发 bye 关闭、再停服务")
        expect(Policy.lifecycleActions(for: .disconnect, hasBoundConnection: true) == [
            .invalidateRecovery,
            .suppressCurrentPeer,
            .sendByeThenClose,
        ], "disconnect + bound 必须先失效、抑制当前 peer、再发 bye 关闭")
        expect(Policy.lifecycleActions(for: .stop, hasBoundConnection: false) == [
            .invalidateRecovery,
            .stopServices,
        ], "stop 无 bound 时不应发 bye，但必须保留其余语义")
        expect(Policy.lifecycleActions(for: .disconnect, hasBoundConnection: false) == [
            .invalidateRecovery,
            .suppressCurrentPeer,
        ], "disconnect 无 bound 时不应发 bye，但必须保留抑制语义")

        expect(Policy.inboundDecision(
            isPairedCodeless: true,
            locallyAllowed: false
        ) == .rejectAndCancel,
        "本机主动断开后即使 bye 丢失也必须拒绝免码入站")
        expect(Policy.inboundDecision(
            isPairedCodeless: true,
            locallyAllowed: true
        ) == .acceptCodeless,
        "未被本机抑制的已配对免码入站应直接接受")
        expect(Policy.inboundDecision(
            isPairedCodeless: false,
            locallyAllowed: false
        ) == .continuePairing,
        "未知设备首次配对不能被已配对 suppression 误伤")

        let staleBoundConnection = ConnectionProbe()
        let currentBoundConnection = ConnectionProbe()
        var staleByeCoordinator = Coordinator()
        staleByeCoordinator.connected(to: peerRef, endpointKey: "ep-new")
        let staleByeDecision = Policy.boundMessageDecision(
            source: staleBoundConnection,
            active: currentBoundConnection
        )
        expect(staleByeDecision == .ignoreStale,
               "superseded 旧连接的迟到 bye 必须按 exact identity 忽略")
        if staleByeDecision == .handle {
            staleByeCoordinator.peerSaidBye(peerRef)
        }
        expect(staleByeCoordinator.target == peerRef,
               "旧连接 bye 不得清除新会话 coordinator target")
        expect(Policy.boundMessageDecision(
            source: currentBoundConnection,
            active: currentBoundConnection
        ) == .handle, "当前 bound 连接的 bye 应正常处理")
        var currentByeCoordinator = Coordinator()
        currentByeCoordinator.connected(to: peerRef, endpointKey: "ep-current")
        if Policy.boundMessageDecision(
            source: currentBoundConnection,
            active: currentBoundConnection
        ) == .handle {
            currentByeCoordinator.peerSaidBye(peerRef)
        }
        expect(currentByeCoordinator.target == nil && currentByeCoordinator.allowsInbound(peerRef),
               "当前连接 bye 应停止恢复但不得加入本机 suppression")

        let rejectedConnection = ConnectionProbe()
        let rejectedLifecycle = Policy.InboundConnectionLifecycle(
            connection: rejectedConnection
        )
        expect(!rejectedLifecycle.rejectSilently(staleBoundConnection),
               "suppression 静默标记不得应用到其他 connection identity")
        expect(rejectedLifecycle.rejectSilently(rejectedConnection),
               "suppression reject 必须为 exact inbound connection 建立静默终态")
        var rejectedPresentation = ConnectionState.idle
        var rejectedFailurePublications = 0
        var rejectedRecoveryResumes = 0
        for event in Policy.InboundTerminalEvent.allCases {
            let decision = rejectedLifecycle.terminalDecision(
                for: event,
                source: rejectedConnection,
                activePairing: nil,
                activeBound: nil
            )
            switch decision {
            case .ignoreSilently, .ignoreStale:
                break
            case .finishPairingFailure:
                rejectedPresentation = .failed("pairing")
                rejectedRecoveryResumes += 1
            case .publishFailure:
                rejectedPresentation = .failed("unbound")
                rejectedFailurePublications += 1
            }
        }
        expect(rejectedPresentation == .idle,
               "rejected inbound 的 cancelled/failed/timeout 均不得污染 idle UI/Retry")
        expect(rejectedFailurePublications == 0 && rejectedRecoveryResumes == 0,
               "rejected inbound 不得发布失败或恢复 deferred/automatic")

        let repeatedRejectedConnection = ConnectionProbe()
        let repeatedRejectedLifecycle = Policy.InboundConnectionLifecycle(
            connection: repeatedRejectedConnection
        )
        expect(repeatedRejectedLifecycle.rejectSilently(repeatedRejectedConnection),
               "第二条 suppression reject 应与前一条连接独立")
        expect(repeatedRejectedLifecycle.terminalDecision(
            for: .cancelled,
            source: repeatedRejectedConnection,
            activePairing: nil,
            activeBound: nil
        ) == .ignoreSilently, "重复回连被拒绝后也必须静默收口")

        let normalPairingConnection = ConnectionProbe()
        let normalPairingLifecycle = Policy.InboundConnectionLifecycle(
            connection: normalPairingConnection
        )
        expect(normalPairingLifecycle.terminalDecision(
            for: .cancelled,
            source: normalPairingConnection,
            activePairing: normalPairingConnection,
            activeBound: nil
        ) == .finishPairingFailure,
        "未知设备的正常 pairing cancel 仍必须发布失败并释放 deferred")
        expect(normalPairingLifecycle.terminalDecision(
            for: .failed,
            source: normalPairingConnection,
            activePairing: nil,
            activeBound: nil
        ) == .ignoreStale, "同一正常 pairing 的重复终态必须幂等")

        expect(ConnectionState.connected(peerName: "B").isBusy, "connected 应 busy")
        expect(ConnectionState.connecting.isBusy, "connecting 应 busy")
        expect(ConnectionState.pairing.isBusy, "pairing 应 busy")
        expect(!ConnectionState.idle.isBusy, "idle 不应 busy")
        expect(!ConnectionState.failed("x").isBusy, "failed 不应 busy")

        let hostRequest = TransferManualRetryRequest(
            target: .host(host: "192.0.2.1", port: 6000),
            pairingCode: "654321"
        )
        expect(TransferManualRetryPolicy.afterSuccessfulBind(hostRequest) == .init(
            target: .host(host: "192.0.2.1", port: 6000),
            pairingCode: nil
        ), "host bind 成功后必须保留 host/port 并清 code")

        let peerRequest = TransferManualRetryRequest(
            target: .peer(peerRef),
            pairingCode: "654321"
        )
        expect(TransferManualRetryPolicy.afterSuccessfulBind(peerRequest) == .init(
            target: .peer(peerRef),
            pairingCode: nil
        ), "peer bind 成功后必须清 code")

        let oldDiscovered = peer(recoveryToken: "ep-old")
        let latestDiscovered = peer(recoveryToken: "ep-new")
        expect(TransferManualRetryPolicy.resolvePeer(
            peerRequest, discovered: [latestDiscovered]
        )?.reconnectEndpointKey == "ep-new", "Retry 必须从最新 discovered snapshot 解析 endpoint token")
        expect(TransferManualRetryPolicy.resolvePeer(
            peerRequest, discovered: [oldDiscovered]
        )?.reconnectEndpointKey == "ep-old", "每次解析都必须使用传入的当前 snapshot")
        expect(TransferManualRetryPolicy.resolvePeer(
            peerRequest, discovered: []
        ) == nil, "先前解析成功后也不得缓存旧 endpoint")
        expect(TransferManualRetryPolicy.resolvePeer(
            peerRequest, discovered: [peer("peer-X", "fp-B")]
        ) == nil, "deviceId 错误不得解析")
        expect(TransferManualRetryPolicy.resolvePeer(
            peerRequest, discovered: [peer("peer-B", "fp-X")]
        ) == nil, "fingerprint 错误不得解析")

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
