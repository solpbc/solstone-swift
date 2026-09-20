// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class StatusPaneTests: XCTestCase {
    func testScreenOnlyWaitingPresentationUsesScreenRouteAndAggregateTotal() {
        let presentation = StatusPaneWaitingPresentation.build(
            mobileAggregateCount: 1,
            audioCount: 0,
            locationCount: 0,
            screencastCount: 1,
            watchCount: 0
        )

        XCTAssertEqual(presentation.total, 1)
        XCTAssertEqual(presentation.rows, [StatusPaneWaitingRow(source: .screencast, count: 1)])
        XCTAssertEqual(presentation.rows.first?.route, .screencast)
        XCTAssertEqual(presentation.rows.first?.kind, .screencast)
    }

    func testMixedBundleRendersThreeFacetsWithoutTripleCountingHeadline() {
        let presentation = StatusPaneWaitingPresentation.build(
            mobileAggregateCount: 1,
            audioCount: 1,
            locationCount: 1,
            screencastCount: 1,
            watchCount: 0
        )

        XCTAssertEqual(presentation.total, 1)
        XCTAssertEqual(presentation.rows.map(\.source), [.audio, .location, .screencast])
        XCTAssertEqual(presentation.rows.map(\.route), [.audio, .location, .screencast])
        XCTAssertEqual(presentation.rows.map(\.kind), [.observer, .location, .screencast])
        XCTAssertEqual(presentation.rows.map(\.count), [1, 1, 1])
    }

    func testConnectionDetailsRequireAnActiveTunnelDespitePairedStaleContext() throws {
        let text = try String(
            contentsOf: StringLiteralGrepSupport.worktreeRoot()
                .appendingPathComponent("Sources/Home/StatusPane.swift"),
            encoding: .utf8
        )
        let gate = try Self.slice(
            in: text,
            from: "private var showsConnectionDetails: Bool {",
            to: "\n    private var probeDisplay"
        )
        let pane = try Self.slice(
            in: text,
            from: "private var paneContent: some View {",
            to: "\n            Section(\"diagnostics\")"
        )

        XCTAssertTrue(gate.contains("self.appConfig.isPaired && self.tunnelManager.state.isConnected"))
        XCTAssertTrue(pane.contains("if self.showsConnectionDetails {"))
        XCTAssertTrue(pane.contains("LabeledContent(\n                        \"method\","))
        XCTAssertTrue(pane.contains("LabeledContent(\"uptime\")"))
        XCTAssertTrue(pane.contains("shell.pane.status.transferRate"))
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
