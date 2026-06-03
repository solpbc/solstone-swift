// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class PendingLocationCommandStateTests: XCTestCase {
    @MainActor
    func testSetAndClearCommand() {
        let state = PendingLocationCommandState()

        state.command = .pauseRequested
        XCTAssertEqual(state.command, .pauseRequested)

        state.command = nil
        XCTAssertNil(state.command)
    }
}
