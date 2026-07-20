// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchSteadyVocabularyGrepTests: XCTestCase {
    func testNoSourceVocabularyLiteralEndsWithWaitingOnYourWatch() throws {
        let literals = try Self.sourceVocabularyStringLiterals()

        XCTAssertFalse(literals.contains { literal in
            literal == "waiting on your watch" || literal.hasSuffix("waiting on your watch")
        })
    }

    func testWaitingToReachJournalLiteralIsOnlyApprovedStuckReason() throws {
        let literals = try Self.sourceVocabularyStringLiterals().filter {
            $0.contains("waiting to reach your journal")
        }

        // The handoff stuck reason is a deliberate, approved exception and must not be fixed by deleting it.
        XCTAssertEqual(literals, [
            "segments are on this iphone and waiting to reach your journal."
        ])
    }

    private static func sourceVocabularyStringLiterals() throws -> [String] {
        let path = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SourceVocabulary.swift")
        let text = try String(contentsOf: path, encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: false).flatMap { line in
            try StringLiteralGrepSupport.stringLiterals(in: String(line))
        }
    }
}
