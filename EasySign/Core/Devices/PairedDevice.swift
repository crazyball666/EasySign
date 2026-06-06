import Foundation

public struct PairedDevice: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let model: String
    public let osVersion: String
}
