import Foundation

// MARK: - AFC wire protocol
//
// Independent Swift reimplementation of the AFC packet protocol. We need this
// because Apple's `AFCConnectionOpen` only works on plain TCP sockets — services
// that lockdownd encrypts (com.apple.mobile.house_arrest on iOS 13+) require
// I/O through `AMDServiceConnectionSend/Receive` which transparently handle the
// SSL session.
//
// Packet format (all little-endian, header is fixed 40 bytes):
//   off  0..8   magic "CFA6LPAA"
//   off  8..16  entire_length  (u64)  total bytes of packet incl. header
//   off 16..24  this_length    (u64)  header + immediate args (no body data)
//   off 24..32  packet_num     (u64)  request id, must match in response
//   off 32..40  operation      (u64)  AFCOpcode
//
// References:
//   - pymobiledevice3 services/afc.py
//   - libimobiledevice src/afc.c

private let afcMagic: [UInt8] = Array("CFA6LPAA".utf8)
private let afcHeaderSize = 40

enum AFCOpcode: UInt64 {
    case status                  = 0x0000_0001
    case data                    = 0x0000_0002
    case readDir                 = 0x0000_0003
    case readFile                = 0x0000_0004
    case writeFile               = 0x0000_0005
    case writePart               = 0x0000_0006
    case truncateFile            = 0x0000_0007
    case removePath              = 0x0000_0008
    case makeDir                 = 0x0000_0009
    case getFileInfo             = 0x0000_000A
    case getDeviceInfo           = 0x0000_000B
    case writeFileAtomic         = 0x0000_000C
    // Opcode values MUST match libimobiledevice's afc.h `enum afc_ops` exactly.
    // (Earlier these were off-by-shift from 0x11 onward, which silently sent
    // FILE_TELL instead of FILE_CLOSE and SET_SOCKET_BS instead of RENAME_PATH.)
    case fileOpen                = 0x0000_000D
    case fileOpenResult          = 0x0000_000E
    case fileRead                = 0x0000_000F
    case fileWrite               = 0x0000_0010
    case fileSeek                = 0x0000_0011
    case fileTell                = 0x0000_0012
    case fileTellResult          = 0x0000_0013
    case fileClose               = 0x0000_0014
    case fileSetSize             = 0x0000_0015
    case getConnectionInfo       = 0x0000_0016
    case setConnectionOptions    = 0x0000_0017
    case renamePath              = 0x0000_0018
    case setFSBlockSize          = 0x0000_0019
    case setSocketBlockSize      = 0x0000_001A
    case fileLock                = 0x0000_001B
    case makeLink                = 0x0000_001C
    case setFileTime             = 0x0000_001E
}

// File open modes (subset, matches AFC protocol)
struct AFCFileMode {
    static let readOnly:  UInt64 = 0x00000001  // r
    static let readWrite: UInt64 = 0x00000002  // r+
    static let writeOnly: UInt64 = 0x00000003  // w  (create/truncate)
    static let writePlus: UInt64 = 0x00000004  // w+
    static let append:    UInt64 = 0x00000005  // a
    static let appendPlus: UInt64 = 0x00000006 // a+
}

// MARK: - Errors

enum AFCSessionError: LocalizedError {
    case notConnected
    case sendFailed(errno: Int32)
    case recvFailed(errno: Int32)
    case shortRead(expected: Int, got: Int)
    case invalidMagic(String)
    case unexpectedOpcode(UInt64, expected: AFCOpcode)
    case status(AFCStatus, opcode: AFCOpcode)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "AFC session not connected"
        case .sendFailed(let e): return "AFC send failed (errno \(e))"
        case .recvFailed(let e): return "AFC receive failed (errno \(e))"
        case .shortRead(let exp, let got):
            return "AFC short read (expected \(exp), got \(got))"
        case .invalidMagic(let m): return "AFC invalid magic: \(m)"
        case .unexpectedOpcode(let got, let expected):
            return "AFC unexpected opcode 0x\(String(got, radix: 16)) (expected \(expected))"
        case .status(let s, let op): return "AFC \(op) returned \(s)"
        case .malformedResponse(let what): return "AFC malformed response: \(what)"
        }
    }
}

