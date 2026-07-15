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
    struct ServiceGeneration {
        private(set) var current: UInt = 0
        private(set) var runningGeneration: UInt?

        var isRunning: Bool {
            runningGeneration != nil
        }

        mutating func begin() -> UInt {
            current &+= 1
            runningGeneration = nil
            return current
        }

        @discardableResult
        mutating func activate(_ generation: UInt) -> Bool {
            guard generation == current else { return false }
            runningGeneration = generation
            return true
        }

        mutating func stop() {
            current &+= 1
            runningGeneration = nil
        }

        func acceptsEvent(_ generation: UInt) -> Bool {
            runningGeneration == generation
        }
    }

    enum BoundMessageDecision: Equatable {
        case handle
        case ignoreStale
    }

    enum InboundDecision: Equatable {
        case rejectAndCancel
        case acceptCodeless
        case continuePairing
    }

    enum InboundPairingBlockerDecision: Equatable {
        case none
        case rejectInboundPreserveUserAttempt
        case invalidateRecoveryOnly
        case invalidateAndCancelAutomaticAttempt
    }

    enum InboundPairingBlockerReleaseDecision: Equatable {
        case ignore
        case resumeDeferred(TransferReconnectCoordinator.Token)
        case requestRecoveryEvent
    }

    /// Tracks the exact inbound connection which temporarily blocked automatic recovery.
    /// Production confines mutations to main; identity matching also makes terminal delivery
    /// idempotent and prevents a superseded inbound connection from releasing a newer blocker.
    final class InboundPairingBlockerLifecycle: @unchecked Sendable {
        private let connectionID: ObjectIdentifier
        private var active = true

        init(connection: AnyObject) {
            connectionID = ObjectIdentifier(connection)
        }

        @discardableResult
        func consumeRelease(_ connection: AnyObject) -> Bool {
            consume(connection)
        }

        @discardableResult
        func consumeWithoutRecovery(_ connection: AnyObject) -> Bool {
            consume(connection)
        }

        func invalidate() {
            active = false
        }

        private func consume(_ connection: AnyObject) -> Bool {
            guard active,
                  ObjectIdentifier(connection) == connectionID else { return false }
            active = false
            return true
        }
    }

    enum AutomaticReadyDecision: Equatable {
        case bind
        case cleanupStale
    }

    enum InboundTerminalEvent: CaseIterable, Equatable {
        case failed
        case cancelled
        case timeout
    }

    enum InboundTerminalDecision: Equatable {
        case ignoreSilently
        case ignoreStale
        case finishPairingFailure
        case publishFailure
    }

    /// One reducer is created per accepted inbound connection. Production confines mutations to main.
    final class InboundConnectionLifecycle: @unchecked Sendable {
        private enum State {
            case ordinary
            case silentlyRejected
            case cancelledByUser
            case finished
        }

        private let connectionID: ObjectIdentifier
        private var state = State.ordinary

        init(connection: AnyObject) {
            connectionID = ObjectIdentifier(connection)
        }

        @discardableResult
        func rejectSilently(_ connection: AnyObject) -> Bool {
            guard matches(connection), state == .ordinary else { return false }
            state = .silentlyRejected
            return true
        }

        @discardableResult
        func cancelForUserDisconnect(_ connection: AnyObject) -> Bool {
            guard matches(connection), state == .ordinary else { return false }
            state = .cancelledByUser
            return true
        }

        func terminalDecision(
            for event: InboundTerminalEvent,
            source: AnyObject,
            activePairing: AnyObject?,
            activeBound: AnyObject?
        ) -> InboundTerminalDecision {
            guard matches(source) else { return .ignoreStale }
            switch state {
            case .silentlyRejected, .cancelledByUser:
                return .ignoreSilently
            case .finished:
                return .ignoreStale
            case .ordinary:
                break
            }

            // Failed, cancelled, and the 30-second timeout share one idempotent terminal gate.
            switch event {
            case .failed, .cancelled, .timeout:
                break
            }
            let decision: InboundTerminalDecision
            if let activePairing {
                decision = matches(activePairing) ? .finishPairingFailure : .ignoreStale
            } else if activeBound == nil {
                decision = .publishFailure
            } else {
                decision = .ignoreStale
            }
            state = .finished
            return decision
        }

        private func matches(_ connection: AnyObject) -> Bool {
            ObjectIdentifier(connection) == connectionID
        }
    }

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
        case silenceInboundPairingTerminal
        case invalidateRecovery
        case suppressCurrentPeer
        case sendByeThenClose
        case stopServices
    }

    enum DiscoveryEndpointAction: Equatable {
        case invalidateAutomaticRecovery
        case cleanupAutomaticAttempt
        case recordBoundEndpoint
        case requestRecovery
    }

    enum DiscoverySessionDisposition: Equatable {
        case manual
        case transientBusy
        case bound
        case automatic
        case idle

        var preservesPresentation: Bool {
            switch self {
            case .manual, .transientBusy, .bound:
                true
            case .automatic, .idle:
                false
            }
        }

        var allowsAutomaticRecovery: Bool {
            switch self {
            case .automatic, .idle:
                true
            case .manual, .transientBusy, .bound:
                false
            }
        }

        var allowsAutomaticAttemptCleanup: Bool {
            self == .automatic
        }
    }

    enum AutomaticDialDecision: Equatable {
        case start
        case ignore
        case deferCurrentAttempt
        case targetChanged
        case targetUnavailable
        case waitForEvent
    }

    static func allowsSessionActivity(
        servicesRunning: Bool,
        stopRequested: Bool
    ) -> Bool {
        servicesRunning && !stopRequested
    }

    static func inboundPairingBlockerDecision(
        requiresPairing: Bool,
        activeOrigin: TransferConnectionOrigin?
    ) -> InboundPairingBlockerDecision {
        guard requiresPairing else { return .none }
        if activeOrigin == .user {
            return .rejectInboundPreserveUserAttempt
        }
        if case .automatic = activeOrigin {
            return .invalidateAndCancelAutomaticAttempt
        }
        return .invalidateRecoveryOnly
    }

    static func inboundPairingBlockerReleaseDecision(
        deferredToken: TransferReconnectCoordinator.Token?,
        deferredTokenAccepted: Bool,
        servicesRunning: Bool,
        userStopped: Bool,
        hasUserAttempt: Bool,
        busy: Bool,
        hasActiveConnection: Bool,
        hasActivePairing: Bool,
        hasActivePairingConnection: Bool,
        hasBoundConnection: Bool
    ) -> InboundPairingBlockerReleaseDecision {
        guard servicesRunning,
              !userStopped,
              !hasUserAttempt,
              !busy,
              !hasActiveConnection,
              !hasActivePairing,
              !hasActivePairingConnection,
              !hasBoundConnection else { return .ignore }
        if let deferredToken, deferredTokenAccepted {
            return .resumeDeferred(deferredToken)
        }
        return .requestRecoveryEvent
    }

    static func automaticReadyDecision(
        tokenAccepted: Bool,
        hasConcurrentPairingConnection: Bool
    ) -> AutomaticReadyDecision {
        tokenAccepted && !hasConcurrentPairingConnection ? .bind : .cleanupStale
    }

    static func shouldPublishAutomaticCompletion(
        hasConcurrentPairingConnection: Bool
    ) -> Bool {
        !hasConcurrentPairingConnection
    }

    static func discoverySessionDisposition(
        connectionState: ConnectionState,
        hasBoundConnection: Bool,
        activeOrigin: TransferConnectionOrigin?,
        hasActivePairingConnection: Bool
    ) -> DiscoverySessionDisposition {
        if hasBoundConnection { return .bound }
        if activeOrigin == .user { return .manual }
        if hasActivePairingConnection || connectionState == .pairing {
            return .transientBusy
        }
        if case .automatic = activeOrigin { return .automatic }
        if connectionState.isBusy { return .transientBusy }
        return .idle
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
        automaticDialDecision(
            token: token,
            tokenAccepted: tokenAccepted,
            busy: busy,
            hasActiveConnection: hasActiveConnection,
            pathSatisfied: pathSatisfied,
            currentPeer: currentPeer,
            currentEndpointKey: currentEndpointKey
        ) == .start
    }

    static func automaticDialDecision(
        token: TransferReconnectCoordinator.Token,
        tokenAccepted: Bool,
        busy: Bool,
        hasActiveConnection: Bool,
        pathSatisfied: Bool,
        currentPeer: TransferAutoReconnect.PeerRef?,
        currentEndpointKey: String?
    ) -> AutomaticDialDecision {
        guard tokenAccepted else { return .ignore }
        if busy || hasActiveConnection { return .deferCurrentAttempt }
        guard pathSatisfied else { return .waitForEvent }
        guard currentPeer == token.peer else { return .targetUnavailable }
        guard let currentEndpointKey else { return .targetUnavailable }
        guard currentEndpointKey == token.endpointKey else { return .targetChanged }
        return .start
    }

    static func mayResumeDeferredRecovery(
        tokenAccepted: Bool,
        servicesRunning: Bool,
        userStopped: Bool,
        busy: Bool,
        hasActiveConnection: Bool,
        hasActivePairing: Bool,
        hasActivePairingConnection: Bool,
        hasBoundConnection: Bool
    ) -> Bool {
        tokenAccepted
            && servicesRunning
            && !userStopped
            && !busy
            && !hasActiveConnection
            && !hasActivePairing
            && !hasActivePairingConnection
            && !hasBoundConnection
    }

    static func readyPeerMatches(
        token: TransferReconnectCoordinator.Token,
        actual: PairedPeer
    ) -> Bool {
        token.peer.deviceId == actual.deviceId
            && token.peer.fingerprint == actual.fingerprint
    }

    static func inboundDecision(
        isPairedCodeless: Bool,
        locallyAllowed: Bool
    ) -> InboundDecision {
        guard isPairedCodeless else { return .continuePairing }
        return locallyAllowed ? .acceptCodeless : .rejectAndCancel
    }

    static func boundMessageDecision(
        source: AnyObject,
        active: AnyObject?
    ) -> BoundMessageDecision {
        guard let active else { return .ignoreStale }
        return ObjectIdentifier(source) == ObjectIdentifier(active) ? .handle : .ignoreStale
    }

    static func completionDecision(
        attemptMatches: Bool,
        connectionMatches: Bool,
        tokenAccepted: Bool
    ) -> CompletionDecision {
        guard attemptMatches, connectionMatches else { return .ignore }
        return tokenAccepted ? .cleanupAndRetry : .cleanupOnly
    }

    static func discoveryEndpointActions(
        oldEndpointKey: String?,
        newEndpointKey: String?,
        hasBoundConnection: Bool,
        hasActiveAutomaticAttempt: Bool
    ) -> [DiscoveryEndpointAction] {
        guard let newEndpointKey,
              newEndpointKey != oldEndpointKey else { return [] }
        if hasBoundConnection {
            return [.recordBoundEndpoint, .requestRecovery]
        }
        if hasActiveAutomaticAttempt {
            return [
                .invalidateAutomaticRecovery,
                .cleanupAutomaticAttempt,
                .requestRecovery,
            ]
        }
        return [.requestRecovery]
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
        var actions: [LifecycleAction] = []
        if event == .disconnect {
            actions.append(.silenceInboundPairingTerminal)
        }
        actions.append(.invalidateRecovery)
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
