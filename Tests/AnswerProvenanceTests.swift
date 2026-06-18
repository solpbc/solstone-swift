// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class AnswerProvenanceTests: XCTestCase {
    func testShowsPillOnlyWhenSourcesExist() {
        XCTAssertTrue(AnswerProvenance(state: .answered, sources: [Self.source], coverage: []).showsPill)
        XCTAssertFalse(AnswerProvenance(state: .answered, sources: [], coverage: []).showsPill)
        XCTAssertFalse(AnswerProvenance(state: .partial, sources: [], coverage: []).showsPill)
        XCTAssertFalse(AnswerProvenance(state: .failed, sources: [], coverage: []).showsPill)
    }

    func testCoverageLinesPreserveSourceCasingVerbatim() {
        XCTAssertEqual(
            AnswerProvenance(state: .answered, sources: [Self.source], coverage: ["Reading your journal…"]).coverageLines,
            ["Reading your journal…"]
        )
    }

    func testSourceIDIsStableRef() {
        let source = AnswerProvenance.ProvenanceSource(
            ref: "sol://entry/902",
            label: "9:02 call with Jack",
            url: URL(string: "http://127.0.0.1/entry/902")
        )

        XCTAssertEqual(source.id, "sol://entry/902")
        XCTAssertEqual(source.ref, "sol://entry/902")
    }

    private static var source: AnswerProvenance.ProvenanceSource {
        AnswerProvenance.ProvenanceSource(
            ref: "sol://entry/902",
            label: "9:02 call with Jack",
            url: URL(string: "http://127.0.0.1/")
        )
    }
}
