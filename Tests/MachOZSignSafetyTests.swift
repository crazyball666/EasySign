//
//  MachOZSignSafetyTests.swift
//
//  Run:
//    swiftc -o /tmp/easysign-macho-zsign-tests \
//      EasySign/Core/Resigning/Model/MachOExecutableScanner.swift \
//      Tests/MachOZSignSafetyTests.swift && /tmp/easysign-macho-zsign-tests
//

import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() {
        print("PASS  \(name)")
    } else {
        failures += 1
        print("FAIL  \(name)")
    }
}

private func expectThrows(_ name: String, _ body: () throws -> Void) {
    do {
        try body()
        failures += 1
        print("FAIL  \(name)")
    } catch {
        print("PASS  \(name): \(error.localizedDescription)")
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)
        ])
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        appendUInt32LE(value.byteSwapped)
    }
}

private func thinMachO(fileType: UInt32, cpuType: UInt32 = 0x0100000C) -> Data {
    var result = Data()
    result.appendUInt32LE(0xFEEDFACF) // MH_MAGIC_64
    result.appendUInt32LE(cpuType)
    result.appendUInt32LE(0)
    result.appendUInt32LE(fileType)
    result.appendUInt32LE(0) // ncmds
    result.appendUInt32LE(0) // sizeofcmds
    result.appendUInt32LE(0)
    result.appendUInt32LE(0)
    return result
}

private func fatMachO(_ slices: [(UInt32, Data)]) -> Data {
    var result = Data()
    result.appendUInt32BE(0xCAFEBABE)
    result.appendUInt32BE(UInt32(slices.count))
    var offset = 8 + slices.count * 20
    for (cpuType, slice) in slices {
        result.appendUInt32BE(cpuType)
        result.appendUInt32BE(0)
        result.appendUInt32BE(UInt32(offset))
        result.appendUInt32BE(UInt32(slice.count))
        result.appendUInt32BE(0)
        offset += slice.count
    }
    for (_, slice) in slices { result.append(slice) }
    return result
}

private func write(_ data: Data, to path: URL) throws {
    try data.write(to: path)
}

@main
struct MachOZSignSafetyTests {
    static func main() {
        do {
            let slices = try MachOExecutableScanner.slices(in: thinMachO(fileType: MachOFileType.execute.rawValue))
            expect(slices.count == 1 && slices[0].fileType == .execute, "thin executable is classified as MH_EXECUTE")
        } catch {
            failures += 1
            print("FAIL  thin execute classification: \(error)")
        }

        do {
            let fat = fatMachO([
                (0x0100000C, thinMachO(fileType: MachOFileType.dylib.rawValue)),
                (0x01000007, thinMachO(fileType: MachOFileType.dylib.rawValue, cpuType: 0x01000007))
            ])
            let slices = try MachOExecutableScanner.slices(in: fat)
            expect(slices.count == 2 && slices.allSatisfy { $0.fileType == .dylib }, "fat binary reports every dylib slice")
        } catch {
            failures += 1
            print("FAIL  fat dylib classification: \(error)")
        }

        var invalidFat = Data()
        invalidFat.appendUInt32BE(0xCAFEBABE)
        invalidFat.appendUInt32BE(1)
        invalidFat.appendUInt32BE(0x0100000C)
        invalidFat.appendUInt32BE(0)
        invalidFat.appendUInt32BE(0xFFFFFFF0)
        invalidFat.appendUInt32BE(32)
        invalidFat.appendUInt32BE(0)
        expectThrows("out-of-range fat slice is rejected without a crash") {
            _ = try MachOExecutableScanner.slices(in: invalidFat)
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("EasySign-MachOTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let app = root.appendingPathComponent("Payload/Test.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let main = app.appendingPathComponent("Test")
            try write(thinMachO(fileType: MachOFileType.execute.rawValue), to: main)
            try MachOExecutableScanner.validateAppTopology(appRoot: app, mainExecutable: main)
            expect(true, "app topology accepts only the declared main executable")

            let nested = app.appendingPathComponent("Frameworks/Bad.framework/Bad")
            try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(thinMachO(fileType: MachOFileType.execute.rawValue), to: nested)
            expectThrows("nested MH_EXECUTE is rejected before ZSign recursive signing") {
                try MachOExecutableScanner.validateAppTopology(appRoot: app, mainExecutable: main)
            }

            try FileManager.default.removeItem(at: nested.deletingLastPathComponent())
            let hiddenExecutable = app.appendingPathComponent(".helper")
            try write(thinMachO(fileType: MachOFileType.execute.rawValue), to: hiddenExecutable)
            expectThrows("hidden nested MH_EXECUTE is rejected before ZSign recursive signing") {
                try MachOExecutableScanner.validateAppTopology(appRoot: app, mainExecutable: main)
            }

            try FileManager.default.removeItem(at: hiddenExecutable)
            let resourceDirectory = app.appendingPathComponent("Resources")
            try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
            let javaClass = resourceDirectory.appendingPathComponent("NotMachO.class")
            // Java class-file magic followed by a plausible class-file version. This is
            // not a valid fat-Mach-O header, despite sharing the first four bytes.
            try write(Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 0x34]), to: javaClass)
            try MachOExecutableScanner.validateAppTopology(appRoot: app, mainExecutable: main)
            expect(true, "non-Mach-O CAFEBABE resource does not abort topology validation")

            let outside = root.appendingPathComponent("outside.dylib")
            try write(thinMachO(fileType: MachOFileType.dylib.rawValue), to: outside)
            try FileManager.default.createSymbolicLink(at: app.appendingPathComponent("escape.dylib"), withDestinationURL: outside)
            expectThrows("symlink escaping app root is rejected") {
                try MachOExecutableScanner.validateAppTopology(appRoot: app, mainExecutable: main)
            }
        } catch {
            failures += 1
            print("FAIL  app topology test setup: \(error)")
        }

        do {
            let dylib = root.appendingPathComponent("Inject.dylib")
            try write(fatMachO([
                (0x0100000C, thinMachO(fileType: MachOFileType.dylib.rawValue)),
                (0x01000007, thinMachO(fileType: MachOFileType.dylib.rawValue, cpuType: 0x01000007))
            ]), to: dylib)
            try MachOExecutableScanner.validateInjectedDylib(dylib)
            expect(true, "all-dylib fat injection is accepted")

            try write(fatMachO([
                (0x0100000C, thinMachO(fileType: MachOFileType.dylib.rawValue)),
                (0x01000007, thinMachO(fileType: MachOFileType.execute.rawValue, cpuType: 0x01000007))
            ]), to: dylib)
            expectThrows("injected library with an executable slice is rejected") {
                try MachOExecutableScanner.validateInjectedDylib(dylib)
            }
        } catch {
            failures += 1
            print("FAIL  injected dylib test setup: \(error)")
        }

        if failures == 0 {
            print("ALL PASS")
        } else {
            print("\(failures) FAILURES")
            exit(1)
        }
    }
}
