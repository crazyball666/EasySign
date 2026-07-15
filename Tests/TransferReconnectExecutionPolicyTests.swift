// swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors -module-cache-path /tmp/easysign-swift-module-cache EasySign/Core/Transfer/TransferModels.swift EasySign/Core/Transfer/TransferAutoReconnect.swift EasySign/Core/Transfer/TransferReconnectCoordinator.swift EasySign/Core/Transfer/TransferReconnectExecutionPolicy.swift Tests/TransferReconnectExecutionPolicyTests.swift -o /tmp/transfer-reconnect-execution-policy
// /tmp/transfer-reconnect-execution-policy

import Foundation
import Network

@main
struct TransferReconnectExecutionPolicyTests {
    typealias Coordinator = TransferReconnectCoordinator
    typealias Policy = TransferReconnectExecutionPolicy

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
