// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WatchPipelineReducerIsolationGrepTests: XCTestCase {
    func testWatchPipelineBuildersDoNotReadRawInputs() throws {
        let root = Self.worktreeRoot()
        let presentation = root.appendingPathComponent("Sources/WatchCapture/WatchSourceDetailPresentation.swift")
        let view = root.appendingPathComponent("Sources/WatchCapture/WatchSourceDetailView.swift")
        let assembler = root.appendingPathComponent("Sources/WatchCapture/WatchPipelineInputAssembler.swift")

        let presentationText = try String(contentsOf: presentation, encoding: .utf8)
        XCTAssertNoThrow(try Self.assertExemptMarkerCount(in: presentationText, path: presentation.path, expected: 0))
        try self.assertNoForbiddenSymbols(in: presentationText, path: presentation.path)

        let viewText = try String(contentsOf: view, encoding: .utf8)
        XCTAssertNoThrow(try Self.assertExemptMarkerCount(in: viewText, path: view.path, expected: 0))
        try self.assertNoForbiddenSymbols(in: viewText, path: view.path)

        let assemblerText = try String(contentsOf: assembler, encoding: .utf8)
        let strippedAssemblerText = try Self.removingExemptSeam(from: assemblerText, path: assembler.path)
        try self.assertNoForbiddenSymbols(in: strippedAssemblerText, path: assembler.path)
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
        "WatchPhoneSessionHistoryStore",
        "ConnectionSyncModel",
        "canOpenURL",
    ]

    private static let exemptBegin = "// KILL-LIST-EXEMPT:BEGIN"
    private static let exemptEnd = "// KILL-LIST-EXEMPT:END"

    private func assertNoForbiddenSymbols(in text: String, path: String) throws {
        for forbidden in Self.forbiddenSymbols where text.contains(forbidden) {
            XCTFail("forbidden watch pipeline builder symbol \(forbidden) in \(path)")
        }
    }

    private static func assertExemptMarkerCount(in text: String, path: String, expected: Int) throws {
        let beginRanges = text.ranges(of: self.exemptBegin)
        let endRanges = text.ranges(of: self.exemptEnd)
        XCTAssertEqual(beginRanges.count, expected, "unexpected watch pipeline exempt begin marker count in \(path)")
        XCTAssertEqual(endRanges.count, expected, "unexpected watch pipeline exempt end marker count in \(path)")
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
