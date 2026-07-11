//
//  MachOCodeSignatureInspectorTests.swift
//
//  Run:
//    swiftc -o /tmp/easysign-code-signature-tests \
//      EasySign/Core/Resigning/Model/MachOExecutableScanner.swift \
//      EasySign/Core/Resigning/Model/MachOCodeSignatureInspector.swift \
//      Tests/MachOCodeSignatureInspectorTests.swift && /tmp/easysign-code-signature-tests
//

import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
}

private func expectThrows(_ name: String, _ body: () throws -> Void) {
    do { try body(); failures += 1; print("FAIL  \(name)") }
    catch { print("PASS  \(name): \(error.localizedDescription)") }
}

private func expectThrowsContaining(_ expectedMessage: String, _ name: String, _ body: () throws -> Void) {
    do {
        try body()
        failures += 1
        print("FAIL  \(name)")
    } catch {
        expect(error.localizedDescription.contains(expectedMessage), name)
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xff), UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)
        ])
    }
    mutating func appendUInt32BE(_ value: UInt32) { appendUInt32LE(value.byteSwapped) }
    mutating func appendUInt64BE(_ value: UInt64) {
        appendUInt32BE(UInt32(value >> 32)); appendUInt32BE(UInt32(value & 0xffff_ffff))
    }
}

private func derLength(_ length: Int) -> Data {
    precondition(length < 128)
    return Data([UInt8(length)])
}

private func der(_ tag: UInt8, _ payload: Data) -> Data {
    var result = Data([tag]); result.append(derLength(payload.count)); result.append(payload); return result
}

private func derValue(_ value: Any) -> Data {
    // ZSign's `_DER` encodes true as 0x01 rather than 0xFF.
    if let bool = value as? Bool { return der(0x01, Data([bool ? 1 : 0])) }
    if let string = value as? String { return der(0x0c, Data(string.utf8)) }
    if let array = value as? [Any] { return der(0x30, array.reduce(into: Data()) { $0.append(derValue($1)) }) }
    let dictionary = value as! [String: Any]
    var payload = Data()
    for key in dictionary.keys.sorted() {
        var entry = Data(); entry.append(der(0x0c, Data(key.utf8))); entry.append(derValue(dictionary[key]!)); payload.append(der(0x30, entry))
    }
    return der(0x31, payload)
}

private func blob(magic: UInt32, payload: Data) -> Data {
    var result = Data(); result.appendUInt32BE(magic); result.appendUInt32BE(UInt32(payload.count + 8)); result.append(payload); return result
}

private func codeDirectory(identifier: String, team: String, execSegFlags: UInt64) -> Data {
    let identity = Data(identifier.utf8) + Data([0])
    let teamID = Data(team.utf8) + Data([0])
    let headerLength = 88
    let totalLength = headerLength + identity.count + teamID.count
    var result = Data()
    result.appendUInt32BE(0xfade0c02); result.appendUInt32BE(UInt32(totalLength)); result.appendUInt32BE(0x20400)
    result.appendUInt32BE(0); result.appendUInt32BE(0); result.appendUInt32BE(UInt32(headerLength))
    result.appendUInt32BE(0); result.appendUInt32BE(0); result.appendUInt32BE(0)
    result.append(contentsOf: [0, 0, 0, 0])
    result.appendUInt32BE(0); result.appendUInt32BE(0); result.appendUInt32BE(UInt32(headerLength + identity.count))
    result.appendUInt32BE(0); result.appendUInt64BE(0); result.appendUInt64BE(0); result.appendUInt64BE(0); result.appendUInt64BE(execSegFlags)
    result.append(identity); result.append(teamID)
    return result
}

