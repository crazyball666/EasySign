import Foundation

/// Standalone test for TransferItem Codable roundtrip + TransferHistoryStore.pruning.
@main
struct TransferHistoryStoreTests {
    static func main() {
        // ---- Codable roundtrip (incl. localURL, kind, direction) --------------------
        let items: [TransferItem] = [
            TransferItem(id: UUID(), kind: .text, direction: .outgoing,
                         timestamp: Date(timeIntervalSince1970: 1_000_000),
                         preview: "hello 世界", peerName: "DeviceA", localURL: nil),
            TransferItem(id: UUID(), kind: .image, direction: .incoming,
                         timestamp: Date(timeIntervalSince1970: 2_000_000),
                         preview: "图片", peerName: "DeviceB",
                         localURL: URL(fileURLWithPath: "/tmp/eztx/image.png")),
            TransferItem(id: UUID(), kind: .file, direction: .incoming,
                         timestamp: Date(timeIntervalSince1970: 3_000_000),
                         preview: "doc.pdf", peerName: "DeviceB",
                         localURL: URL(fileURLWithPath: "/tmp/eztx/doc.pdf")),
        ]
        let data: Data
        do { data = try JSONEncoder().encode(items) }
        catch { return fail("encode threw: \(error)") }
        let decoded: [TransferItem]
        do { decoded = try JSONDecoder().decode([TransferItem].self, from: data) }
        catch { return fail("decode threw: \(error)") }

        expect(decoded == items, "roundtrip equality (Equatable) holds")
        expect(decoded.count == 3, "decoded 3 items")
        for (a, b) in zip(items, decoded) {
            expect(a.id == b.id, "id preserved")
            expect(a.kind == b.kind, "kind preserved (\(a.kind) vs \(b.kind))")
            expect(a.direction == b.direction, "direction preserved")
            expect(a.timestamp == b.timestamp, "timestamp preserved")
            expect(a.preview == b.preview, "preview preserved")
            expect(a.peerName == b.peerName, "peerName preserved")
            expect(a.localURL == b.localURL, "localURL preserved (\(String(describing: a.localURL)))")
        }

        // ---- pruning(_:olderThan:) drops old items ----------------------------------
        let store = TransferHistoryStore()
        let cutoff = Date(timeIntervalSince1970: 2_500_000)
        let kept = store.pruning(items, olderThan: cutoff)
        expect(kept.count == 1, "pruning keeps only items >= cutoff, got \(kept.count)")
        expect(kept.first?.preview == "doc.pdf", "pruning kept the newest item")
        expect(!kept.contains(where: { $0.timestamp < cutoff }), "no surviving item is older than cutoff")

        // boundary: item exactly at cutoff is kept (>=)
        let boundary = [TransferItem(kind: .text, direction: .outgoing,
                                     timestamp: cutoff, preview: "edge", peerName: "X")]
        expect(store.pruning(boundary, olderThan: cutoff).count == 1, "item at exact cutoff is kept")

        print("ALL PASS")
    }

    static func expect(_ c: Bool, _ m: String) {
        if !c { fail(m) }
    }
    static func fail(_ m: String) {
        FileHandle.standardError.write(Data("FAIL: \(m)\n".utf8)); exit(1)
    }
}
