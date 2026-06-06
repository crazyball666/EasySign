import Foundation

public struct InstallEvent {
    public let stage: String
    public let progress: Double
    public let message: String?

    public init(stage: String, progress: Double, message: String? = nil) {
        self.stage = stage
        self.progress = progress
        self.message = message
    }
}
