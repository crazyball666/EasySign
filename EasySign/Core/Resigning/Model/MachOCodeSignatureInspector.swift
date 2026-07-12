//
//  MachOCodeSignatureInspector.swift
//  EasySign
//
//  Independent structural verification of ZSign-produced Mach-O signatures.
//

import CoreFoundation
import Foundation

enum MachOCodeSignatureInspector {
    static func inspectMainExecutable(
        in data: Data,
        expectedEntitlements: [String: Any],
        expectedIdentifier: String,
        expectedTeamIdentifier: String
    ) throws {
        let slices = try MachOExecutableScanner.slices(in: data)
        guard !slices.isEmpty, slices.allSatisfy({ $0.fileType == .execute }) else {
            throw MachOCodeSignatureInspectorError.invalid("main executable contains a non-MH_EXECUTE slice")
        }
        for slice in slices {
            guard let signature = try signature(in: data, slice: slice) else {
                throw MachOCodeSignatureInspectorError.invalid("main executable slice has no LC_CODE_SIGNATURE")
            }
            let contents = try parseSignature(data, range: signature)
            guard let xml = contents.xmlEntitlements, let der = contents.derEntitlements else {
                throw MachOCodeSignatureInspectorError.invalid("main executable must contain XML and DER entitlement slots")
            }
            guard deepEqual(xml, der), deepEqual(xml, expectedEntitlements) else {
                throw MachOCodeSignatureInspectorError.invalid("XML/DER entitlements do not equal the reconciled entitlement result")
            }
            guard !contents.codeDirectories.isEmpty else {
                throw MachOCodeSignatureInspectorError.invalid("main executable has no CodeDirectory")
            }
            for directory in contents.codeDirectories {
                guard directory.version == 0x20400 else {
                    throw MachOCodeSignatureInspectorError.invalid("CodeDirectory version \(String(directory.version, radix: 16)) is not ZSign 0x20400")
                }
                guard directory.identifier == expectedIdentifier, directory.teamIdentifier == expectedTeamIdentifier else {
                    throw MachOCodeSignatureInspectorError.invalid("CodeDirectory identifier or team identifier differs from the selected profile")
                }
                let taskAllowed = (expectedEntitlements["get-task-allow"] as? Bool) == true
                if !taskAllowed && (directory.execSegFlags & 0x10) != 0 {
                    throw MachOCodeSignatureInspectorError.invalid("CS_EXECSEG_ALLOW_UNSIGNED is set without get-task-allow")
                }
            }
        }
    }

    static func inspectNonExecutableMachO(in data: Data) throws {
        for slice in try MachOExecutableScanner.slices(in: data) {
            guard slice.fileType != .execute else {
                throw MachOCodeSignatureInspectorError.invalid("non-executable inspection received MH_EXECUTE")
            }
            guard let signature = try signature(in: data, slice: slice) else { continue }
            let contents = try parseSignature(data, range: signature)
            if let xml = contents.xmlEntitlements, !xml.isEmpty {
                throw MachOCodeSignatureInspectorError.invalid("non-executable Mach-O contains XML entitlements")
            }
            if let der = contents.derEntitlements, !der.isEmpty {
                throw MachOCodeSignatureInspectorError.invalid("non-executable Mach-O contains DER entitlements")
            }
        }
    }
}

enum MachOCodeSignatureInspectorError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

private extension MachOCodeSignatureInspector {
    struct CodeDirectory {
        let version: UInt32
        let identifier: String
        let teamIdentifier: String
        let execSegFlags: UInt64
    }

    struct SignatureContents {
        var xmlEntitlements: [String: Any]?
        var derEntitlements: [String: Any]?
        var codeDirectories: [CodeDirectory]
    }

