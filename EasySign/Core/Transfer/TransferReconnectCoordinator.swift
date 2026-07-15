import Foundation

struct TransferReconnectCoordinator {
    struct Token: Equatable {
        let generation: UInt
        let attempt: Int
        let peer: TransferAutoReconnect.PeerRef
        let endpointKey: String
    }

    enum Phase: Equatable {
        case inactive
        case dialing(Token)
        case waiting(Token)
        case waitingForEvent
    }

    enum Command: Equatable {
        case none
        case dial(Token)
        case schedule(Token, delay: TimeInterval)
        case waitForEvent
    }

    static let delays: [TimeInterval] = [0, 2, 5, 10]

    private(set) var generation: UInt = 0
    private(set) var phase: Phase = .inactive
    private(set) var target: TransferAutoReconnect.PeerRef?
    private(set) var endpointKey: String?
    private var suppressed = Set<TransferAutoReconnect.PeerRef>()

    mutating func connected(to peer: TransferAutoReconnect.PeerRef, endpointKey: String?) {
        target = peer
        self.endpointKey = endpointKey
        invalidateAutomaticRecovery(phase: .inactive)
    }

    mutating func unexpectedDrop(
        pathSatisfied: Bool,
        canDial: Bool,
        endpointKey: String?
    ) -> Command {
        guard let target, allowsInbound(target) else { return .none }
        return beginRecovery(
            peer: target,
            pathSatisfied: pathSatisfied,
            canDial: canDial,
            endpointKey: endpointKey
        )
    }

    mutating func recoveryEvent(
        pathSatisfied: Bool,
        canDial: Bool,
        busy: Bool,
        endpointKey: String?
    ) -> Command {
        guard let target, !busy, allowsInbound(target) else { return .none }

        switch phase {
        case let .dialing(token) where token.endpointKey == endpointKey:
            return .none
        case let .waiting(token) where token.endpointKey == endpointKey:
            return .none
        default:
            return beginRecovery(
                peer: target,
                pathSatisfied: pathSatisfied,
                canDial: canDial,
                endpointKey: endpointKey
            )
        }
    }

    mutating func peerBecameUnavailable() {
        endpointKey = nil
        invalidateAutomaticRecovery(phase: target == nil ? .inactive : .waitingForEvent)
    }

    mutating func attemptFailed(_ token: Token) -> Command {
        guard accepts(token), phase == .dialing(token) else { return .none }

        let nextAttempt = token.attempt + 1
        guard Self.delays.indices.contains(nextAttempt) else {
            phase = .waitingForEvent
            return .waitForEvent
        }

        let next = Token(
            generation: token.generation,
            attempt: nextAttempt,
            peer: token.peer,
            endpointKey: token.endpointKey
        )
        phase = .waiting(next)
        return .schedule(next, delay: Self.delays[nextAttempt])
    }

    mutating func delayElapsed(_ token: Token) -> Command {
        guard accepts(token), phase == .waiting(token) else { return .none }
        phase = .dialing(token)
        return .dial(token)
    }

    mutating func networkUnavailable() {
        invalidateAutomaticRecovery(phase: target == nil ? .inactive : .waitingForEvent)
    }

    mutating func userDisconnected(from peer: TransferAutoReconnect.PeerRef) {
        suppressed.insert(peer)
        stopTarget(peer)
    }

    mutating func peerSaidBye(_ peer: TransferAutoReconnect.PeerRef) {
        stopTarget(peer)
    }

    mutating func explicitlyConnecting(to peer: TransferAutoReconnect.PeerRef) {
        suppressed.remove(peer)
        cancelAutomaticRecovery()
    }

    mutating func cancelAutomaticRecovery() {
        invalidateAutomaticRecovery(phase: .inactive)
    }

    mutating func clearPeer(_ peer: TransferAutoReconnect.PeerRef) {
        suppressed.remove(peer)
        stopTarget(peer)
    }

    func allowsInbound(_ peer: TransferAutoReconnect.PeerRef) -> Bool {
        !suppressed.contains(peer)
    }

    func accepts(_ token: Token) -> Bool {
        token.generation == generation
            && token.peer == target
            && token.endpointKey == endpointKey
    }

    mutating func stop() {
        target = nil
        endpointKey = nil
        invalidateAutomaticRecovery(phase: .inactive)
    }

    private mutating func beginRecovery(
        peer: TransferAutoReconnect.PeerRef,
        pathSatisfied: Bool,
        canDial: Bool,
        endpointKey: String?
    ) -> Command {
        generation &+= 1
        self.endpointKey = endpointKey

        guard pathSatisfied, canDial, let endpointKey else {
            phase = .waitingForEvent
            return .waitForEvent
        }

        let token = Token(
            generation: generation,
            attempt: 0,
            peer: peer,
            endpointKey: endpointKey
        )
        phase = .dialing(token)
        return .dial(token)
    }

    private mutating func stopTarget(_ peer: TransferAutoReconnect.PeerRef) {
        guard target == peer else { return }
        target = nil
        endpointKey = nil
        invalidateAutomaticRecovery(phase: .inactive)
    }

    private mutating func invalidateAutomaticRecovery(phase: Phase) {
        generation &+= 1
        self.phase = phase
    }
}
