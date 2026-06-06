import Foundation

// MARK: - AFC Errors

enum AFCError: LocalizedError {
    case deviceNotConnected
    case connectionFailed
    case notConnected
    case listFailed(Error)
    case fileOpenFailed(Error)
    case readFailed(Error)
    case writeFailed(Error)
    case deleteFailed(Error)
    case createDirectoryFailed(Error)
    case renameFailed(Error)
    case localOpenFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceNotConnected:           return "Device is not connected"
        case .connectionFailed:             return "Failed to establish AFC connection"
        case .notConnected:                 return "AFC client is not connected"
        case .listFailed(let e):            return "Failed to list directory: \(e.localizedDescription)"
        case .fileOpenFailed(let e):        return "Failed to open file: \(e.localizedDescription)"
        case .readFailed(let e):            return "Failed to read file: \(e.localizedDescription)"
        case .writeFailed(let e):           return "Failed to write file: \(e.localizedDescription)"
        case .deleteFailed(let e):          return "Failed to delete: \(e.localizedDescription)"
        case .createDirectoryFailed(let e): return "Failed to create directory: \(e.localizedDescription)"
        case .renameFailed(let e):          return "Failed to rename/move: \(e.localizedDescription)"
        case .localOpenFailed(let r):       return "Failed to open local file: \(r)"
        }
    }
}

// MARK: - AFCClient
//
// High-level AFC API that talks the AFC packet protocol via AFCSession.
//
// Two service variants, both over AFCServiceConnectionTransport (an
// AMDServiceConnection from AMDeviceSecureStartService):
//   - Media (com.apple.afc): not encrypted, but the service connection works
//     just the same.
//   - App sandbox (com.apple.mobile.house_arrest): SSL-wrapped; the service
//     connection applies the SSL session transparently.
//
// All AFC operations (listDirectory / readFile / writeFile / streamFile /
// uploadFile / copyFile / move / delete / makeDir / fileSize / exists) go
// through AFCSession, which handles framing and SSL transparently per
// transport.
final class AFCClient {
    private let device: Device
    private var session: AFCSession?

    // MARK: - Init

    // Browses the device-wide Media partition (DCIM/Books/Downloads/…).
    init(device: Device) throws {
        self.device = device
        self.session = try Self.makeMediaSession(device: device)
    }

    // Browses a single app's sandbox container via com.apple.mobile.house_arrest.
    // Tries VendContainer (full container) first, falls back to VendDocuments.
    init(device: Device, bundleID: String) throws {
        self.device = device
        self.session = try Self.makeSandboxSession(device: device, bundleID: bundleID)
    }

    // MARK: - Session construction

    private static func makeMediaSession(device: Device) throws -> AFCSession {
        guard let deviceRef = DeviceManager.shared.getConnectedDeviceRef(for: device.id) else {
            throw AFCError.deviceNotConnected
        }
        // Use the secure-start path (same as house_arrest) and route AFC packets
        // through the AMDServiceConnection. com.apple.afc isn't SSL-encrypted, so
        // this adds no overhead, but it gives us a real byte channel instead of
        // trying (incorrectly) to reinterpret an AFCConnectionRef pointer as a
        // socket fd.
        var serviceConn: AMDServiceConnectionRef?
        let startResult = AMDeviceSecureStartService(
            deviceRef,
            "com.apple.afc" as CFString,
            nil,
            &serviceConn
        )
        guard startResult == AMDAppLEDETECT_SUCCESS, let conn = serviceConn else {
            throw AFCError.connectionFailed
        }
        return AFCSession(transport: AFCServiceConnectionTransport(connection: conn))
    }

    private static func makeSandboxSession(device: Device, bundleID: String) throws -> AFCSession {
        guard let deviceRef = DeviceManager.shared.getConnectedDeviceRef(for: device.id) else {
            throw AFCError.deviceNotConnected
        }
        do {
            let transport = try HouseArrestClient.openTransport(
                deviceRef: deviceRef, bundleID: bundleID, command: .vendContainer)
            return AFCSession(transport: transport)
        } catch {
            // VendContainer failed (often: no get-task-allow). Try VendDocuments.
            let transport = try HouseArrestClient.openTransport(
                deviceRef: deviceRef, bundleID: bundleID, command: .vendDocuments)
            return AFCSession(transport: transport)
        }
    }

    // MARK: - Directory operations

