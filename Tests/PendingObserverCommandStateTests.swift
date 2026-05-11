// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class PendingObserverCommandStateTests: XCTestCase {
    @MainActor
    func testSetAndClearCommand() {
        let state = PendingObserverCommandState()

        state.command = .stopRequested
        XCTAssertEqual(state.command, .stopRequested)

        state.command = nil
        XCTAssertNil(state.command)
    }
}
