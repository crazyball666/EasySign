//
//  MachOExecutableScanner.swift
//  EasySign
//
//  Bounded Mach-O topology checks used before and after ZSign.
//

import Foundation

enum MachOFileType: UInt32, Equatable {
    case execute = 0x2       // MH_EXECUTE
    case dylib = 0x6         // MH_DYLIB
}

struct MachOSlice: Equatable {
    let offset: Int
    let size: Int
    let fileType: MachOFileType?
}

enum MachOExecutableScanner {
    static func slices(in data: Data) throws -> [MachOSlice] {
        let reader = MachOByteReader(data)
        guard let magicBE = reader.uint32BE(at: 0), let magicLE = reader.uint32LE(at: 0) else {
            throw MachOScannerError.malformed("file is shorter than a Mach-O magic")
        }
        switch magicBE {
        case 0xCAFEBABE:
            return try fatSlices(reader: reader, is64: false)
        case 0xCAFEBABF:
            return try fatSlices(reader: reader, is64: true)
        default:
            return [try thinSlice(reader: reader, offset: 0, size: data.count, magic: magicLE)]
        }
    }

    static func isMachO(_ data: Data) -> Bool {
        guard let magicBE = MachOByteReader(data).uint32BE(at: 0), let magicLE = MachOByteReader(data).uint32LE(at: 0) else {
            return false
        }
        return magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF || magicLE == 0xFEEDFACF || magicLE == 0xFEEDFACE
    }

    static func validateInjectedDylib(_ dylibURL: URL) throws {
        let slices = try slices(in: Data(contentsOf: dylibURL))
        guard !slices.isEmpty, slices.allSatisfy({ $0.fileType == .dylib }) else {
            throw MachOScannerError.invalidInjectedDylib("\(dylibURL.path) contains a non-MH_DYLIB slice")
        }
    }

    static func validateAppTopology(appRoot: URL, mainExecutable: URL) throws {
        let root = appRoot.resolvingSymlinksInPath().standardizedFileURL
        let main = mainExecutable.resolvingSymlinksInPath().standardizedFileURL
        guard isDescendant(main, of: root), FileManager.default.fileExists(atPath: main.path) else {
            throw MachOScannerError.invalidTopology("main executable is outside the app bundle")
        }
        guard isMachO(try Data(contentsOf: main)), try slices(in: Data(contentsOf: main)).contains(where: { $0.fileType == .execute }) else {
            throw MachOScannerError.invalidTopology("declared main executable is not MH_EXECUTE")
        }

        for fileURL in try machOFiles(in: appRoot) {
            let executable = try slices(in: Data(contentsOf: fileURL)).contains { $0.fileType == .execute }
            guard executable else { continue }
            let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolved == main else {
                throw MachOScannerError.invalidTopology("nested MH_EXECUTE is unsupported by the single-profile ZSign backend: \(fileURL.path)")
            }
        }
    }

    static func machOFiles(in appRoot: URL) throws -> [URL] {
        let root = appRoot.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: appRoot,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            throw MachOScannerError.invalidTopology("cannot enumerate app bundle")
        }

        var result: [URL] = []
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                let resolved = fileURL.resolvingSymlinksInPath().standardizedFileURL
                guard isDescendant(resolved, of: root) else {
                    throw MachOScannerError.invalidTopology("symlink escapes app bundle: \(fileURL.path)")
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let data = try Data(contentsOf: fileURL)
            // Java class files also begin with CAFEBABE. Treat a magic collision that
            // cannot be parsed as a Mach-O as a regular resource, as ZSign does.
            guard isMachO(data), let slices = try? slices(in: data), !slices.isEmpty else { continue }
            result.append(fileURL)
        }
        return result.sorted { $0.path < $1.path }
    }
}

enum MachOScannerError: LocalizedError {
    case malformed(String)
    case invalidTopology(String)
    case invalidInjectedDylib(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let message), .invalidTopology(let message), .invalidInjectedDylib(let message):
            return message
        }
    }
}

