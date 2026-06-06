import Foundation
import Combine

public enum SettingsKey: String {
    case defaultOutputDir
    case autoCleanWorkspace
    case workspaceRetentionDays
    case logRetentionDays
    case recentFilesCap
    case launchRestoresLastTool
    case lastActiveTool
    case windowSize
    case sidebarWidth
    case enableExperimental
}

public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults
    private var subjects: [SettingsKey: PassthroughSubject<Void, Never>] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func string(_ key: SettingsKey) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    public func bool(_ key: SettingsKey) -> Bool {
        defaults.bool(forKey: key.rawValue)
    }

    public func int(_ key: SettingsKey) -> Int {
        defaults.integer(forKey: key.rawValue)
    }

    public func double(_ key: SettingsKey) -> Double {
        defaults.double(forKey: key.rawValue)
    }

    public func url(_ key: SettingsKey) -> URL? {
        guard let s = defaults.string(forKey: key.rawValue) else { return nil }
        return URL(string: s)
    }

    public func set(_ value: Any?, for key: SettingsKey) {
        if let v = value {
            defaults.set(v, forKey: key.rawValue)
        } else {
            defaults.removeObject(forKey: key.rawValue)
        }
        subjects[key, default: PassthroughSubject()].send()
    }

    public func publisher(for key: SettingsKey) -> AnyPublisher<Void, Never> {
        subjects[key, default: PassthroughSubject()].eraseToAnyPublisher()
    }

    public func resetAll() {
        for key in [SettingsKey.defaultOutputDir, .autoCleanWorkspace, .workspaceRetentionDays,
                    .logRetentionDays, .recentFilesCap, .launchRestoresLastTool,
                    .lastActiveTool, .windowSize, .sidebarWidth, .enableExperimental] {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
