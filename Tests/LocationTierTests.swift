// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class LocationTierTests: XCTestCase {
    func testDefaultTierIsBalanced() {
        XCTAssertEqual(LocationTier.defaultTier, .balanced)
    }

    func testTierRequirementsAndModes() {
        XCTAssertEqual(LocationTier.light.requiredAuthorization, .whenInUse)
        XCTAssertFalse(LocationTier.light.requiresFullAccuracy)
        XCTAssertEqual(LocationTier.light.modes, [.visits])

        XCTAssertEqual(LocationTier.balanced.requiredAuthorization, .always)
        XCTAssertFalse(LocationTier.balanced.requiresFullAccuracy)
        XCTAssertEqual(LocationTier.balanced.modes, [.visits, .significantChanges])

        XCTAssertEqual(LocationTier.full.requiredAuthorization, .always)
        XCTAssertTrue(LocationTier.full.requiresFullAccuracy)
        XCTAssertEqual(LocationTier.full.modes, [.liveUpdates])
    }

    func testTierLabelsAndBodies() {
        XCTAssertEqual(LocationTier.light.label, LocationVocabulary.lightLabel)
        XCTAssertEqual(LocationTier.balanced.label, LocationVocabulary.balancedLabel)
        XCTAssertEqual(LocationTier.full.label, LocationVocabulary.fullLabel)
        XCTAssertEqual(LocationTier.light.body, LocationVocabulary.lightBody)
        XCTAssertEqual(LocationTier.balanced.body, LocationVocabulary.balancedBody)
        XCTAssertEqual(LocationTier.full.body, LocationVocabulary.fullBody)
    }

    func testMatchToAllowedHighestSatisfiedTier() {
        XCTAssertEqual(LocationTier.matchToAllowed(for: .always(accuracy: .full)), .full)
        XCTAssertEqual(LocationTier.matchToAllowed(for: .always(accuracy: .reduced)), .balanced)
        XCTAssertEqual(LocationTier.matchToAllowed(for: .whenInUse(accuracy: .full)), .light)
        XCTAssertEqual(LocationTier.matchToAllowed(for: .whenInUse(accuracy: .reduced)), .light)
        XCTAssertNil(LocationTier.matchToAllowed(for: .notDetermined))
        XCTAssertNil(LocationTier.matchToAllowed(for: .servicesDisabled))
        XCTAssertNil(LocationTier.matchToAllowed(for: .denied))
        XCTAssertNil(LocationTier.matchToAllowed(for: .restricted))
    }

    func testTierPersistenceUsesRawValueAndDefaultsInvalidToBalanced() {
        XCTAssertEqual(LocationTier(rawValue: "light"), .light)
        XCTAssertEqual(LocationTier(rawValue: "balanced"), .balanced)
        XCTAssertEqual(LocationTier(rawValue: "full"), .full)
        XCTAssertNil(LocationTier(rawValue: "places"))
    }
}