    func listDirectory(at path: String) throws -> [FileNode] {
        guard let session = session else { throw AFCError.notConnected }
        let names: [String]
        do {
            names = try session.listDirectory(at: path)
        } catch {
            throw AFCError.listFailed(error)
        }

        var nodes: [FileNode] = []
        for name in names where name != "." && name != ".." {
            let fullPath = (path as NSString).appendingPathComponent(name)
            let info: (isDirectory: Bool, size: UInt64) =
                (try? readFileInfo(session: session, path: fullPath)) ?? (false, 0)
            nodes.append(FileNode(
                id: fullPath,
                name: name,
                path: fullPath,
                isDirectory: info.isDirectory,
                size: info.size,
                modificationDate: nil,
                fileType: guessFileType(name: name, isDirectory: info.isDirectory)
            ))
        }
        return nodes.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fileSize(at path: String) throws -> UInt64 {
        guard let session = session else { throw AFCError.notConnected }
        let info = try readFileInfo(session: session, path: path)
        return info.size
    }

    func exists(at path: String) -> Bool {
        guard let session = session else { return false }
        return (try? session.getFileInfo(at: path)) != nil
    }

    // MARK: - File operations

    private static let readChunkSize: UInt64 = 1024 * 1024

    // Reads up to `maxBytes` bytes (0 = unlimited). AFC FILE_READ returns
    // whatever the device sends per packet — keep looping until EOF or cap.
    func readFile(at path: String, maxBytes: UInt64 = 0) throws -> Data {
        guard let session = session else { throw AFCError.notConnected }

        let handle: UInt64
        do {
            handle = try session.fileOpen(at: path, mode: AFCFileMode.readOnly)
        } catch {
            throw AFCError.fileOpenFailed(error)
        }
        defer { try? session.fileClose(handle: handle) }

        var collected = Data()
        while maxBytes == 0 || UInt64(collected.count) < maxBytes {
            let want: UInt64 = {
                if maxBytes == 0 { return Self.readChunkSize }
                return min(Self.readChunkSize, maxBytes - UInt64(collected.count))
            }()
            let chunk: Data
            do {
                chunk = try session.fileRead(handle: handle, length: want)
            } catch {
                throw AFCError.readFailed(error)
            }
            if chunk.isEmpty { break }
            collected.append(chunk)
        }
        return collected
    }

    // Streams to a local URL without buffering the whole file in memory.
    // Optional progress callback receives (bytesWritten, totalSize?).
    func streamFile(
        at path: String,
        to localURL: URL,
        progress: ((UInt64, UInt64?) -> Void)? = nil
    ) throws {
        guard let session = session else { throw AFCError.notConnected }
        let totalSize = (try? fileSize(at: path)).flatMap { $0 > 0 ? $0 : nil }

        let handle: UInt64
        do {
            handle = try session.fileOpen(at: path, mode: AFCFileMode.readOnly)
        } catch {
            throw AFCError.fileOpenFailed(error)
        }
        defer { try? session.fileClose(handle: handle) }

        // Local file handle (overwrite).
        let parent = localURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: localURL)
        defer { try? outHandle.close() }

        var written: UInt64 = 0
        while true {
            let chunk: Data
            do {
                chunk = try session.fileRead(handle: handle, length: Self.readChunkSize)
            } catch {
                throw AFCError.readFailed(error)
            }
            if chunk.isEmpty { break }
            try outHandle.write(contentsOf: chunk)
            written += UInt64(chunk.count)
            progress?(written, totalSize)
        }
    }

    func writeFile(at path: String, data: Data) throws {
        guard let session = session else { throw AFCError.notConnected }
        let handle: UInt64
        do {
            handle = try session.fileOpen(at: path, mode: AFCFileMode.writeOnly)
        } catch {
            throw AFCError.fileOpenFailed(error)
        }
        defer { try? session.fileClose(handle: handle) }

        // Chunk the write: a single FILE_WRITE packet carries its whole body in
        // one entire_length frame, and the device rejects oversized packets.
        var offset = 0
        while offset < data.count {
            let end = min(offset + Int(Self.readChunkSize), data.count)
            let chunk = data.subdata(in: offset..<end)
            do {
                try session.fileWrite(handle: handle, data: chunk)
            } catch {
                throw AFCError.writeFailed(error)
            }
            offset = end
        }
    }

