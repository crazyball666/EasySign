//
//  ResignOutputPublisherTests.swift
//
//  Run:
//    swiftc -o /tmp/easysign-output-tests \
//      EasySign/Core/Resigning/Model/ResignOutputPublisher.swift \
//      Tests/ResignOutputPublisherTests.swift && /tmp/easysign-output-tests
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

@main
struct ResignOutputPublisherTests {
    static func main() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("EasySign-PublisherTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let final = root.appendingPathComponent("Final.ipa")
            try Data("old".utf8).write(to: final)
            let publisher = try ResignOutputPublisher(finalURL: final)
            expect(publisher.candidateURL.deletingLastPathComponent() == final.deletingLastPathComponent(), "candidate is a sibling of final IPA")
            expect(publisher.candidateURL.lastPathComponent.hasPrefix(".EasySign-") && publisher.candidateURL.pathExtension == "ipa", "candidate is hidden and has IPA extension")

            try Data("failed".utf8).write(to: publisher.candidateURL)
            try publisher.discardCandidate()
            expect((try? Data(contentsOf: final)) == Data("old".utf8), "discarding failed candidate preserves existing final IPA")
            expect(!FileManager.default.fileExists(atPath: publisher.candidateURL.path), "discarding removes only candidate")

            expectThrows("cannot publish without a candidate") { try publisher.publish() }
            try Data("new".utf8).write(to: publisher.candidateURL)
            try publisher.publish()
            expect((try? Data(contentsOf: final)) == Data("new".utf8), "publish replaces final only after candidate exists")
            expect(!FileManager.default.fileExists(atPath: publisher.candidateURL.path), "publish consumes candidate")
        } catch {
            failures += 1
            print("FAIL  publisher test setup: \(error)")
        }
        if failures == 0 { print("ALL PASS") } else { print("\(failures) FAILURES"); exit(1) }
    }
}
