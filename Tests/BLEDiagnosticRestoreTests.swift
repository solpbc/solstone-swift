// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class BLEDiagnosticRestoreTests: XCTestCase {
    func testRestoreIdentifierConstant() {
        XCTAssertEqual(BLEDiagnosticManager.restoreIdentifier, "app.solstone.swift.ble-diagnostic")
    }

    @MainActor
    func testWillRestoreStateHandlerExistsWithoutInstantiatingManager() {
        let handler = BLEDiagnosticManager.handleWillRestoreState
        _ = handler
    }
}
