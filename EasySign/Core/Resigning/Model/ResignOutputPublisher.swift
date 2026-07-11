//
//  ResignOutputPublisher.swift
//  EasySign
//
//  Transactional publication of a verified signing result.
//

import Foundation

final class ResignOutputPublisher {
    let finalURL: URL
    let candidateURL: URL

    init(finalURL: URL) throws {
        self.finalURL = finalURL.standardizedFileURL
        let directory = self.finalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        candidateURL = directory.appendingPathComponent(".EasySign-\(UUID().uuidString).tmp.ipa")
    }

    func discardCandidate() throws {
        guard FileManager.default.fileExists(atPath: candidateURL.path) else { return }
        try FileManager.default.removeItem(at: candidateURL)
    }

    func publish() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: candidateURL.path) else {
            throw NSError(domain: "com.EasySign.error", code: -1, userInfo: [NSLocalizedDescriptionKey: "签名候选 IPA 不存在，无法发布"])
        }
        if manager.fileExists(atPath: finalURL.path) {
            _ = try manager.replaceItemAt(finalURL, withItemAt: candidateURL, backupItemName: nil, options: .usingNewMetadataOnly)
        } else {
            try manager.moveItem(at: candidateURL, to: finalURL)
        }
    }
}