private func signedMachO(
    xmlEntitlements: [String: Any],
    derEntitlements: [String: Any],
    execSegFlags: UInt64 = 0,
    signaturePadding: Int = 0,
    derBlobExtendsIntoSignaturePadding: Bool = false
) -> Data {
    let xmlData = try! PropertyListSerialization.data(fromPropertyList: xmlEntitlements, format: .xml, options: 0)
    let code = codeDirectory(identifier: "com.example.app", team: "TEAM", execSegFlags: execSegFlags)
    let blobs: [(UInt32, Data)] = [
        (0, code),
        (5, blob(magic: 0xfade7171, payload: xmlData)),
        (7, blob(magic: 0xfade7172, payload: derValue(derEntitlements)))
    ]
    let headerSize = 12 + blobs.count * 8
    var superBlob = Data(); superBlob.appendUInt32BE(0xfade0cc0); superBlob.appendUInt32BE(UInt32(headerSize + blobs.reduce(0) { $0 + $1.1.count })); superBlob.appendUInt32BE(UInt32(blobs.count))
    var offset = headerSize
    var offsets: [Int] = []
    for (slot, data) in blobs {
        offsets.append(offset)
        superBlob.appendUInt32BE(slot)
        superBlob.appendUInt32BE(UInt32(offset))
        offset += data.count
    }
    for (_, data) in blobs { superBlob.append(data) }
    if derBlobExtendsIntoSignaturePadding {
        let derOffset = offsets[2]
        let extendedLength = superBlob.count + signaturePadding - derOffset
        superBlob.replaceSubrange((derOffset + 4)..<(derOffset + 8), with: Data([
            UInt8((extendedLength >> 24) & 0xff), UInt8((extendedLength >> 16) & 0xff),
            UInt8((extendedLength >> 8) & 0xff), UInt8(extendedLength & 0xff)
        ]))
    }

    var macho = Data()
    macho.appendUInt32LE(0xfeedfacf); macho.appendUInt32LE(0x0100000c); macho.appendUInt32LE(0); macho.appendUInt32LE(2)
    macho.appendUInt32LE(1); macho.appendUInt32LE(16); macho.appendUInt32LE(0); macho.appendUInt32LE(0)
    macho.appendUInt32LE(0x1d); macho.appendUInt32LE(16); macho.appendUInt32LE(48); macho.appendUInt32LE(UInt32(superBlob.count + signaturePadding))
    macho.append(superBlob)
    macho.append(Data(repeating: 0, count: signaturePadding))
    return macho
}

@main
struct MachOCodeSignatureInspectorTests {
    static func main() {
        let expected: [String: Any] = [
            "application-identifier": "PREFIX.com.example.app",
            "com.apple.developer.team-identifier": "TEAM",
            "aps-environment": "production"
        ]
        do {
            try MachOCodeSignatureInspector.inspectMainExecutable(
                in: signedMachO(xmlEntitlements: expected, derEntitlements: expected),
                expectedEntitlements: expected,
                expectedIdentifier: "com.example.app",
                expectedTeamIdentifier: "TEAM"
            )
            expect(true, "main executable accepts matching XML, DER and CodeDirectory identity")
        } catch {
            failures += 1; print("FAIL  valid signature inspection: \(error)")
        }

        do {
            try MachOCodeSignatureInspector.inspectMainExecutable(
                in: signedMachO(xmlEntitlements: expected, derEntitlements: expected, signaturePadding: 32 * 1024),
                expectedEntitlements: expected,
                expectedIdentifier: "com.example.app",
                expectedTeamIdentifier: "TEAM"
            )
            expect(true, "main executable accepts ZSign code-signature allocation padding")
        } catch {
            failures += 1; print("FAIL  ZSign code-signature allocation padding: \(error)")
        }

        expectThrowsContaining("Code Signature SuperBlob entry is invalid", "SuperBlob entries cannot extend into ZSign allocation padding") {
            try MachOCodeSignatureInspector.inspectMainExecutable(
                in: signedMachO(
                    xmlEntitlements: expected,
                    derEntitlements: expected,
                    signaturePadding: 32 * 1024,
                    derBlobExtendsIntoSignaturePadding: true
                ),
                expectedEntitlements: expected,
                expectedIdentifier: "com.example.app",
                expectedTeamIdentifier: "TEAM"
            )
        }

        expectThrows("DER entitlement mismatch is rejected") {
            let wrongDER = expected.merging(["aps-environment": "development"]) { _, new in new }
            try MachOCodeSignatureInspector.inspectMainExecutable(
                in: signedMachO(xmlEntitlements: expected, derEntitlements: wrongDER),
                expectedEntitlements: expected,
                expectedIdentifier: "com.example.app",
                expectedTeamIdentifier: "TEAM"
            )
        }

        expectThrows("allow-unsigned exec segment flag is rejected without get-task-allow") {
            try MachOCodeSignatureInspector.inspectMainExecutable(
                in: signedMachO(xmlEntitlements: expected, derEntitlements: expected, execSegFlags: 0x10),
                expectedEntitlements: expected,
                expectedIdentifier: "com.example.app",
                expectedTeamIdentifier: "TEAM"
            )
        }

        do {
            let unsignedDylib = Data([0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
            try MachOCodeSignatureInspector.inspectNonExecutableMachO(in: unsignedDylib)
            expect(true, "unsigned non-executable Mach-O is accepted")
        } catch {
            failures += 1; print("FAIL  unsigned dylib inspection: \(error)")
        }

        if failures == 0 { print("ALL PASS") } else { print("\(failures) FAILURES"); exit(1) }
    }
}
