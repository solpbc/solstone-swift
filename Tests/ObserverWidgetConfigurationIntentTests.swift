// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ObserverWidgetConfigurationIntentTests: XCTestCase {
    @MainActor
    func testSourceAdapterCoversTheRealSourceVocabulary() {
        let sourceKinds = Set(ObserverWidgetSource.allCases.map(\.sourceKind))

        XCTAssertEqual(
            sourceKinds,
            [.observer, .location, .omi, .screencast, .watch]
        )
        XCTAssertEqual(sourceKinds.count, 5)

        for sourceKind in sourceKinds {
            XCTAssertEqual(ObserverWidgetSource(sourceKind: sourceKind).sourceKind, sourceKind)
        }
    }

    @MainActor
    func testConfigurationIntentRetainsTheSelectedSource() {
        let intent = ObserverWidgetConfigurationIntent(source: .omi)

        XCTAssertEqual(intent.source.sourceKind, .omi)
    }
}
