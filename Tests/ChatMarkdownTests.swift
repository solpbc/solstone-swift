// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ChatMarkdownTests: XCTestCase {
    func testStripSolCitationMarkdownKeepsLabelAndSource() {
        let result = ChatMarkdown.stripSolCitations(from: "See [journal note](sol://entry/902) today.")

        XCTAssertEqual(result.text, "See journal note today.")
        XCTAssertEqual(result.sources, [
            AnswerProvenance.ProvenanceSource(ref: "sol://entry/902", label: "journal note"),
        ])
    }

    func testAttributedStringRemovesSolLinkAttributes() throws {
        let attributed = try XCTUnwrap(ChatMarkdown.attributedString(from: "See [entry](sol://entry/1) and <sol://entry/2>."))

        XCTAssertEqual(String(attributed.characters), "See entry and sol://entry/2.")
        XCTAssertFalse(attributed.runs.contains { run in
            run.link?.scheme?.lowercased() == "sol"
        })
    }
}
