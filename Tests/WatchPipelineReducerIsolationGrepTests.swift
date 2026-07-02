// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchPipelineReducerIsolationGrepTests: XCTestCase {
    func testWatchPipelineBuildersDoNotReadRawInputs() throws {
        let root = Self.worktreeRoot()
        let presentation = root.appendingPathComponent("Sources/WatchCapture/WatchSourceDetailPresentation.swift")
        let view = root.appendingPathComponent("Sources/WatchCapture/WatchSourceDetailView.swift")

        try self.assertNoForbiddenSymbols(in: String(contentsOf: presentation, encoding: .utf8), path: presentation.path)

        let viewText = try String(contentsOf: view, encoding: .utf8)
        let strippedViewText = try Self.removingExemptSeam(from: viewText, path: view.path)
        try self.assertNoForbiddenSymbols(in: strippedViewText, path: view.path)
    }

    private static let forbiddenSymbols = [
        ".queuedCount",
        ".transferringCount",
        ".lifetimeReceived",
        ".lifetimeHanded",
        ".nonTerminalCount",
        ".oldestNonTerminalReceivedAt",
        ".pendingCount",
        ".failedCount",
        ".inFlightCount",
        "WatchUploaderHolder",
        "WatchRelayReceiver",
        "WatchSegmentLedger",
        "ConnectionSyncModel",
    ]

    private static let exemptBegin = "// KILL-LIST-EXEMPT:BEGIN"
    private static let exemptEnd = "// KILL-LIST-EXEMPT:END"

    private func assertNoForbiddenSymbols(in text: String, path: String) throws {
        for forbidden in Self.forbiddenSymbols where text.contains(forbidden) {
            XCTFail("forbidden watch pipeline builder symbol \(forbidden) in \(path)")
        }
    }

    private static func removingExemptSeam(from text: String, path: String) throws -> String {
        let beginRanges = text.ranges(of: self.exemptBegin)
        let endRanges = text.ranges(of: self.exemptEnd)
        XCTAssertEqual(beginRanges.count, 1, "expected one watch pipeline exempt begin marker in \(path)")
        XCTAssertEqual(endRanges.count, 1, "expected one watch pipeline exempt end marker in \(path)")
        guard let begin = beginRanges.first, let end = endRanges.first, begin.lowerBound < end.upperBound else {
            XCTFail("invalid watch pipeline exempt markers in \(path)")
            return text
        }
        return String(text[..<begin.lowerBound]) + String(text[end.upperBound...])
    }

    private static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = self.startIndex
        while searchStart < self.endIndex,
              let range = self.range(of: needle, range: searchStart..<self.endIndex)
        {
            ranges.append(range)
            searchStart = range.upperBound
        }
        return ranges
    }
}
