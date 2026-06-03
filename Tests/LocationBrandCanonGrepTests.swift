// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class LocationBrandCanonGrepTests: XCTestCase {
    func testLocationStringsAvoidSurveillanceTerms() throws {
        let root = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources/Location")
        let regex = try NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive])
        let files = try StringLiteralGrepSupport.swiftFiles(under: root)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = try StringLiteralGrepSupport.removingStructuralLiterals(from: String(line))
                for literal in try StringLiteralGrepSupport.stringLiterals(in: lineText) {
                    let range = NSRange(literal.startIndex..<literal.endIndex, in: literal)
                    if let match = regex.firstMatch(in: literal, range: range) {
                        XCTFail("forbidden location string at \(file.path):\(index + 1): \(literal)")
                        XCTAssertEqual(match.numberOfRanges, 0)
                    }
                }
            }
        }
    }

    private static let terms = [
        "track",
        "track" + "s",
        "track" + "ed",
        "track" + "ing",
        "mon" + "itor",
        "mon" + "itors",
        "mon" + "itored",
        "mon" + "itoring",
        "follow",
        "follow" + "s",
        "follow" + "ed",
        "follow" + "ing",
        "trace",
        "trace" + "s",
        "traced",
        "trac" + "ing",
        "breadcrumb",
        "breadcrumb" + "s",
        "trail",
        "trail" + "s",
        "captur" + "e",
        "captur" + "es",
        "captur" + "ed",
        "captur" + "ing",
        "watch",
        "watch" + "es",
        "watch" + "ed",
        "watch" + "ing",
        "collect",
        "collect" + "s",
        "collect" + "ed",
        "collect" + "ing",
        "rec" + "ord",
        "rec" + "ords",
        "rec" + "orded",
        "rec" + "ording",
    ]

    private static var pattern: String {
        let alternation = self.terms
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        return #"(?<![A-Za-z0-9_])("# + alternation + #")(?![A-Za-z0-9_])"#
    }
}