    static func signature(in data: Data, slice: MachOSlice) throws -> Range<Int>? {
        let reader = CodeSignReader(data)
        guard let magic = reader.uint32LE(at: slice.offset) else { throw malformed("Mach-O slice is truncated") }
        let headerSize: Int
        switch magic {
        case 0xFEEDFACF: headerSize = 32
        case 0xFEEDFACE: headerSize = 28
        default: throw malformed("Mach-O slice magic is invalid")
        }
        guard let ncmds = reader.uint32LE(at: slice.offset + 16),
              let sizeofcmds = reader.uint32LE(at: slice.offset + 20),
              let commandsEnd = safeAdd(slice.offset + headerSize, Int(sizeofcmds)), commandsEnd <= slice.offset + slice.size
        else { throw malformed("Mach-O load command range is invalid") }
        var cursor = slice.offset + headerSize
        for _ in 0..<ncmds {
            guard cursor + 8 <= commandsEnd,
                  let command = reader.uint32LE(at: cursor), let commandSize = reader.uint32LE(at: cursor + 4), commandSize >= 8,
                  let commandEnd = safeAdd(cursor, Int(commandSize)), commandEnd <= commandsEnd
            else { throw malformed("Mach-O load command is malformed") }
            if command == 0x1d {
                guard commandSize >= 16,
                      let dataOffset = reader.uint32LE(at: cursor + 8), let dataSize = reader.uint32LE(at: cursor + 12),
                      let start = safeAdd(slice.offset, Int(dataOffset)), let end = safeAdd(start, Int(dataSize)),
                      start >= slice.offset, end <= slice.offset + slice.size
                else { throw malformed("LC_CODE_SIGNATURE range is invalid") }
                return start..<end
            }
            cursor = commandEnd
        }
        return nil
    }

    static func parseSignature(_ data: Data, range: Range<Int>) throws -> SignatureContents {
        let reader = CodeSignReader(data)
        guard range.count >= 12, reader.uint32BE(at: range.lowerBound) == 0xfade0cc0,
              let totalLength = reader.uint32BE(at: range.lowerBound + 4), totalLength >= 12,
              let superBlobEnd = safeAdd(range.lowerBound, Int(totalLength)), superBlobEnd <= range.upperBound,
              let count = reader.uint32BE(at: range.lowerBound + 8), count <= 32
        else { throw malformed("Code Signature SuperBlob is malformed") }
        let indexBytes = Int(count) * 8
        guard let indexEnd = safeAdd(range.lowerBound + 12, indexBytes), indexEnd <= superBlobEnd else {
            throw malformed("Code Signature SuperBlob index is truncated")
        }

        var blobs: [(slot: UInt32, range: Range<Int>)] = []
        var ranges: [Range<Int>] = []
        for index in 0..<Int(count) {
            let entry = range.lowerBound + 12 + index * 8
            guard let slot = reader.uint32BE(at: entry), let relativeOffset = reader.uint32BE(at: entry + 4),
                  let start = safeAdd(range.lowerBound, Int(relativeOffset)), start >= indexEnd,
                  let length = reader.uint32BE(at: start + 4), let end = safeAdd(start, Int(length)), length >= 8, end <= superBlobEnd
            else { throw malformed("Code Signature SuperBlob entry is invalid") }
            let blobRange = start..<end
            guard !ranges.contains(where: { $0.overlaps(blobRange) }) else {
                throw malformed("Code Signature SuperBlob blobs overlap")
            }
            ranges.append(blobRange)
            blobs.append((slot, blobRange))
        }

        var contents = SignatureContents(xmlEntitlements: nil, derEntitlements: nil, codeDirectories: [])
        var seenSlots = Set<UInt32>()
        for blob in blobs {
            guard seenSlots.insert(blob.slot).inserted else { throw malformed("duplicate Code Signature slot") }
            guard let magic = reader.uint32BE(at: blob.range.lowerBound) else { throw malformed("truncated Code Signature blob") }
            switch blob.slot {
            case 0, 0x1000...0x1004:
                guard magic == 0xfade0c02 else { throw malformed("CodeDirectory has invalid magic") }
                contents.codeDirectories.append(try parseCodeDirectory(reader, range: blob.range))
            case 5:
                guard magic == 0xfade7171 else { throw malformed("XML entitlements slot has invalid magic") }
                contents.xmlEntitlements = try plistEntitlements(data, payload: (blob.range.lowerBound + 8)..<blob.range.upperBound)
            case 7:
                guard magic == 0xfade7172 else { throw malformed("DER entitlements slot has invalid magic") }
                var decoder = DEREntitlementsDecoder(data: data[(blob.range.lowerBound + 8)..<blob.range.upperBound])
                contents.derEntitlements = try decoder.decodeDictionary()
            default:
                continue
            }
        }
        return contents
    }

