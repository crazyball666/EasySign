import Foundation

// MARK: - AFC C API Declarations

@_silgen_name("AFCDirectoryOpen")
func AFCDirectoryOpen(_ connection: AFCConnectionRef, _ path: String, _ dirRef: UnsafeMutablePointer<AFCDirectoryRef?>) -> Int32

@_silgen_name("AFCDirectoryRead")
func AFCDirectoryRead(_ connection: AFCConnectionRef, _ dirRef: AFCDirectoryRef, _ entry: UnsafeMutablePointer<AFCFileInfoPointer?>?) -> UnsafeMutablePointer<AFCFileInfoStruct>?

@_silgen_name("AFCDirectoryClose")
func AFCDirectoryClose(_ connection: AFCConnectionRef, _ dirRef: AFCDirectoryRef) -> Int32

@_silgen_name("AFCDirectoryCreate")
func AFCDirectoryCreate(_ connection: AFCConnectionRef, _ path: String) -> Int32

@_silgen_name("AFCFileRefOpen")
func AFCFileRefOpen(_ connection: AFCConnectionRef, _ path: String, _ openFlags: UInt32, _ fileRef: UnsafeMutablePointer<AFCFileRef?>) -> Int32

@_silgen_name("AFCFileRefRead")
func AFCFileRefRead(_ connection: AFCConnectionRef, _ fileRef: AFCFileRef, _ buffer: UnsafeMutableRawPointer, _ bytesRead: UnsafeMutablePointer<UInt32>?) -> Int32

@_silgen_name("AFCFileRefWrite")
func AFCFileRefWrite(_ connection: AFCConnectionRef, _ fileRef: AFCFileRef, _ buffer: UnsafeRawPointer, _ bytesToWrite: UInt32) -> Int32

@_silgen_name("AFCFileRefClose")
func AFCFileRefClose(_ connection: AFCConnectionRef, _ fileRef: AFCFileRef) -> Int32

@_silgen_name("AFCRemovePath")
func AFCRemovePath(_ connection: AFCConnectionRef, _ path: String) -> Int32

// MARK: - AFC Type Aliases

typealias AFCDirectoryRef = UnsafeMutableRawPointer
typealias AFCFileRef = UnsafeMutableRawPointer

// AFCFileInfoStruct matches the C struct returned by AFCDirectoryRead
// The struct contains file information returned by AFC directory listing
struct AFCFileInfoStruct {
    var name: UnsafeMutablePointer<CChar>?
    var link: UnsafeMutablePointer<CChar>?  // symlink target if applicable
    var size: UInt64
    var type: UInt64  // file type info (similar to st_mode)
}

typealias AFCFileInfoPointer = AFCFileInfoStruct

// MARK: - AFC Constants

let AFCSUCCESS: Int32 = 0
let AFCDirectoryType: UInt64 = 0x1000 // S_IFDIR - directory type flag

// MARK: - AFC Errors

enum AFCError: LocalizedError {
    case deviceNotConnected
    case connectionFailed
    case notConnected
    case directoryOpenFailed
    case fileOpenFailed
    case readFailed
    case writeFailed
    case deleteFailed
    case createDirectoryFailed

    var errorDescription: String? {
        switch self {
        case .deviceNotConnected:
            return "Device is not connected"
        case .connectionFailed:
            return "Failed to establish AFC connection"
        case .notConnected:
            return "AFC client is not connected"
        case .directoryOpenFailed:
            return "Failed to open directory"
        case .fileOpenFailed:
            return "Failed to open file"
        case .readFailed:
            return "Failed to read file"
        case .writeFailed:
            return "Failed to write file"
        case .deleteFailed:
            return "Failed to delete file"
        case .createDirectoryFailed:
            return "Failed to create directory"
        }
    }
}

// MARK: - AFCClient

final class AFCClient {
    private var connection: AFCConnectionRef?
    private let device: Device

    init(device: Device) throws {
        self.device = device
        try openConnection()
    }

    deinit {
        closeConnection()
    }

    // MARK: - Connection

    private func openConnection() throws {
        guard let deviceRef = DeviceManager.shared.getConnectedDeviceRef(for: device.id) else {
            throw AFCError.deviceNotConnected
        }

        var conn: AFCConnectionRef?
        // 启动 AFC 服务获取 connection
        let serviceName = "com.apple.afc" as CFString
        let result = AMDeviceStartService(deviceRef, serviceName, &conn, nil)

        guard result == AMDAppLEDETECT_SUCCESS, let connection = conn else {
            throw AFCError.connectionFailed
        }

        self.connection = connection
    }

