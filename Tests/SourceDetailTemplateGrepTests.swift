// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SourceDetailTemplateGrepTests: XCTestCase {
    func testTemplateOrderForThreeSourceKinds() throws {
        let files = [
            "Sources/Location/LocationSourceDetailView.swift",
            "Sources/SourceDetailView.swift",
            "Sources/Omi/OmiSourceDetailView.swift",
        ]
        for relative in files {
            let text = try Self.contents(relative)
            XCTAssertTrue(text.contains("SourceDetailVerdictLine"), relative)
            XCTAssertTrue(text.contains("SourceDetailReasonLine"), relative)
            XCTAssertTrue(text.contains("SourceFaultActionControl"), relative)
            XCTAssertTrue(text.contains("SourceHomeTileControl"), relative)
            let verdict = try XCTUnwrap(text.range(of: "SourceDetailVerdictLine("), relative)
            let reason = try XCTUnwrap(text.range(of: "SourceDetailReasonLine("), relative)
            let action = try XCTUnwrap(text.range(of: "SourceFaultActionControl("), relative)
            XCTAssertLessThan(verdict.lowerBound, reason.lowerBound, relative)
            XCTAssertLessThan(reason.lowerBound, action.lowerBound, relative)
        }
    }
}

private extension SourceDetailTemplateGrepTests {
    static func contents(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
