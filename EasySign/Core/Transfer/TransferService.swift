import Foundation

/// 互传服务门面。Phase 1 期间逐步填实;Task 0 仅占位以打通接线。
final class TransferService: ObservableObject {
    let logger: LoggerService

    init(logger: LoggerService) {
        self.logger = logger
    }
}
