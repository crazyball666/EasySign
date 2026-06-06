import Foundation

public struct ResignArtifact: Identifiable, Codable {
    public let id: UUID
    public let runId: UUID
    public let startedAt: Date
    public let finishedAt: Date?
    public let inputIPA: URL?
    public let outputIPA: URL?
    public let logPath: URL
    public let workspacePath: URL
    public let status: Status
    public let tool: String
    public let summary: String

    public enum Status: String, Codable {
        case running, success, failure, canceled
    }
}
