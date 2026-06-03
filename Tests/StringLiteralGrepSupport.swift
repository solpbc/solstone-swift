// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum StringLiteralGrepSupport {
    static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func swiftFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            return values.isRegularFile == true ? url : nil
        }
    }

    static func removingStructuralLiterals(from line: String) throws -> String {
        var sanitized = line
        for pattern in self.structuralLiteralPatterns {
            let regex = try NSRegularExpression(pattern: pattern)
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = regex.stringByReplacingMatches(
                in: sanitized,
                range: range,
                withTemplate: ""
            )
        }
        return sanitized
    }

    static let structuralLiteralPatterns = [
        #"Image\s*\(\s*systemName\s*:\s*"(?:\\.|[^"\\])*"\s*\)"#,
        #"URL\s*\(\s*string\s*:\s*"(?:\\.|[^"\\])*"\s*\)"#,
        #"font\s*\(\s*\.custom\s*\(\s*"(?:\\.|[^"\\])*"\s*,[^)]*\)\s*\)"#,
    ]

    static func stringLiterals(in line: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: line) else { return nil }
            let quoted = String(line[matchRange])
            return String(quoted.dropFirst().dropLast())
        }
    }
}
