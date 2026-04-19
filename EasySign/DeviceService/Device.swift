import Foundation

struct Device: Identifiable, Hashable {
    let id: String  // UDID
    let name: String
    let model: String
    let systemVersion: String
    let deviceClass: DeviceClass

    enum DeviceClass: String {
        case iPhone
        case iPad
        case iPod
        case unknown
    }

    var displayName: String {
        "\(name) (\(systemVersion))"
    }
}