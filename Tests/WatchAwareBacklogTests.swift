// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import WatchConnectivity
import XCTest

nonisolated final class WatchAwareBacklogTests: XCTestCase {
    func testFreshAddsWristCountAndUnknownUsesKnownLowerBound() {
        let asOf = Date(timeIntervalSince1970: 1_000)
        let active = WatchSessionReadiness.activated(.installedActive)

        XCTAssertEqual(
            watchAwareBacklog(
                phoneLocalCount: 3,
                session: active,
                waiting: .reported(count: 2, freshness: .fresh(asOf: asOf))
            ),
            .known(5)
        )
        XCTAssertEqual(
            watchAwareBacklog(phoneLocalCount: 3, session: active, waiting: .unknown),
            .partiallyUnknown(known: 3, asOf: nil)
        )
        XCTAssertEqual(
            watchAwareBacklog(
                phoneLocalCount: 3,
                session: active,
                waiting: .reported(count: 9, freshness: .stale(asOf: asOf, age: 120))
            ),
            .partiallyUnknown(known: 3, asOf: asOf)
        )
    }
}
