// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class BrandCanonGrepTests: XCTestCase {
    func testSourceCopyAvoidsAccountSurfaceTerms() throws {
        let root = Self.worktreeRoot()
        let sourceRoot = root.appendingPathComponent("Sources")
        let regex = try NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive])
        let files = try Self.swiftFiles(under: sourceRoot)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = String(line)
                guard !Self.isAllowlisted(file: file, line: lineText) else {
                    continue
                }
                let range = NSRange(lineText.startIndex..<lineText.endIndex, in: lineText)
                if let match = regex.firstMatch(in: lineText, range: range) {
                    XCTFail("brand canon term at \(file.path):\(index + 1): \(lineText)")
                    XCTAssertEqual(match.numberOfRanges, 0)
                }
            }
        }
    }

    func testAllowlistEntryStillExists() throws {
        let root = Self.worktreeRoot()
        let contentView = root.appendingPathComponent("Sources/ContentView.swift")
        let text = try String(contentsOf: contentView, encoding: .utf8)
        XCTAssertTrue(text.contains("your WiFi network may require " + "sign" + "-in"))
    }

    private static let terms = [
        "sign" + " in",
        "signed" + " in",
        "signing" + " in",
        "sign" + "-in",
        "sign" + "in",
        "log" + " in",
        "logged" + " in",
        "logging" + " in",
        "log" + "in",
        "your" + " account",
        "account" + " settings",
        "my" + " account",
        "link" + "ed",
        "auth" + "enticate",
        "authentic" + "ation",
        "authentic" + "ating",
        "pass" + "key",
        "e" + "mail",
        "pass" + "word",
        "create" + " account",
        "sign" + " up",
        "sign" + "up",
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

    private static func isAllowlisted(file: URL, line: String) -> Bool {
        file.lastPathComponent == "ContentView.swift"
            && line.contains("your WiFi network may require " + "sign" + "-in")
    }
}
