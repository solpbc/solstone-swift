// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class AnswerProvenanceTests: XCTestCase {
    func testShowsPillOnlyForSourcedWithSources() {
        XCTAssertTrue(Self.sourced(sources: [Self.source], coverage: ["read your journal"]).showsPill)
        XCTAssertFalse(Self.sourced(sources: [], coverage: ["read your journal"]).showsPill)
        XCTAssertFalse(AnswerProvenance.unknown(coverage: ["read your journal"]).showsPill)
    }

    func testCoverageLinesPreserveSourceCasingVerbatim() {
        XCTAssertEqual(
            Self.sourced(sources: [Self.source], coverage: ["Reading your journal"]).coverageLines,
            ["Reading your journal"]
        )
        XCTAssertEqual(
            AnswerProvenance.unknown(coverage: ["read your journal"]).coverageLines,
            ["read your journal"]
        )
    }

    private static func sourced(
        sources: [AnswerProvenance.ProvenanceSource],
        coverage: [String]
    ) -> AnswerProvenance {
        AnswerProvenance.sourced(
            sources: sources,
            confidence: .high,
            coverage: coverage
        )
    }

    private static var source: AnswerProvenance.ProvenanceSource {
        AnswerProvenance.ProvenanceSource(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000902") ?? UUID(),
            label: "9:02 call with jack",
            detail: "37 min",
            openURL: URL(string: "http://127.0.0.1/")
        )
    }
}
