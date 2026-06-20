// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class OmiCopyGrepTests: XCTestCase {
    func testOmiOwnerFacingViewStringsAvoidForbiddenTerms() throws {
        let root = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources/Omi")
        let regex = try NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive])
        let files = try StringLiteralGrepSupport.swiftFiles(under: root)
            .filter { $0.lastPathComponent.hasSuffix("View.swift") }

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = try StringLiteralGrepSupport.removingStructuralLiterals(from: String(line))
                for literal in try StringLiteralGrepSupport.stringLiterals(in: lineText) {
                    let range = NSRange(literal.startIndex..<literal.endIndex, in: literal)
                    if let match = regex.firstMatch(in: literal, range: range) {
                        XCTFail("forbidden omi view string at \(file.path):\(index + 1): \(literal)")
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
}
