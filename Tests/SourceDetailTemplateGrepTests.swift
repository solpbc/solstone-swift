// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SourceDetailTemplateGrepTests: XCTestCase {
    func testTemplateOrderForFiveSourceDetails() throws {
        let withMappedAction = [
            "Sources/Location/LocationSourceDetailView.swift",
            "Sources/SourceDetailView.swift",
            "Sources/Omi/OmiSourceDetailView.swift",
        ]
        for relative in withMappedAction {
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

        let screencast = try Self.contents("Sources/Screencast/ScreencastSourceDetailView.swift")
        XCTAssertTrue(screencast.contains("SourceDetailVerdictLine"))
        XCTAssertTrue(screencast.contains("SourceDetailReasonLine"))
        XCTAssertTrue(screencast.contains("SourceHomeTileControl"))
        XCTAssertFalse(screencast.contains("SourceFaultActionControl"))
        let screencastVerdict = try XCTUnwrap(screencast.range(of: "SourceDetailVerdictLine("))
        let screencastReason = try XCTUnwrap(screencast.range(of: "SourceDetailReasonLine("))
        XCTAssertLessThan(screencastVerdict.lowerBound, screencastReason.lowerBound)

        let watch = try Self.contents("Sources/WatchCapture/WatchSourceDetailView.swift")
        XCTAssertTrue(watch.contains("SourceDetailReasonLine"))
        XCTAssertTrue(watch.contains("SourceHomeTileControl"))
        XCTAssertFalse(watch.contains("SourceDetailVerdictLine"))
        XCTAssertFalse(watch.contains("SourceFaultActionControl"))
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
