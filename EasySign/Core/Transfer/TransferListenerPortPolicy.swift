import Network

/// Chooses the port for the next listener without owning any listener or scheduling state.
struct TransferListenerPortPolicy {
    enum FailureKind: Equatable {
        case addressInUse
        case other
    }

    enum BindingChoice: Equatable {
        case random
        case preferred(UInt16)
    }

    private(set) var preferredPort: UInt16?

    init(preferredPort: UInt16? = nil) {
        self.preferredPort = preferredPort.flatMap { $0 == 0 ? nil : $0 }
    }

    var nextBinding: BindingChoice {
        preferredPort.map(BindingChoice.preferred) ?? .random
    }

    mutating func listenerReady(port: UInt16) {
        guard port != 0 else { return }
        preferredPort = port
    }

    @discardableResult
    mutating func listenerFailed(requestedPort: UInt16?, kind: FailureKind) -> BindingChoice {
        if kind == .addressInUse,
           let requestedPort,
           requestedPort == preferredPort {
            preferredPort = nil
        }
        return nextBinding
    }

    static func failureKind(for error: NWError) -> FailureKind {
        if case .posix(.EADDRINUSE) = error {
            return .addressInUse
        }
        return .other
    }
}
