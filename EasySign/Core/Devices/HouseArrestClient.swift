import Foundation

// MARK: - House Arrest Errors

enum HouseArrestError: LocalizedError {
    case startServiceFailed(Int32)
    case sendFailed(errno: Int32)
    case recvFailed(errno: Int32)
    case plistDecodeFailed
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .startServiceFailed(let c):
            return "Failed to start house_arrest service (\(amdErrorName(c)), code \(c))"
        case .sendFailed(let e):
            return "Failed to send VendContainer (errno \(e))"
        case .recvFailed(let e):
            return "Failed to receive VendContainer response (errno \(e))"
        case .plistDecodeFailed:
            return "Failed to decode VendContainer response"
        case .rejected(let msg):
            return msg
        }
    }

    var isTransient: Bool {
        if case .startServiceFailed(let code) = self {
            switch UInt32(bitPattern: code) {
            case 0xE8000003, 0xE8000004, 0xE8000005, 0xE800000C, 0xE8000012:
                return true
            default:
                return false
            }
        }
        return false
    }
}

private func amdErrorName(_ code: Int32) -> String {
    switch UInt32(bitPattern: code) {
    case 0xE8000001: return "Undefined"
    case 0xE8000003: return "NoResources"
    case 0xE8000007: return "InvalidArgument"
    case 0xE8000008: return "NotFound"
    case 0xE800000A: return "PermissionDenied"
    case 0xE800000C: return "Timeout"
    case 0xE8000010: return "Unsupported"
    case 0xE8000012: return "Busy"
    case 0xE8000013: return "Crypto"
    default:         return "Unknown"
    }
}

enum HouseArrestCommand: String {
    case vendContainer = "VendContainer"   // full app container
    case vendDocuments = "VendDocuments"   // Documents-only fallback
}

// MARK: - HouseArrestClient
//
// On iOS 13+ `com.apple.mobile.house_arrest` is an SSL-required lockdownd
// service. We start it with `AMDeviceSecureStartService` (which sets up the
// SSL context) and do the VendContainer / VendDocuments plist exchange
// through `AMDServiceConnectionSend/Receive` (SSL-transparent). The returned
// `AFCServiceConnectionTransport` then routes all AFC packets through the
// same SSL-aware path — Apple's plain `AFCConnectionOpen` does NOT know how
// to do AFC over SSL, so we wrote our own protocol layer (AFCProtocol.swift).
enum HouseArrestClient {

    // Returns a transport already past the VendContainer/VendDocuments
    // handshake. Caller owns it — pass to AFCSession.
    static func openTransport(
        deviceRef: AMDeviceRef,
        bundleID: String,
        command: HouseArrestCommand
    ) throws -> AFCTransport {
        let serviceConn = try startSecureService(deviceRef: deviceRef)

        // Default: if anything below throws, invalidate the connection on the
        // way out. After the success path runs, flip this off so the connection
        // survives to be owned by the returned transport.
        var shouldInvalidate = true
        defer { if shouldInvalidate { AMDServiceConnectionInvalidate(serviceConn) } }

        try vendHandshake(connection: serviceConn, bundleID: bundleID, command: command)

        shouldInvalidate = false
        return AFCServiceConnectionTransport(connection: serviceConn)
    }

    // MARK: - Private

    private static func startSecureService(deviceRef: AMDeviceRef) throws -> AMDServiceConnectionRef {
        var serviceConn: AMDServiceConnectionRef?
        var result: Int32 = -1

        for attempt in 0..<3 {
            serviceConn = nil
            result = AMDeviceSecureStartService(
                deviceRef,
                "com.apple.mobile.house_arrest" as CFString,
                nil,
                &serviceConn
            )
            if result == AMDAppLEDETECT_SUCCESS, serviceConn != nil { break }
            let transient: Bool = {
                switch UInt32(bitPattern: result) {
                case 0xE8000003, 0xE8000004, 0xE8000005, 0xE800000C, 0xE8000012:
                    return true
                default: return false
                }
            }()
            if !transient { break }
            Thread.sleep(forTimeInterval: 0.3 * Double(attempt + 1))
        }
        guard result == AMDAppLEDETECT_SUCCESS, let conn = serviceConn else {
            throw HouseArrestError.startServiceFailed(result)
        }
        return conn
    }

    // Sends {Command, Identifier} plist (length-prefixed big-endian u32 + xml
    // plist) over the SSL channel, reads the response, checks for {Error}.
    private static func vendHandshake(
        connection: AMDServiceConnectionRef,
        bundleID: String,
        command: HouseArrestCommand
    ) throws {
        let request: [String: Any] = [
            "Command": command.rawValue,
            "Identifier": bundleID,
        ]
        let plistData: Data
        do {
            plistData = try PropertyListSerialization.data(
                fromPropertyList: request, format: .xml, options: 0)
        } catch {
            throw HouseArrestError.plistDecodeFailed
        }

        var lengthBE = UInt32(plistData.count).bigEndian
        var buffer = Data()
        buffer.append(Data(bytes: &lengthBE, count: 4))
        buffer.append(plistData)

        // Send length-prefixed plist over SSL.
        try buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let n = AMDServiceConnectionSend(connection, base.advanced(by: sent), buffer.count - sent)
                if n <= 0 { throw HouseArrestError.sendFailed(errno: errno) }
                sent += Int(n)
            }
        }

        // Read 4-byte BE length prefix, then plist body.
        var lengthBytes = [UInt8](repeating: 0, count: 4)
        try lengthBytes.withUnsafeMutableBufferPointer { bp in
            try readExact(connection: connection, into: bp.baseAddress!, count: 4)
        }
        let bodyLength = lengthBytes.withUnsafeBytes { raw -> Int in
            let be = raw.loadUnaligned(as: UInt32.self)
            return Int(UInt32(bigEndian: be))
        }
        guard bodyLength > 0 && bodyLength < 1_000_000 else {
            throw HouseArrestError.plistDecodeFailed
        }
        var bodyBytes = [UInt8](repeating: 0, count: bodyLength)
        try bodyBytes.withUnsafeMutableBufferPointer { bp in
            try readExact(connection: connection, into: bp.baseAddress!, count: bodyLength)
        }

        guard let plist = try? PropertyListSerialization.propertyList(
            from: Data(bodyBytes), options: [], format: nil) as? [String: Any] else {
            throw HouseArrestError.plistDecodeFailed
        }
        if let errorMsg = plist["Error"] as? String {
            throw HouseArrestError.rejected(errorMsg)
        }
        // Success — Status="Complete" on newer iOS, or empty dict on older.
    }

    private static func readExact(
        connection: AMDServiceConnectionRef,
        into pointer: UnsafeMutableRawPointer,
        count: Int
    ) throws {
        var read = 0
        while read < count {
            let n = AMDServiceConnectionReceive(connection, pointer.advanced(by: read), count - read)
            if n <= 0 { throw HouseArrestError.recvFailed(errno: errno) }
            read += Int(n)
        }
    }
}