// Status codes returned by the device in STATUS responses.
enum AFCStatus: UInt64 {
    case success            = 0
    case unknownError       = 1
    case opHeaderInvalid    = 2
    case noResources        = 3
    case readError          = 4
    case writeError         = 5
    case unknownPacketType  = 6
    case invalidArg         = 7
    case objectNotFound     = 8
    case objectIsDir        = 9
    case permDenied         = 10
    case serviceNotConnected = 11
    case opTimeout          = 12
    case tooMuchData        = 13
    case endOfData          = 14
    case opNotSupported     = 15
    case objectExists       = 16
    case objectBusy         = 17
    case noSpaceLeft        = 18
    case opWouldBlock       = 19
    case ioError            = 20
    case opInterrupted      = 21
    case opInProgress       = 22
    case internalError      = 23
    case unknown            = 0xFFFF
}

// MARK: - Transport
//
// Byte channel backed by an AMDServiceConnection. Both com.apple.afc (Media)
// and com.apple.mobile.house_arrest (App sandbox) are started via
// AMDeviceSecureStartService and route through AMDServiceConnectionSend/Receive,
// which transparently apply the SSL session when lockdownd marks the service
// encrypted. (Apple's plain AFCConnectionOpen can't do AFC-over-SSL, and the
// raw socket fd it hands back can't be reconstructed from an AFCConnectionRef
// pointer — hence we own the framing and use the service-connection transport.)

protocol AFCTransport: AnyObject {
    func send(_ data: Data) throws
    func receive(_ count: Int) throws -> Data
    func close()
}

final class AFCServiceConnectionTransport: AFCTransport {
    private var conn: AMDServiceConnectionRef?

    init(connection: AMDServiceConnectionRef) {
        self.conn = connection
    }

    deinit { close() }

    func send(_ data: Data) throws {
        guard let conn = conn else { throw AFCSessionError.notConnected }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = AMDServiceConnectionSend(conn, base.advanced(by: sent), data.count - sent)
                if n <= 0 { throw AFCSessionError.sendFailed(errno: errno) }
                sent += Int(n)
            }
        }
    }

    func receive(_ count: Int) throws -> Data {
        guard let conn = conn else { throw AFCSessionError.notConnected }
        var buf = Data(count: count)
        try buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var read = 0
            while read < count {
                let n = AMDServiceConnectionReceive(conn, base.advanced(by: read), count - read)
                if n == 0 { throw AFCSessionError.shortRead(expected: count, got: read) }
                if n < 0 { throw AFCSessionError.recvFailed(errno: errno) }
                read += Int(n)
            }
        }
        return buf
    }

    func close() {
        if let c = conn {
            AMDServiceConnectionInvalidate(c)
            conn = nil
        }
    }
}

// MARK: - Session — high-level AFC operations

final class AFCSession {
    private let transport: AFCTransport
    private var nextPacketID: UInt64 = 0
    // Serializes request/response so multiple ops don't interleave packets on
    // the same transport.
    private let lock = NSLock()

    init(transport: AFCTransport) {
        self.transport = transport
    }

    deinit { transport.close() }

    // MARK: - Public operations

    func listDirectory(at path: String) throws -> [String] {
        // Path bytes WITHOUT NUL terminator — the packet's entire_length field
        // defines payload boundaries. Adding a trailing NUL gets the request
        // rejected by the device.
        let resp = try roundTrip(opcode: .readDir, headerPayload: pathBytes(path))
        // Response payload is a sequence of NUL-separated UTF-8 strings,
        // including "." and ".." which the caller filters.
        let names = resp.payload.split(separator: 0, omittingEmptySubsequences: true)
            .compactMap { String(data: Data($0), encoding: .utf8) }
        return names
    }

