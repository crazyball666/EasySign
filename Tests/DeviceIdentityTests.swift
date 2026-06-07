import Foundation
import Security

@main
struct DeviceIdentityTests {
    static func main() throws {
        let mat = try DeviceIdentity.generateSelfSigned(commonName: "EasySign-test")
        expect(!mat.certDER.isEmpty, "cert DER not empty")
        expect(mat.keyX963.count == 97, "P-256 x963 private key is 97 bytes (04‖X‖Y‖K): \(mat.keyX963.count)")
        expect(mat.fingerprint.count == 64, "fingerprint 64 hex: \(mat.fingerprint)")

        let imported = try DeviceIdentity.importIdentity(certDER: mat.certDER, keyX963: mat.keyX963)
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
