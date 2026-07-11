//
//  MachOEntitlementsTests.swift
//  合成最小 Mach-O(thin / fat / 各种坏数据)验证 MachOEntitlementsReader,
//  顺带验证 IPAPreviewPlistFormatter 的 Bool/嵌套格式化。
//
//  运行:
//    swiftc -o /tmp/t Packages/PreviewKit/Sources/PreviewKit/IPAPreviewService.swift \
//      Packages/PreviewKit/Sources/PreviewKit/MachOEntitlementsReader.swift \
//      Tests/MachOEntitlementsTests.swift && /tmp/t [可选:真实二进制路径...]
//

import Foundation

private var failures = 0

private func expect(_ condition: Bool, _ name: String) {
    if condition {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        appendUInt32LE(value.byteSwapped)
    }
}

/// 构造一个只有 LC_CODE_SIGNATURE 的最小 64 位 Mach-O,签名里塞给定 entitlements plist
private func makeThinMachO(entitlementsXML: String?, cputype: UInt32 = 0x0100000C) -> Data {
    let plist = entitlementsXML.map { Data($0.utf8) }

    var superBlob = Data()
    if let plist {
        let blobLength = UInt32(8 + plist.count)
        superBlob.appendUInt32BE(0xFADE0CC0)              // CSMAGIC_EMBEDDED_SIGNATURE
        superBlob.appendUInt32BE(UInt32(12 + 8) + blobLength)
        superBlob.appendUInt32BE(1)                        // count
        superBlob.appendUInt32BE(5)                        // CSSLOT_ENTITLEMENTS
        superBlob.appendUInt32BE(20)                       // blob 相对 superblob 偏移
        superBlob.appendUInt32BE(0xFADE7171)              // CSMAGIC_EMBEDDED_ENTITLEMENTS
        superBlob.appendUInt32BE(blobLength)
        superBlob.append(plist)
    }

    var machO = Data()
    machO.appendUInt32LE(0xFEEDFACF)   // MH_MAGIC_64
    machO.appendUInt32LE(cputype)
    machO.appendUInt32LE(0)            // cpusubtype
    machO.appendUInt32LE(2)            // filetype MH_EXECUTE
    machO.appendUInt32LE(1)            // ncmds
    machO.appendUInt32LE(16)           // sizeofcmds
    machO.appendUInt32LE(0)            // flags
    machO.appendUInt32LE(0)            // reserved → header 共 32 字节
    machO.appendUInt32LE(0x1D)         // LC_CODE_SIGNATURE
    machO.appendUInt32LE(16)           // cmdsize
    machO.appendUInt32LE(48)           // dataoff(header 32 + lc 16)
    machO.appendUInt32LE(UInt32(superBlob.count))
    machO.append(superBlob)
    return machO
}

/// 构造一个完全没有 LC_CODE_SIGNATURE 的 Mach-O(ncmds=0),
/// 用来真正走 reader 遍历 load command「找不到签名段」的分支
private func makeMachOWithoutCodeSignature(cputype: UInt32 = 0x0100000C) -> Data {
    var machO = Data()
    machO.appendUInt32LE(0xFEEDFACF)   // MH_MAGIC_64
    machO.appendUInt32LE(cputype)
    machO.appendUInt32LE(0)            // cpusubtype
    machO.appendUInt32LE(2)            // filetype MH_EXECUTE
    machO.appendUInt32LE(0)            // ncmds = 0(没有任何 load command)
    machO.appendUInt32LE(0)            // sizeofcmds
    machO.appendUInt32LE(0)            // flags
    machO.appendUInt32LE(0)            // reserved → header 共 32 字节
    return machO
}

/// 把若干 thin 切片包成 fat 二进制
private func makeFat(slices: [(cputype: UInt32, data: Data)]) -> Data {
    var fat = Data()
    fat.appendUInt32BE(0xCAFEBABE)
    fat.appendUInt32BE(UInt32(slices.count))
    var offset = 8 + slices.count * 20
    // 对齐到 8 字节,好看一点(reader 不要求)
    offset = (offset + 7) & ~7
    var offsets: [Int] = []
    for slice in slices {
        offsets.append(offset)
        fat.appendUInt32BE(slice.cputype)
        fat.appendUInt32BE(0)                       // cpusubtype
        fat.appendUInt32BE(UInt32(offset))
        fat.appendUInt32BE(UInt32(slice.data.count))
        fat.appendUInt32BE(3)                       // align
        offset += slice.data.count
        offset = (offset + 7) & ~7
    }
    for (index, slice) in slices.enumerated() {
        while fat.count < offsets[index] {
            fat.append(0)
        }
        fat.append(slice.data)
    }
    return fat
}