    static func parseCodeDirectory(_ reader: CodeSignReader, range: Range<Int>) throws -> CodeDirectory {
        guard range.count >= 88,
              let version = reader.uint32BE(at: range.lowerBound + 8),
              let identifierOffset = reader.uint32BE(at: range.lowerBound + 20),
              let teamOffset = reader.uint32BE(at: range.lowerBound + 48),
              let execSegFlags = reader.uint64BE(at: range.lowerBound + 80),
              let identifierStart = safeAdd(range.lowerBound, Int(identifierOffset)),
              let teamStart = safeAdd(range.lowerBound, Int(teamOffset)),
              let identifier = reader.nullTerminatedUTF8(at: identifierStart, within: range),
              let team = reader.nullTerminatedUTF8(at: teamStart, within: range)
        else { throw malformed("CodeDirectory is truncated or missing identifier/team") }
        return CodeDirectory(version: version, identifier: identifier, teamIdentifier: team, execSegFlags: execSegFlags)
    }

    static func plistEntitlements(_ data: Data, payload: Range<Int>) throws -> [String: Any] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data[payload], options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else { throw malformed("XML entitlements plist is invalid") }
        return dictionary
    }

    static func deepEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        plistEqual(lhs, rhs)
    }

    static func plistEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
            return left.count == right.count && left.allSatisfy { key, value in
                right[key].map { plistEqual(value, $0) } ?? false
            }
        }
        if let left = lhs as? [Any], let right = rhs as? [Any] {
            return left.count == right.count && zip(left, right).allSatisfy { plistEqual($0.0, $0.1) }
        }
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber,
           CFGetTypeID(left) == CFBooleanGetTypeID(), CFGetTypeID(right) == CFBooleanGetTypeID() {
            return left.boolValue == right.boolValue
        }
        // Numeric values: XML plist decodes to NSNumber, the DER decoder yields Int.
        if let left = lhs as? NSNumber, let right = rhs as? NSNumber,
           CFGetTypeID(left) != CFBooleanGetTypeID(), CFGetTypeID(right) != CFBooleanGetTypeID() {
            return left == right
        }
        if let left = lhs as? String, let right = rhs as? String { return left == right }
        return false
    }

    static func malformed(_ message: String) -> MachOCodeSignatureInspectorError { .invalid(message) }
    static func safeAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}

private struct CodeSignReader {
    let data: Data
    init(_ data: Data) { self.data = data }

    func uint32LE(at offset: Int) -> UInt32? {
        guard let bytes = bytes(at: offset, count: 4) else { return nil }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }
    func uint32BE(at offset: Int) -> UInt32? { uint32LE(at: offset).map { $0.byteSwapped } }
    func uint64BE(at offset: Int) -> UInt64? {
        guard let high = uint32BE(at: offset), let low = uint32BE(at: offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }
    func nullTerminatedUTF8(at offset: Int, within range: Range<Int>) -> String? {
        guard range.contains(offset) else { return nil }
        guard let end = data[offset..<range.upperBound].firstIndex(of: 0) else { return nil }
        return String(data: data[offset..<end], encoding: .utf8)
    }
    private func bytes(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, offset <= data.count - count else { return nil }
        let start = data.index(data.startIndex, offsetBy: offset)
        return Array(data[start..<data.index(start, offsetBy: count)])
    }
}

private struct DEREntitlementsDecoder {
    private let bytes: [UInt8]
    private var position = 0
    private var nodes = 0

    init(data: Data) { bytes = Array(data) }

    mutating func decodeDictionary() throws -> [String: Any] {
        let value = try decodeValue(depth: 0)
        guard position == bytes.count, let dictionary = value as? [String: Any] else {
            throw MachOCodeSignatureInspectorError.invalid("DER entitlements root is not a complete dictionary")
        }
        return dictionary
    }

