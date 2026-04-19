import Foundation

struct FileNode: Identifiable, Hashable {
    let id: String  // 完整路径
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modificationDate: Date?
    let fileType: FileType

    enum FileType: String {
        case directory
        case text
        case image
        case database
        case plist
        case json
        case other
    }
}
