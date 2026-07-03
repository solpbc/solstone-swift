// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class ProblemReportsCopyGrepTests: XCTestCase {
    func testProblemReportsSourceStringsAvoidForbiddenTerms() throws {
        let root = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources/ProblemReports")
        let regex = try NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive])
        let files = try StringLiteralGrepSupport.swiftFiles(under: root)

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let lineText = try StringLiteralGrepSupport.removingStructuralLiterals(from: String(line))
                for literal in try StringLiteralGrepSupport.stringLiterals(in: lineText) {
                    let range = NSRange(literal.startIndex..<literal.endIndex, in: literal)
                    if regex.firstMatch(in: literal, range: range) != nil {
                        XCTFail("forbidden problem reports string at \(file.path):\(index + 1): \(literal)")
                    }
                }
            }
        }
    }

    @MainActor
    func testProblemReportsVocabularyIsLowercaseAndCovenantClean() throws {
        let regex = try NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive])
        for string in Self.ownerVisibleStrings {
            let firstScalar = try XCTUnwrap(string.unicodeScalars.first)
            XCTAssertTrue(
                CharacterSet.lowercaseLetters.contains(firstScalar) || CharacterSet.decimalDigits.contains(firstScalar),
                string
            )
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            XCTAssertNil(regex.firstMatch(in: string, range: range), string)
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

    private static var ownerVisibleStrings: [String] {
        [
            SourceVocabulary.problemReportsToggle,
            SourceVocabulary.problemReportsToggleHint,
            SourceVocabulary.problemReportsTitle,
            SourceVocabulary.problemReportsRow,
            SourceVocabulary.problemReportsRowHint,
            SourceVocabulary.problemReportsReportRowHint,
            SourceVocabulary.problemReportsOptedOutTitle,
            SourceVocabulary.problemReportsOptedOutBody,
            SourceVocabulary.problemReportsEmptyTitle,
            SourceVocabulary.problemReportsEmptyBody,
            SourceVocabulary.problemReportKindCrash,
            SourceVocabulary.problemReportKindHang,
            SourceVocabulary.problemReportKindCPUException,
            SourceVocabulary.problemReportKindDiskWriteException,
            SourceVocabulary.problemReportKindAppLaunch,
            SourceVocabulary.problemReportKindAppExit,
            SourceVocabulary.problemReportKindUnknown,
            SourceVocabulary.problemReportsShare,
            SourceVocabulary.problemReportsShareHint,
            SourceVocabulary.problemReportsShareAll,
            SourceVocabulary.problemReportsShareAllHint,
            SourceVocabulary.problemReportsDelete,
            SourceVocabulary.problemReportsDeleteHint,
            SourceVocabulary.problemReportsDeleteAll,
            SourceVocabulary.problemReportsDeleteAllHint,
            SourceVocabulary.problemReportsDeleteAllConfirmTitle,
            SourceVocabulary.problemReportsDeleteAllConfirmBody,
            SourceVocabulary.problemReportsMissingTitle,
            SourceVocabulary.problemReportsMissingBody,
        ]
    }
}
