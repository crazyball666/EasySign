import Foundation

/// WS 控制/剪贴板消息。扁平 JSON `{"type": ...}`,跨平台易解析。
enum WireMessage: Equatable {
    case hello(deviceId: String, name: String, version: Int)
    case pairOffer(nonce: String)
    case pairProof(mac: String)
    case pairResult(ok: Bool)
    case clipboardText(text: String, contentHash: String)
    case ack(id: String)

    enum WireError: Error { case unknownType(String); case malformed }

    private struct Envelope: Codable {
        var type: String
        var deviceId: String?
        var name: String?
        var version: Int?
        var nonce: String?
        var mac: String?
        var ok: Bool?
        var text: String?
        var contentHash: String?
        var id: String?
    }

    func encoded() throws -> Data {
        var e = Envelope(type: "")
        switch self {
        case let .hello(deviceId, name, version):
            e.type = "hello"; e.deviceId = deviceId; e.name = name; e.version = version
        case let .pairOffer(nonce):
            e.type = "pairOffer"; e.nonce = nonce
        case let .pairProof(mac):
            e.type = "pairProof"; e.mac = mac
        case let .pairResult(ok):
            e.type = "pairResult"; e.ok = ok
        case let .clipboardText(text, contentHash):
            e.type = "clipboardText"; e.text = text; e.contentHash = contentHash
        case let .ack(id):
            e.type = "ack"; e.id = id
        }
        return try JSONEncoder().encode(e)
    }

    static func decode(_ data: Data) throws -> WireMessage {
        let e = try JSONDecoder().decode(Envelope.self, from: data)
        switch e.type {
        case "hello":
            guard let d = e.deviceId, let n = e.name, let v = e.version else { throw WireError.malformed }
            return .hello(deviceId: d, name: n, version: v)
        case "pairOffer":
            guard let n = e.nonce else { throw WireError.malformed }
            return .pairOffer(nonce: n)
        case "pairProof":
            guard let m = e.mac else { throw WireError.malformed }
            return .pairProof(mac: m)
        case "pairResult":
            guard let ok = e.ok else { throw WireError.malformed }
            return .pairResult(ok: ok)
        case "clipboardText":
            guard let t = e.text, let h = e.contentHash else { throw WireError.malformed }
            return .clipboardText(text: t, contentHash: h)
        case "ack":
            guard let id = e.id else { throw WireError.malformed }
            return .ack(id: id)
        default:
            throw WireError.unknownType(e.type)
        }
    }
}