    private func closeConnection() {
        if let conn = connection {
            _ = AFCConnectionClose(conn)
            connection = nil
        }
    }

    // MARK: - Directory Operations

    func listDirectory(at path: String) throws -> [FileNode] {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        var dirRef: AFCDirectoryRef?
        let openResult = AFCDirectoryOpen(conn, path, &dirRef)
        guard openResult == AFCSUCCESS, let dir = dirRef else {
            throw AFCError.directoryOpenFailed
        }

        defer { _ = AFCDirectoryClose(conn, dir) }

        var nodes: [FileNode] = []
        while true {
            guard let entry = AFCDirectoryRead(conn, dir, nil) else { break }

            let namePointer = entry.pointee.name!
            let name = String(cString: namePointer)
            let fullPath = (path as NSString).appendingPathComponent(name)

            // Skip "." and ".." entries
            if name == "." || name == ".." {
                continue
            }

            let isDirectory = (entry.pointee.type & 0x1000) != 0
            let size = entry.pointee.size

            let node = FileNode(
                id: fullPath,
                name: name,
                path: fullPath,
                isDirectory: isDirectory,
                size: size,
                modificationDate: nil,  // AFCDirectoryRead doesn't provide mtime
                fileType: guessFileType(name: name, isDirectory: isDirectory)
            )
            nodes.append(node)
        }

        return nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - File Operations

    func readFile(at path: String, offset: UInt64 = 0, length: UInt64 = 0) throws -> Data {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        var fileRef: AFCFileRef?
        let openFlags: UInt32 = 0x0001  // O_RDONLY
        let openResult = AFCFileRefOpen(conn, path, openFlags, &fileRef)
        guard openResult == AFCSUCCESS, let ref = fileRef else {
            throw AFCError.fileOpenFailed
        }

        defer { _ = AFCFileRefClose(conn, ref) }

        // 读取文件内容
        let bufferSize = length > 0 ? length : 1024 * 1024  // 默认 1MB
        var buffer = [UInt8](repeating: 0, count: Int(bufferSize))
        var bytesRead: UInt32 = 0

        let readResult = AFCFileRefRead(conn, ref, &buffer, &bytesRead)
        guard readResult == AFCSUCCESS else {
            throw AFCError.readFailed
        }

        return Data(buffer.prefix(Int(bytesRead)))
    }

    func writeFile(at path: String, data: Data) throws {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        var fileRef: AFCFileRef?
        let openFlags: UInt32 = 0x0002  // O_WRONLY | O_CREAT | O_TRUNC
        let openResult = AFCFileRefOpen(conn, path, openFlags, &fileRef)
        guard openResult == AFCSUCCESS, let ref = fileRef else {
            throw AFCError.fileOpenFailed
        }

        defer { _ = AFCFileRefClose(conn, ref) }

        let writeResult = data.withUnsafeBytes { ptr -> Int32 in
            AFCFileRefWrite(conn, ref, ptr.baseAddress!, UInt32(data.count))
        }

        guard writeResult == AFCSUCCESS else {
            throw AFCError.writeFailed
        }
    }

    func deleteFile(at path: String) throws {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        let result = AFCRemovePath(conn, path)
        guard result == AFCSUCCESS else {
            throw AFCError.deleteFailed
        }
    }

    func createDirectory(at path: String) throws {
        guard let conn = connection else {
            throw AFCError.notConnected
        }

        let result = AFCDirectoryCreate(conn, path)
        guard result == AFCSUCCESS else {
            throw AFCError.createDirectoryFailed
        }
    }

    // MARK: - Helper Methods

    private func guessFileType(name: String, isDirectory: Bool) -> FileNode.FileType {
        if isDirectory {
            return .directory
        }

        let ext = (name as NSString).pathExtension.lowercased()

        switch ext {
        case "txt", "text", "md", "rtf", "h", "m", "swift", "c", "cpp", "hpp", "java", "py", "js", "ts", "html", "css", "xml", "yaml", "yml":
            return .text
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "svg", "ico", "webp":
            return .image
        case "db", "sqlite", "sqlite3", "mdb":
            return .database
        case "plist":
            return .plist
        case "json":
            return .json
        default:
            return .other
        }
    }
}
