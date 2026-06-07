import Foundation
import Security

@main
struct DeviceIdentityTests {
    static func main() throws {
        let mat = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-test")
        expect(!mat.p12Data.isEmpty, "p12 not empty")
        expect(mat.fingerprint.count == 64, "fingerprint 64 hex: \(mat.fingerprint)")

        let imported = try DeviceIdentity.importIdentity(p12Data: mat.p12Data, passphrase: mat.passphrase)
        expect(imported.fingerprint == mat.fingerprint, "fingerprint stable after import")

        var key: SecKey?
        let st = SecIdentityCopyPrivateKey(imported.identity, &key)
        expect(st == errSecSuccess && key != nil, "identity has private key")

        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    }
}
