//
//  MachOEntitlementsReader.swift
//  EasySign
//
//  从可执行文件的 LC_CODE_SIGNATURE → SuperBlob → Entitlements Blob
//  中抽出实际签入的 entitlements(描述文件里声明的不等于签进去的,
//  排查重签后权限丢失时要看这个)。所有解析失败都静默返回 nil。
//

import Foundation

enum MachOEntitlementsReader {
    /// 返回格式化好的 "key = value" 行;可执行文件里没有 entitlements 或解析失败返回 []
    static func entitlementLines(fromExecutable data: Data) -> [String] {
        guard let entitlements = entitlements(from: data), !entitlements.isEmpty else {
            return []
        }
        return IPAPreviewPlistFormatter.lines(from: entitlements)
    }

    static func entitlements(from data: Data) -> [String: Any]? {
        guard let plistData = entitlementsPlistData(from: data, sliceOffset: 0) else {
            return nil
        }
        return (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any]
    }
}

private extension MachOEntitlementsReader {
    // Mach-O / fat 头魔数(按文件里的小端读出来的值)
    static let machMagic64: UInt32 = 0xFEEDFACF
    static let machMagic32: UInt32 = 0xFEEDFACE
    // fat 头是大端存储
    static let fatMagic: UInt32 = 0xCAFEBABE
    static let fatMagic64: UInt32 = 0xCAFEBABF
    static let cpuTypeArm64: UInt32 = 0x0100000C

    static let lcCodeSignature: UInt32 = 0x1D
    // Code Signing blob 一律大端
    static let csMagicEmbeddedSignature: UInt32 = 0xFADE0CC0
    static let csMagicEmbeddedEntitlements: UInt32 = 0xFADE7171
    static let csSlotEntitlements: UInt32 = 5

    /// sliceOffset:当前解析的 Mach-O 切片在整个文件里的起点(fat 二进制递归用)
    static func entitlementsPlistData(from data: Data, sliceOffset: UInt64) -> Data? {
        guard let magicLE = uint32LE(data, at: sliceOffset), let magicBE = uint32BE(data, at: sliceOffset) else {
            return nil
        }

        // fat 二进制:优先 arm64 切片,找不到就取第一个
        if magicBE == fatMagic || magicBE == fatMagic64 {
            guard sliceOffset == 0 else {
                return nil  // fat 套 fat,异常文件
            }
            return fatSliceEntitlements(from: data, is64: magicBE == fatMagic64)
        }

        let is64: Bool
        switch magicLE {
        case machMagic64:
            is64 = true
        case machMagic32:
            is64 = false
        default:
            return nil
        }

        let headerSize: UInt64 = is64 ? 32 : 28
        guard let ncmds = uint32LE(data, at: sliceOffset + 16) else {
            return nil
        }

        // 遍历 load commands 找 LC_CODE_SIGNATURE(linkedit_data_command)
        var cursor = sliceOffset + headerSize
        for _ in 0..<ncmds {
            guard let cmd = uint32LE(data, at: cursor),
                  let cmdsize = uint32LE(data, at: cursor + 4),
                  cmdsize >= 8
            else {
                return nil
            }
            if cmd == lcCodeSignature {
                guard let dataoff = uint32LE(data, at: cursor + 8) else {
                    return nil
                }
                return superBlobEntitlements(from: data, superBlobOffset: sliceOffset + UInt64(dataoff))
            }
            cursor += UInt64(cmdsize)
        }
        return nil
    }

    static func fatSliceEntitlements(from data: Data, is64: Bool) -> Data? {
        guard let count = uint32BE(data, at: 4) else {
            return nil
        }
        let archSize: UInt64 = is64 ? 32 : 20

        var firstSliceOffset: UInt64?
        for index in 0..<UInt64(count) {
            let archBase = 8 + index * archSize
            guard let cputype = uint32BE(data, at: archBase) else {
                return nil
            }
            let offset: UInt64?
            if is64 {
                offset = uint64BE(data, at: archBase + 8)
            } else {
                offset = uint32BE(data, at: archBase + 8).map(UInt64.init)
            }
            guard let offset else {
                return nil
            }
            if cputype == cpuTypeArm64 {
                return entitlementsPlistData(from: data, sliceOffset: offset)
            }
            if firstSliceOffset == nil {
                firstSliceOffset = offset
            }
        }
        return firstSliceOffset.flatMap { entitlementsPlistData(from: data, sliceOffset: $0) }
    }

    static func superBlobEntitlements(from data: Data, superBlobOffset: UInt64) -> Data? {
        guard uint32BE(data, at: superBlobOffset) == csMagicEmbeddedSignature,
              let count = uint32BE(data, at: superBlobOffset + 8)
        else {
            return nil
        }

        for index in 0..<UInt64(count) {
            let entryBase = superBlobOffset + 12 + index * 8
            guard let slotType = uint32BE(data, at: entryBase),
                  let slotOffset = uint32BE(data, at: entryBase + 4)
            else {
                return nil
            }
            guard slotType == csSlotEntitlements else {
                continue
            }

            let blobBase = superBlobOffset + UInt64(slotOffset)
            guard uint32BE(data, at: blobBase) == csMagicEmbeddedEntitlements,
                  let blobLength = uint32BE(data, at: blobBase + 4),
                  blobLength > 8
            else {
                return nil
            }
            let plistStart = blobBase + 8
            let plistLength = UInt64(blobLength) - 8
            guard plistStart + plistLength <= UInt64(data.count) else {
                return nil
            }
            let start = data.startIndex + Int(plistStart)
            return data[start..<(start + Int(plistLength))]
        }
        return nil
    }

    // 带边界检查的取整数;offset 是相对 data 起点的绝对偏移。
    // fat64 的 arch offset 是攻击者可控的完整 UInt64,直接写 offset + 4 会在
    // offset 接近 UInt64.max 时算术溢出触发 trap,所以用减法做无溢出的边界判断。
    static func uint32LE(_ data: Data, at offset: UInt64) -> UInt32? {
        let count = UInt64(data.count)
        guard count >= 4, offset <= count - 4 else {
            return nil
        }
        let base = data.startIndex + Int(offset)
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    static func uint32BE(_ data: Data, at offset: UInt64) -> UInt32? {
        uint32LE(data, at: offset).map { $0.byteSwapped }
    }

    static func uint64BE(_ data: Data, at offset: UInt64) -> UInt64? {
        guard let high = uint32BE(data, at: offset), let low = uint32BE(data, at: offset + 4) else {
            return nil
        }
        return (UInt64(high) << 32) | UInt64(low)
    }
}