    // Streams a local file straight to the device (chunked).
    func uploadFile(
        localURL: URL,
        to remotePath: String,
        progress: ((UInt64, UInt64?) -> Void)? = nil
    ) throws {
        guard let session = session else { throw AFCError.notConnected }
        let inHandle: FileHandle
        do {
            inHandle = try FileHandle(forReadingFrom: localURL)
        } catch {
            throw AFCError.localOpenFailed(error.localizedDescription)
        }
        defer { try? inHandle.close() }

        let totalSize = (try? FileManager.default
            .attributesOfItem(atPath: localURL.path)[.size] as? UInt64).flatMap { $0 }

        let remoteHandle: UInt64
        do {
            remoteHandle = try session.fileOpen(at: remotePath, mode: AFCFileMode.writeOnly)
        } catch {
            throw AFCError.fileOpenFailed(error)
        }
        defer { try? session.fileClose(handle: remoteHandle) }

        var written: UInt64 = 0
        while true {
            let chunk = inHandle.readData(ofLength: Int(Self.readChunkSize))
            if chunk.isEmpty { break }
            do {
                try session.fileWrite(handle: remoteHandle, data: chunk)
            } catch {
                throw AFCError.writeFailed(error)
            }
            written += UInt64(chunk.count)
            progress?(written, totalSize)
        }
    }

    // Streams data device-to-device for copy.
    func copyFile(
        from sourcePath: String,
        to destPath: String,
        progress: ((UInt64, UInt64?) -> Void)? = nil
    ) throws {
        guard let session = session else { throw AFCError.notConnected }
        let totalSize = (try? fileSize(at: sourcePath)).flatMap { $0 > 0 ? $0 : nil }

        let src: UInt64
        do {
            src = try session.fileOpen(at: sourcePath, mode: AFCFileMode.readOnly)
        } catch {
            throw AFCError.fileOpenFailed(error)
        }
        defer { try? session.fileClose(handle: src) }

        let dst: UInt64
        do {
            dst = try session.fileOpen(at: destPath, mode: AFCFileMode.writeOnly)
        } catch {
            throw AFCError.fileOpenFailed(error)
        }
        defer { try? session.fileClose(handle: dst) }

        var written: UInt64 = 0
        while true {
            let chunk: Data
            do {
                chunk = try session.fileRead(handle: src, length: Self.readChunkSize)
            } catch {
                throw AFCError.readFailed(error)
            }
            if chunk.isEmpty { break }
            do {
                try session.fileWrite(handle: dst, data: chunk)
            } catch {
                throw AFCError.writeFailed(error)
            }
            written += UInt64(chunk.count)
            progress?(written, totalSize)
        }
    }

    // MARK: - Mutations

    func deleteFile(at path: String) throws {
        guard let session = session else { throw AFCError.notConnected }
        do {
            try session.removePath(path)
        } catch {
            throw AFCError.deleteFailed(error)
        }
    }

    // Recursive delete — drains directories depth-first since AFC's REMOVE_PATH
    // only takes files / empty dirs. Same approach as before, just now over
    // our own protocol layer.
    func deleteRecursive(at path: String, isDirectory: Bool) throws {
        if isDirectory {
            let children = try listDirectory(at: path)
            for child in children {
                try deleteRecursive(at: child.path, isDirectory: child.isDirectory)
            }
        }
        try deleteFile(at: path)
    }

    func createDirectory(at path: String) throws {
        guard let session = session else { throw AFCError.notConnected }
        do {
            try session.makeDirectory(at: path)
        } catch {
            throw AFCError.createDirectoryFailed(error)
        }
    }

    func move(from oldPath: String, to newPath: String) throws {
        guard let session = session else { throw AFCError.notConnected }
        do {
            try session.rename(from: oldPath, to: newPath)
        } catch {
            throw AFCError.renameFailed(error)
        }
    }

    // MARK: - Helpers

    private func readFileInfo(session: AFCSession, path: String) throws -> (isDirectory: Bool, size: UInt64) {
        let info = try session.getFileInfo(at: path)
        let size = UInt64(info["st_size"] ?? "") ?? 0
        let isDir = (info["st_ifmt"] == "S_IFDIR")
        return (isDir, size)
    }

    private func guessFileType(name: String, isDirectory: Bool) -> FileNode.FileType {
        if isDirectory { return .directory }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "txt", "text", "log", "md", "rtf", "h", "m", "swift", "c", "cpp", "hpp",
             "java", "py", "js", "ts", "html", "css", "xml", "yaml", "yml", "csv",
             "ini", "conf", "sh":
            return .text
        case "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "svg", "ico", "webp",
             "heic", "heif", "dng", "icns":
            return .image
        case "mov", "mp4", "m4v", "avi", "mkv", "webm":
            return .video
        case "mp3", "m4a", "aac", "wav", "flac", "ogg":
            return .audio
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