    func getFileInfo(at path: String) throws -> [String: String] {
        let resp = try roundTrip(opcode: .getFileInfo, headerPayload: pathBytes(path))
        return parseKVPairs(resp.payload)
    }

    func fileOpen(at path: String, mode: UInt64) throws -> UInt64 {
        var args = Data()
        args.append(le(mode))
        args.append(pathBytes(path))
        let resp = try roundTrip(opcode: .fileOpen, headerPayload: args, expecting: .fileOpenResult)
        guard resp.payload.count >= 8 else {
            throw AFCSessionError.malformedResponse("fileOpen result < 8 bytes")
        }
        return resp.payload.readU64(at: 0)
    }

    func fileClose(handle: UInt64) throws {
        var args = Data()
        args.append(le(handle))
        _ = try roundTrip(opcode: .fileClose, headerPayload: args)
    }

    // Single AFC FILE_READ — caller is responsible for chunking large reads.
    func fileRead(handle: UInt64, length: UInt64) throws -> Data {
        var args = Data()
        args.append(le(handle))
        args.append(le(length))
        let resp = try roundTrip(opcode: .fileRead, headerPayload: args, expecting: .data)
        return resp.payload
    }

    // Single AFC FILE_WRITE — the handle goes in this_length args, the bytes
    // ride along as bodyPayload.
    func fileWrite(handle: UInt64, data: Data) throws {
        var args = Data()
        args.append(le(handle))
        _ = try roundTrip(opcode: .fileWrite, headerPayload: args, bodyPayload: data)
    }

    func removePath(_ path: String) throws {
        _ = try roundTrip(opcode: .removePath, headerPayload: pathBytes(path))
    }

    func makeDirectory(at path: String) throws {
        _ = try roundTrip(opcode: .makeDir, headerPayload: pathBytes(path))
    }

    func rename(from oldPath: String, to newPath: String) throws {
        // pathBytes already includes a trailing NUL on each, giving the
        // "old\0new\0" wire format AFC expects.
        var args = pathBytes(oldPath)
        args.append(pathBytes(newPath))
        _ = try roundTrip(opcode: .renamePath, headerPayload: args)
    }

    // MARK: - Low-level round-trip

    // Sends one request packet and reads exactly one response. STATUS responses
    // with non-success code are converted to AFCSessionError.status. When the
    // caller passes `expecting`, a different opcode in the response is rejected
    // (except STATUS-with-success which is allowed).
    @discardableResult
    func roundTrip(
        opcode: AFCOpcode,
        headerPayload: Data = Data(),
        bodyPayload: Data = Data(),
        expecting: AFCOpcode? = nil
    ) throws -> AFCResponse {
        lock.lock()
        defer { lock.unlock() }

        nextPacketID += 1
        let pid = nextPacketID

        let thisLength = UInt64(afcHeaderSize + headerPayload.count)
        let entireLength = thisLength + UInt64(bodyPayload.count)

        var packet = Data(capacity: Int(entireLength))
        packet.append(contentsOf: afcMagic)
        packet.append(le(entireLength))
        packet.append(le(thisLength))
        packet.append(le(pid))
        packet.append(le(opcode.rawValue))
        packet.append(headerPayload)
        packet.append(bodyPayload)

        try transport.send(packet)
        let response = try receiveResponse()

        // STATUS responses encode op result in the first 8 bytes of payload.
        if response.opcode == .status {
            let code = response.payload.count >= 8 ? response.payload.readU64(at: 0) : 0
            // A read that hits EOF can be signaled by STATUS(endOfData) or a
            // bare success STATUS instead of an empty DATA packet. For callers
            // expecting DATA, surface that as an empty payload so the read loop
            // terminates cleanly rather than throwing.
            if expecting == .data, code == 0 || code == AFCStatus.endOfData.rawValue {
                return AFCResponse(opcode: .data, payload: Data())
            }
            if code != 0 {
                let status = AFCStatus(rawValue: code) ?? .unknown
                throw AFCSessionError.status(status, opcode: opcode)
            }
            // Success STATUS — treat as fine. If caller expected a specific
            // non-status opcode (like fileOpenResult), reject.
            if let expected = expecting, expected != .status {
                throw AFCSessionError.unexpectedOpcode(response.opcode.rawValue, expected: expected)
            }
            return response
        }

        if let expected = expecting, expected != response.opcode {
            throw AFCSessionError.unexpectedOpcode(response.opcode.rawValue, expected: expected)
        }
        return response
    }

