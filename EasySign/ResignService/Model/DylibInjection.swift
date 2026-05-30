//
//  DylibInjection.swift
//  EasySign
//
//  Created by Codex on 2026/5/30.
//

import Foundation

enum DylibInjection {
    static func paths(from text: String) -> [String] {
        text
            .split { character in
                character == ";" || character == "\n"
            }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func displayText(from paths: [String]) -> String {
        paths.joined(separator: "; ")
    }

    static func duplicateFileNames(in urls: [URL]) -> [String] {
        var seen = Set<String>()
        var duplicates = Set<String>()

        for url in urls {
            let fileName = url.lastPathComponent
            guard !fileName.isEmpty else {
                continue
            }

            if seen.contains(fileName) {
                duplicates.insert(fileName)
            } else {
                seen.insert(fileName)
            }
        }

        return duplicates.sorted()
    }

    static func loadCommandName(for url: URL) -> String {
        "@executable_path/\(url.lastPathComponent)"
    }
}