private extension MachOExecutableScanner {
    static func thinSlice(reader: MachOByteReader, offset: Int, size: Int, magic: UInt32) throws -> MachOSlice {
        let headerSize: Int
        switch magic {
        case 0xFEEDFACF:
            headerSize = 32
        case 0xFEEDFACE:
            headerSize = 28
        default:
            throw MachOScannerError.malformed("slice at \(offset) is not a Mach-O")
        }
        guard size >= headerSize, let fileTypeRaw = reader.uint32LE(at: offset + 12) else {
            throw MachOScannerError.malformed("truncated Mach-O header at \(offset)")
        }
        return MachOSlice(offset: offset, size: size, fileType: MachOFileType(rawValue: fileTypeRaw))
    }

    static func fatSlices(reader: MachOByteReader, is64: Bool) throws -> [MachOSlice] {
        guard let countRaw = reader.uint32BE(at: 4) else {
            throw MachOScannerError.malformed("truncated fat header")
        }
        let count = Int(countRaw)
        let archSize = is64 ? 32 : 20
        let headerSize = 8
        guard count <= 128,
              let tableSize = safeMultiply(count, archSize),
              let tableEnd = safeAdd(headerSize, tableSize),
              tableEnd <= reader.count
        else {
            throw MachOScannerError.malformed("fat architecture table is out of range")
        }

        var ranges: [(offset: Int, size: Int)] = []
        for index in 0..<count {
            let base = headerSize + index * archSize
            let offset: Int
            let size: Int
            if is64 {
                guard let rawOffset = reader.uint64BE(at: base + 8), let rawSize = reader.uint64BE(at: base + 16),
                      rawOffset <= UInt64(Int.max), rawSize <= UInt64(Int.max)
                else { throw MachOScannerError.malformed("fat64 architecture entry is malformed") }
                offset = Int(rawOffset)
                size = Int(rawSize)
            } else {
                guard let rawOffset = reader.uint32BE(at: base + 8), let rawSize = reader.uint32BE(at: base + 12) else {
                    throw MachOScannerError.malformed("fat architecture entry is truncated")
                }
                offset = Int(rawOffset)
                size = Int(rawSize)
            }
            guard offset >= headerSize + tableSize, size > 0, let end = safeAdd(offset, size), end <= reader.count else {
                throw MachOScannerError.malformed("fat slice range is outside the file")
            }
            ranges.append((offset, size))
        }
        let sortedRanges = ranges.sorted { $0.offset < $1.offset }
        for pair in zip(sortedRanges, sortedRanges.dropFirst()) {
            guard let end = safeAdd(pair.0.offset, pair.0.size), end <= pair.1.offset else {
                throw MachOScannerError.malformed("fat slices overlap")
            }
        }
        return try ranges.map { range in
            guard let magic = reader.uint32LE(at: range.offset) else {
                throw MachOScannerError.malformed("fat slice is truncated")
            }
            return try thinSlice(reader: reader, offset: range.offset, size: range.size, magic: magic)
        }
    }

    static func isDescendant(_ child: URL, of root: URL) -> Bool {
        child == root || child.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }

    static func safeAdd(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    static func safeMultiply(_ lhs: Int, _ rhs: Int) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }
}

private struct MachOByteReader {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }

    var count: Int { data.count }

    func uint32LE(at offset: Int) -> UInt32? {
        guard let bytes = bytes(at: offset, count: 4) else { return nil }
        return UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
    }

    func uint32BE(at offset: Int) -> UInt32? {
        uint32LE(at: offset).map { $0.byteSwapped }
    }

    func uint64BE(at offset: Int) -> UInt64? {
        guard let high = uint32BE(at: offset), let low = uint32BE(at: offset + 4) else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    private func bytes(at offset: Int, count: Int) -> [UInt8]? {
        guard offset >= 0, count >= 0, let end = MachOExecutableScanner.safeAdd(offset, count), end <= data.count else {
            return nil
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let finish = data.index(start, offsetBy: count)
        return Array(data[start..<finish])
    }
}