    private func receiveResponse() throws -> AFCResponse {
        let header = try transport.receive(afcHeaderSize)
        // Validate magic
        let magicBytes = header.subdata(in: 0..<8)
        guard magicBytes == Data(afcMagic) else {
            let m = String(data: magicBytes, encoding: .ascii) ?? "?"
            throw AFCSessionError.invalidMagic(m)
        }
        let entireLength = header.readU64(at: 8)
        // let thisLength = header.readU64(at: 16)  // not needed for receive
        // let packetID = header.readU64(at: 24)    // could verify but we don't pipeline
        let opcodeRaw = header.readU64(at: 32)

        // Guard against a corrupt length field: < header would make payloadSize
        // negative (Data(count:) traps), and an absurdly large value would
        // attempt a multi-GB allocation and then block forever in recv. AFC
        // payloads (chunks, dir listings, file info) are well under this cap.
        let maxPayload: UInt64 = 64 * 1024 * 1024
        guard entireLength >= UInt64(afcHeaderSize),
              entireLength - UInt64(afcHeaderSize) <= maxPayload else {
            throw AFCSessionError.malformedResponse("entire_length \(entireLength) out of range")
        }

        let payloadSize = Int(entireLength) - afcHeaderSize
        var payload = Data()
        if payloadSize > 0 {
            payload = try transport.receive(payloadSize)
        }
        guard let opcode = AFCOpcode(rawValue: opcodeRaw) else {
            throw AFCSessionError.malformedResponse("unknown response opcode 0x\(String(opcodeRaw, radix: 16))")
        }
        return AFCResponse(opcode: opcode, payload: payload)
    }
}

// MARK: - Helpers

struct AFCResponse {
    let opcode: AFCOpcode
    let payload: Data
}

private func le(_ value: UInt64) -> Data {
    var v = value.littleEndian
    return withUnsafeBytes(of: &v) { Data($0) }
}

// Raw UTF-8 bytes of a path WITH trailing NUL. libimobiledevice and
// pymobiledevice3 both send `strlen(path)+1` bytes — iOS AFC's READ_DIR
// happens to tolerate a missing NUL, but GET_FILE_INFO / FILE_OPEN do not
// (the request silently fails / returns an empty payload, which then looks
// like "every file is 0 bytes and can't be opened").
private func pathBytes(_ s: String) -> Data {
    var d = Data(s.utf8)
    d.append(0)
    return d
}

// Parses NUL-separated key/value pairs from AFC getFileInfo / getDeviceInfo
// responses. Example payload: "st_size\0123\0st_blocks\01\0st_ifmt\0S_IFREG\0".
private func parseKVPairs(_ data: Data) -> [String: String] {
    let parts = data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) }
    var result: [String: String] = [:]
    var i = 0
    while i + 1 < parts.count {
        result[parts[i]] = parts[i + 1]
        i += 2
    }
    return result
}

private extension Data {
    func readU64(at offset: Int) -> UInt64 {
        let slice = self.subdata(in: offset..<(offset + 8))
        return slice.withUnsafeBytes { raw in
            raw.loadUnaligned(as: UInt64.self).littleEndian
        }
    }
}
