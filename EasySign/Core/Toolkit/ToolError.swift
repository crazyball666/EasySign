import Foundation

public struct ToolError: Error, Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let underlying: Error?
    public let category: Category
    public let severity: Severity
    public let recoverySuggestion: String?

    public enum Category: String {
        case validation, signing, fileSystem, network, keychain
        case `internal`
    }

    public enum Severity: String {
        case info, warning, error, fatal
    }

    public init(title: String, message: String, underlying: Error? = nil,
                category: Category, severity: Severity, recoverySuggestion: String? = nil) {
        self.title = title
        self.message = message
        self.underlying = underlying
        self.category = category
        self.severity = severity
        self.recoverySuggestion = recoverySuggestion
    }
}
