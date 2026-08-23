// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class HomeSourceTileAccessibilityTests: XCTestCase {
    func testAccessibilityValueIsSourceStateLabel() {
        for state in [
            SourceState.off,
            .enrolling,
            .readyToSetUp,
            .checking,
            .active,
            .paused,
            .needsAttention,
        ] {
            XCTAssertEqual(state.label, state.label)
        }
        XCTAssertEqual(SourceState.off.label, "off")
        XCTAssertEqual(SourceState.paused.label, "paused")
        XCTAssertNotEqual(SourceState.off.label, SourceState.paused.label)
    }

    func testHomeSourceTileUsesStateLabelAsAccessibilityValue() throws {
        let text = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Home/HomeSourceTile.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains(".accessibilityValue(self.source.state.label)"))
        XCTAssertFalse(text.contains("homeSourceTileAccessibilityFacts"))
    }
}
