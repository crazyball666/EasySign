import Foundation

enum TransferConnectionOrigin: Equatable {
    case user
    case automatic(TransferReconnectCoordinator.Token)

    func pairingCode(requested: String?) -> String? {
        switch self {
        case .user:
            requested
        case .automatic:
            nil
        }
    }

    var expectedFingerprint: String? {
        switch self {
        case .user:
            nil
        case let .automatic(token):
            token.peer.fingerprint
        }
    }
}

enum TransferReconnectExecutionPolicy {
    enum CompletionDecision: Equatable {
        case ignore
        case cleanupOnly
        case cleanupAndRetry
    }

    enum RecoveryEvent: Equatable {
        case pathUnavailable
        case pathRestored(reassertBonjour: Bool)
        case initialSatisfied(reassertBonjour: Bool)
        case wake(reassertBonjour: Bool)
    }

    enum RecoveryAction: Equatable {
        case cancelRecovery
        case invalidateForNetworkLoss
        case cleanupCurrentConnection
        case waitForEvent
        case repairListener
        case reassertBonjour
        case restartDiscovery
        case requestRecovery
    }

    enum LifecycleEvent: Equatable {
        case stop
        case disconnect
    }

    enum LifecycleAction: Equatable {
        case invalidateRecovery
        case suppressCurrentPeer
        case sendByeThenClose
        case stopServices
    }

    static func mayStartAutomatic(
        token: TransferReconnectCoordinator.Token,
        tokenAccepted: Bool,
        busy: Bool,
        hasActiveConnection: Bool,
        pathSatisfied: Bool,
        currentPeer: TransferAutoReconnect.PeerRef?,
        currentEndpointKey: String?
    ) -> Bool {
        tokenAccepted
            && !busy
            && !hasActiveConnection
            && pathSatisfied
            && currentPeer == token.peer
            && currentEndpointKey == token.endpointKey
    }

    static func readyPeerMatches(
        token: TransferReconnectCoordinator.Token,
        actual: PairedPeer
    ) -> Bool {
        token.peer.deviceId == actual.deviceId
            && token.peer.fingerprint == actual.fingerprint
    }

    static func completionDecision(
        attemptMatches: Bool,
        connectionMatches: Bool,
        tokenAccepted: Bool
    ) -> CompletionDecision {
        guard attemptMatches, connectionMatches else { return .ignore }
        return tokenAccepted ? .cleanupAndRetry : .cleanupOnly
    }

    static func actions(for event: RecoveryEvent) -> [RecoveryAction] {
        switch event {
        case .pathUnavailable:
            return [
                .cancelRecovery,
                .invalidateForNetworkLoss,
                .cleanupCurrentConnection,
                .waitForEvent,
            ]
        case let .pathRestored(reassertBonjour),
             let .initialSatisfied(reassertBonjour),
             let .wake(reassertBonjour):
            var actions: [RecoveryAction] = [.repairListener]
            if reassertBonjour {
                actions.append(.reassertBonjour)
                actions.append(.restartDiscovery)
            }
            actions.append(.requestRecovery)
            return actions
        }
    }

    static func lifecycleActions(
        for event: LifecycleEvent,
        hasBoundConnection: Bool
    ) -> [LifecycleAction] {
        var actions: [LifecycleAction] = [.invalidateRecovery]
        if event == .disconnect {
            actions.append(.suppressCurrentPeer)
        }
        if hasBoundConnection {
            actions.append(.sendByeThenClose)
        }
        if event == .stop {
            actions.append(.stopServices)
        }
        return actions
    }

    static func shouldReassertBonjour(
        last: TimeInterval?,
        now: TimeInterval,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard let last else { return true }
        return now - last >= minimumInterval
    }
}

extension ConnectionState {
    var isBusy: Bool {
        switch self {
        case .connected, .connecting, .pairing:
            true
        case .idle, .failed:
            false
        }
    }
}

enum TransferManualRetryTarget: Equatable {
    case host(host: String, port: UInt16)
    case peer(TransferAutoReconnect.PeerRef)
}

struct TransferManualRetryRequest: Equatable {
    let target: TransferManualRetryTarget
    let pairingCode: String?
}

enum TransferManualRetryPolicy {
    static func afterSuccessfulBind(
        _ request: TransferManualRetryRequest
    ) -> TransferManualRetryRequest {
        TransferManualRetryRequest(target: request.target, pairingCode: nil)
    }

    static func resolvePeer(
        _ request: TransferManualRetryRequest,
        discovered: [DiscoveredPeer]
    ) -> DiscoveredPeer? {
        guard case let .peer(peerRef) = request.target else { return nil }
        return discovered.first {
            $0.deviceId == peerRef.deviceId
                && $0.fingerprint == peerRef.fingerprint
        }
    }
}
