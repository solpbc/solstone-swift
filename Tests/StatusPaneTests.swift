// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class StatusPaneTests: XCTestCase {
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
