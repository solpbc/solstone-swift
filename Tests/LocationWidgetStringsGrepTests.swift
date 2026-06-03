// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class LocationWidgetStringsGrepTests: XCTestCase {
    func testWidgetVisibleStringsAvoidLocationForbiddenTerms() throws {
        let root = Self.worktreeRoot().appendingPathComponent("SolstoneLiveActivityWidget")
        let regex = try NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive])
        let files = try Self.swiftFiles(under: root)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = try Self.removingStructuralLiterals(from: String(line))
                for literal in try Self.stringLiterals(in: lineText) {
                    let range = NSRange(literal.startIndex..<literal.endIndex, in: literal)
                    if let match = regex.firstMatch(in: literal, range: range) {
                        XCTFail("forbidden widget string at \(file.path):\(index + 1): \(literal)")
                        XCTAssertEqual(match.numberOfRanges, 0)
                    }
                }
            }
        }
    }

    private static let terms = [
        "captur" + "e",
        "captur" + "ed",
        "captur" + "es",
        "captur" + "ing",
        "rec" + "ord",
        "rec" + "ords",
        "rec" + "orded",
        "rec" + "ording",
        "watch",
        "watch" + "es",
        "watch" + "ed",
        "watch" + "ing",
        "mon" + "itor",
        "mon" + "itors",
        "mon" + "itored",
        "mon" + "itoring",
        "track",
        "track" + "s",
        "track" + "ed",
        "track" + "ing",
        "collect",
        "collect" + "s",
        "collect" + "ed",
        "collect" + "ing",
        "keeper",
        "assistant",
        "server",
        "service",
    ]

    private static var pattern: String {
        let alternation = self.terms
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return #"(?<![A-Za-z0-9_])("# + alternation + #")(?![A-Za-z0-9_])"#
    }

    private static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under root: URL) throws -> [URL] {
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

    private static func removingStructuralLiterals(from line: String) throws -> String {
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

    private static let structuralLiteralPatterns = [
        #"Image\s*\(\s*systemName\s*:\s*"(?:\\.|[^"\\])*"\s*\)"#,
        #"URL\s*\(\s*string\s*:\s*"(?:\\.|[^"\\])*"\s*\)"#,
        #"font\s*\(\s*\.custom\s*\(\s*"(?:\\.|[^"\\])*"\s*,[^)]*\)\s*\)"#,
    ]

    private static func stringLiterals(in line: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.matches(in: line, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: line) else { return nil }
            let quoted = String(line[matchRange])
            return String(quoted.dropFirst().dropLast())
        }
    }
}
