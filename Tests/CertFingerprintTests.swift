import Foundation
import CryptoKit

@main
struct CertFingerprintTests {
    static func main() {
        let empty = CertFingerprint.sha256Hex(of: Data())
        expect(empty == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
               "empty sha256: \(empty)")
        let abc = CertFingerprint.sha256Hex(of: Data("abc".utf8))
        expect(abc == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
               "abc sha256: \(abc)")
        expect(CertFingerprint.sha256Hex(of: Data([0x00, 0xff, 0x10])).count == 64, "len 64")
        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    }
}
