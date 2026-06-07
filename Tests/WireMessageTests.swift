import Foundation

@main
struct WireMessageTests {
    static func main() throws {
        let hello = WireMessage.hello(deviceId: "dev-1", name: "我的 Mac", version: 1)
        let data = try hello.encoded()
        expect(try WireMessage.decode(data) == hello, "hello round-trip")
        let clip = WireMessage.clipboardText(text: "hello 世界", contentHash: "abc123")
        expect(try WireMessage.decode(clip.encoded()) == clip, "clip round-trip")
        expect(try WireMessage.decode(WireMessage.pairOffer(nonce: "ff00").encoded()) == .pairOffer(nonce: "ff00"), "pairOffer")
        expect(try WireMessage.decode(WireMessage.pairProof(mac: "deadbeef").encoded()) == .pairProof(mac: "deadbeef"), "pairProof")
        expect(try WireMessage.decode(WireMessage.pairResult(ok: true).encoded()) == .pairResult(ok: true), "pairResult")
        expect(try WireMessage.decode(WireMessage.ack(id: "x").encoded()) == .ack(id: "x"), "ack")
        let fOffer = WireMessage.fileOffer(id: "f1", name: "报告.pdf", size: 123_456)
        expect(try WireMessage.decode(fOffer.encoded()) == fOffer, "fileOffer round-trip")
        let fDone = WireMessage.fileComplete(id: "f1")
        expect(try WireMessage.decode(fDone.encoded()) == fDone, "fileComplete round-trip")
        let imgOffer = WireMessage.clipboardImageOffer(id: "img1", size: 9001, hash: "deadbeef")
        expect(try WireMessage.decode(imgOffer.encoded()) == imgOffer, "clipboardImageOffer round-trip")
        let json = String(data: data, encoding: .utf8)!
        expect(json.contains("\"type\""), "has type field")
        expect(json.contains("hello"), "type value present")
        let unknown = Data(#"{"type":"weird"}"#.utf8)
        do { _ = try WireMessage.decode(unknown); fail("should throw on unknown type") } catch {}
        print("ALL PASS")
    }
    static func expect(_ c: Bool, _ m: String) { if !c { fail(m) } }
    static func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1) }
}