    private mutating func decodeValue(depth: Int) throws -> Any {
        guard depth <= 64, nodes < 100_000, position < bytes.count else { throw derError("DER nesting or bounds limit exceeded") }
        nodes += 1
        let tag = bytes[position]; position += 1
        let length = try decodeLength()
        guard length <= bytes.count - position else { throw derError("DER length exceeds remaining data") }
        let payloadStart = position; let payloadEnd = position + length; position = payloadEnd
        switch tag {
        case 0x01:
            guard length == 1, [UInt8(0), UInt8(1), UInt8(0xff)].contains(bytes[payloadStart]) else { throw derError("DER Boolean is invalid") }
            return bytes[payloadStart] != 0
        case 0x02:
            // INTEGER, big-endian. Used by the Apple-canonical entitlements
            // version header and by any integer-valued entitlement.
            guard length >= 1 else { throw derError("DER Integer is empty") }
            var value = 0
            for i in payloadStart..<payloadEnd { value = value << 8 | Int(bytes[i]) }
            return value
        case 0x0c:
            guard let string = String(bytes: bytes[payloadStart..<payloadEnd], encoding: .utf8) else { throw derError("DER UTF8String is invalid") }
            return string
        case 0x30:
            var nested = DEREntitlementsDecoder(bytes: Array(bytes[payloadStart..<payloadEnd]))
            var array: [Any] = []
            while nested.position < nested.bytes.count { array.append(try nested.decodeValue(depth: depth + 1)) }
            return array
        case 0x31, 0xb0:
            // Dictionary container. Apple-canonical DER (zsign fe1750d+) tags the
            // entitlements dictionary 0xb0; older zsign output used 0x31.
            var nested = DEREntitlementsDecoder(bytes: Array(bytes[payloadStart..<payloadEnd]))
            var dictionary: [String: Any] = [:]
            while nested.position < nested.bytes.count {
                let entry = try nested.decodeSequenceEntry(depth: depth + 1)
                guard dictionary[entry.0] == nil else { throw derError("DER dictionary contains duplicate key") }
                dictionary[entry.0] = entry.1
            }
            return dictionary
        case 0x70:
            // Apple-canonical entitlements wrapper: [0x70] { INTEGER version, dict }.
            var nested = DEREntitlementsDecoder(bytes: Array(bytes[payloadStart..<payloadEnd]))
            _ = try nested.decodeValue(depth: depth + 1)            // version, discarded
            let inner = try nested.decodeValue(depth: depth + 1)
            guard nested.position == nested.bytes.count, let dictionary = inner as? [String: Any] else {
                throw derError("DER entitlements wrapper is malformed")
            }
            return dictionary
        default:
            throw derError("DER entitlement contains unsupported tag \(tag)")
        }
    }

    private mutating func decodeSequenceEntry(depth: Int) throws -> (String, Any) {
        guard position < bytes.count, bytes[position] == 0x30 else { throw derError("DER dictionary entry is not a sequence") }
        position += 1
        let length = try decodeLength()
        guard length <= bytes.count - position else { throw derError("DER dictionary entry is truncated") }
        var entry = DEREntitlementsDecoder(bytes: Array(bytes[position..<(position + length)]))
        position += length
        let keyValue = try entry.decodeValue(depth: depth)
        guard let key = keyValue as? String else { throw derError("DER dictionary key is not UTF8String") }
        let value = try entry.decodeValue(depth: depth)
        guard entry.position == entry.bytes.count else { throw derError("DER dictionary entry has trailing data") }
        return (key, value)
    }

    private mutating func decodeLength() throws -> Int {
        guard position < bytes.count else { throw derError("DER length is truncated") }
        let first = bytes[position]; position += 1
        if first < 0x80 { return Int(first) }
        let width = Int(first & 0x7f)
        guard width > 0, width <= 4, width <= bytes.count - position, bytes[position] != 0 else { throw derError("DER length encoding is invalid") }
        var length = 0
        for _ in 0..<width { length = length << 8 | Int(bytes[position]); position += 1 }
        guard length >= 128 else { throw derError("DER length is not minimally encoded") }
        return length
    }

    private func derError(_ message: String) -> MachOCodeSignatureInspectorError { .invalid(message) }

    private init(bytes: [UInt8]) { self.bytes = bytes }
}
