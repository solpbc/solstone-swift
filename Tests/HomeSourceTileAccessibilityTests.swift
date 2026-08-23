// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class HomeSourceTileAccessibilityTests: XCTestCase {
    func testFactsForAllSourceStates() {
        let cases: [(SourceState, String, String)] = [
            (.off, "dev-copy: not taking it in now", "good"),
            (.enrolling, "dev-copy: taking it in now", "good"),
            (.readyToSetUp, "dev-copy: not taking it in now", "unavailable"),
            (.checking, "dev-copy: not taking it in now", "degraded"),
            (.active, "dev-copy: taking it in now", "good"),
            (.paused, "dev-copy: not taking it in now", "good"),
            (.needsAttention, "dev-copy: not taking it in now", "degraded"),
        ]
        for (state, taking, verdict) in cases {
            let facts = homeSourceTileAccessibilityFacts(for: state)
            XCTAssertEqual(facts.takingItIn, taking, String(describing: state))
            XCTAssertEqual(facts.verdict, verdict, String(describing: state))
            XCTAssertEqual(facts.value, "\(taking), \(verdict)", String(describing: state))
        }
    }
}
