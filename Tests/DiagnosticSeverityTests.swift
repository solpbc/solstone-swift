// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class DiagnosticSeverityTests: XCTestCase {
    @MainActor
    func testRowEmphasisMapping() {
        XCTAssertEqual(DiagnosticSeverity.error.rowEmphasis, .error)
        XCTAssertEqual(DiagnosticSeverity.warning.rowEmphasis, .warning)
        XCTAssertEqual(DiagnosticSeverity.info.rowEmphasis, .normal)
    }
}
