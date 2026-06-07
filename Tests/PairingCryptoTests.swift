import Foundation
import CryptoKit

@main
struct PairingCryptoTests {
    static func main() {
        let fpA = "aa11", fpB = "bb22"
        let nA = "n0", nB = "n1"
        let m1 = PairingCrypto.mac(code: "123456", fpSelf: fpA, fpPeer: fpB, nonceSelf: nA, noncePeer: nB)
        let m2 = PairingCrypto.mac(code: "123456", fpSelf: fpB, fpPeer: fpA, nonceSelf: nB, noncePeer: nA)
        expect(m1 == m2, "symmetric MAC")
        expect(PairingCrypto.verify(m2, code: "123456", fpSelf: fpA, fpPeer: fpB, nonceSelf: nA, noncePeer: nB), "verify ok")
        expect(!PairingCrypto.verify(m1, code: "000000", fpSelf: fpA, fpPeer: fpB, nonceSelf: nA, noncePeer: nB), "wrong code rejected")
        let mitm = PairingCrypto.mac(code: "123456", fpSelf: fpA, fpPeer: "mm99", nonceSelf: nA, noncePeer: nB)
        expect(mitm != m1, "mitm differs")
        expect(!PairingCrypto.verify(mitm, code: "123456", fpSelf: fpA, fpPeer: fpB, nonceSelf: nA, noncePeer: nB), "mitm rejected")
        let code = PairingCrypto.makeCode()
        expect(code.count == 6 && code.allSatisfy { $0.isNumber }, "code format: \(code)")
        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) {
        if !c { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
    }
}
