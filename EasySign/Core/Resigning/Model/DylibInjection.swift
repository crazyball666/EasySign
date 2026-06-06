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

    static func mergePaths(existing: [String], adding newPaths: [String]) -> [String] {
        var merged: [String] = []
        var seen = Set<String>()

        for path in existing + newPaths {
            let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPath.isEmpty, !seen.contains(trimmedPath) else {
                continue
            }

            merged.append(trimmedPath)
            seen.insert(trimmedPath)
        }

        return merged
    }

    static func removePath(at index: Int, from paths: [String]) -> [String] {
        guard paths.indices.contains(index) else {
            return paths
        }

        var result = paths
        result.remove(at: index)
        return result
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
