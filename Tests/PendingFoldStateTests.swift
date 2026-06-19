// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class PendingFoldStateTests: XCTestCase {
    @MainActor
    func testMarkPendingSetsUseID() {
        let state = PendingFoldState()

        state.markPending("turn-1")

        XCTAssertEqual(state.useID, "turn-1")
    }

    @MainActor
    func testMarkShownMatchingUseIDClears() {
        let state = PendingFoldState()
        state.markPending("turn-1")

        state.markShown("turn-1")

        XCTAssertNil(state.useID)
    }

    @MainActor
    func testMarkShownNonMatchingUseIDDoesNotClear() {
        let state = PendingFoldState()
        state.markPending("turn-1")

        state.markShown("turn-2")

        XCTAssertEqual(state.useID, "turn-1")
    }

    @MainActor
    func testNonMatchingShownCallsPersistUntilMatchingShown() {
        let state = PendingFoldState()
        state.markPending("turn-1")

        state.markShown("turn-2")
        state.markShown("turn-3")
        state.markShown("turn-4")

        XCTAssertEqual(state.useID, "turn-1")

        state.markShown("turn-1")

        XCTAssertNil(state.useID)
    }

    @MainActor
    func testMarkPendingOverwritesPreviousUseID() {
        let state = PendingFoldState()
        state.markPending("turn-1")

        state.markPending("turn-2")

        XCTAssertEqual(state.useID, "turn-2")
    }
}