private func entitlementsXML(_ body: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>\(body)</dict></plist>
    """
}

@main
struct MachOEntitlementsTests {
    static func main() {
        let sandboxXML = entitlementsXML("""
        <key>com.apple.security.app-sandbox</key><true/>
        <key>application-identifier</key><string>TEAM.com.example.app</string>
        <key>com.apple.developer.associated-domains</key><array><string>applinks:example.com</string></array>
        """)

        // thin Mach-O
        let thin = makeThinMachO(entitlementsXML: sandboxXML)
        let thinResult = MachOEntitlementsReader.entitlements(from: thin)
        expect(thinResult?["com.apple.security.app-sandbox"] as? Bool == true, "thin: 读出 sandbox entitlement")
        expect(thinResult?["application-identifier"] as? String == "TEAM.com.example.app", "thin: 读出 application-identifier")
        expect(thinResult?.count == 3, "thin: entitlements 数量正确")

        // 无签名 Mach-O(datasize=0 空 superblob)
        let unsigned = makeThinMachO(entitlementsXML: nil)
        expect(MachOEntitlementsReader.entitlements(from: unsigned) == nil, "thin: 空签名段返回 nil")

        // 完全没有 LC_CODE_SIGNATURE(真正的未签名/裸二进制),走遍历找不到的分支
        let noSig = makeMachOWithoutCodeSignature()
        expect(MachOEntitlementsReader.entitlements(from: noSig) == nil, "thin: 无 LC_CODE_SIGNATURE 返回 nil")

        // fat:x86_64 切片无 entitlements、arm64 有 → 必须选 arm64
        let x86XML = entitlementsXML("<key>marker</key><string>x86_64</string>")
        let fat = makeFat(slices: [
            (cputype: 0x01000007, data: makeThinMachO(entitlementsXML: x86XML, cputype: 0x01000007)),
            (cputype: 0x0100000C, data: makeThinMachO(entitlementsXML: sandboxXML))
        ])
        let fatResult = MachOEntitlementsReader.entitlements(from: fat)
        expect(fatResult?["com.apple.security.app-sandbox"] as? Bool == true, "fat: 优先取 arm64 切片")
        expect(fatResult?["marker"] == nil, "fat: 没有误取 x86_64 切片")

        // fat 里只有 x86_64 → 回落到第一个切片
        let fatX86Only = makeFat(slices: [
            (cputype: 0x01000007, data: makeThinMachO(entitlementsXML: x86XML, cputype: 0x01000007))
        ])
        expect(MachOEntitlementsReader.entitlements(from: fatX86Only)?["marker"] as? String == "x86_64", "fat: 无 arm64 时回落第一个切片")

        // 坏数据不崩溃
        expect(MachOEntitlementsReader.entitlements(from: Data()) == nil, "空数据返回 nil")
        expect(MachOEntitlementsReader.entitlements(from: Data([0xFE, 0xED])) == nil, "截断数据返回 nil")
        expect(MachOEntitlementsReader.entitlements(from: thin.prefix(40)) == nil, "截断在 load command 中间返回 nil")
        var badBlob = makeThinMachO(entitlementsXML: sandboxXML)
        badBlob[48] = 0xFF  // 破坏 superblob magic(superblob 起点 = header 32 + lc 16)
        expect(MachOEntitlementsReader.entitlements(from: badBlob) == nil, "superblob magic 损坏返回 nil")

        // Data 切片(startIndex != 0)也能正确解析
        var padded = Data([0xAA, 0xBB, 0xCC])
        padded.append(thin)
        let slice = padded.dropFirst(3)
        expect(MachOEntitlementsReader.entitlements(from: slice)?.count == 3, "非零 startIndex 的 Data 切片解析正确")

        // fat64 的 arch offset 是攻击者可控的完整 UInt64;接近 UInt64.max 时
        // 边界检查若写成 offset+4 会算术溢出 trap。这里断言只返回 nil、不崩溃。
        var fat64 = Data()
        fat64.appendUInt32BE(0xCAFEBABF)              // FAT_MAGIC_64
        fat64.appendUInt32BE(1)                        // nfat_arch = 1
        fat64.appendUInt32BE(0x0100000C)              // cputype arm64
        fat64.appendUInt32BE(0)                        // cpusubtype
        fat64.appendUInt32BE(0xFFFFFFFF)              // offset 高 32 位
        fat64.appendUInt32BE(0xFFFFFFFF)              // offset 低 32 位 → 0xFFFFFFFFFFFFFFFF
        fat64.appendUInt32BE(0)                        // size 高
        fat64.appendUInt32BE(0)                        // size 低
        fat64.appendUInt32BE(0)                        // align
        fat64.appendUInt32BE(0)                        // reserved
        expect(MachOEntitlementsReader.entitlements(from: fat64) == nil, "fat64 越界 offset 返回 nil 而非崩溃")

        // 格式化器:Bool 不显示成 1,数组/字典缩进展开,多行拆分
        let lines = IPAPreviewPlistFormatter.lines(from: [
            "b": true,
            "n": 42,
            "arr": ["x", "y"],
            "dict": ["inner": false]
        ])
        expect(lines.contains("b = true"), "formatter: Bool 显示 true")
        expect(lines.contains("n = 42"), "formatter: 数字显示 42")
        expect(lines.contains("arr = (") && lines.contains("    x"), "formatter: 数组缩进展开")
        expect(lines.contains("    inner = false"), "formatter: 嵌套字典展开")
        expect(!lines.contains(where: { $0.contains("\n") }), "formatter: 行内不含换行符")

        // 可选:传真实二进制路径做对照(不计入断言)
        for path in CommandLine.arguments.dropFirst() {
            let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            let keys = MachOEntitlementsReader.entitlements(from: data)?.keys.sorted() ?? []
            print("INFO  \(path): \(keys.count) entitlements \(keys)")
        }

        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILURES")
            exit(1)
        }
    }
}
