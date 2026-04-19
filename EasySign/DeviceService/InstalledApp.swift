import Foundation

struct InstalledApp: Identifiable, Hashable {
    let id: String  // Bundle ID
    let bundleID: String
    let name: String
    let version: String
    let buildVersion: String
    let signingInfo: SigningInfo
    let path: String
    let isSystemApp: Bool

    enum SigningInfo: String {
        case development = "Development"
        case distribution = "Distribution"
        case enterprise = "Enterprise"
        case unknown = "Unknown"
    }
}