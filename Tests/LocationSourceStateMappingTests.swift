// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class LocationSourceStateMappingTests: XCTestCase {
    func testFullCapabilityMatrix() {
        let capabilities: [LocationCapability] = [
            .notDetermined,
            .servicesDisabled,
            .denied,
            .restricted,
            .whenInUse(accuracy: .full),
            .whenInUse(accuracy: .reduced),
            .always(accuracy: .full),
            .always(accuracy: .reduced),
        ]

        for tier in LocationTier.allCases {
            for capability in capabilities {
                let result = locationSourceState(effective: capability, tier: tier, paused: false)
                if tier.isSatisfied(by: capability) {
                    XCTAssertEqual(result.0, .active, "\(tier) \(capability)")
                    XCTAssertNil(result.1, "\(tier) \(capability)")
                } else {
                    XCTAssertEqual(result.0, .needsAttention, "\(tier) \(capability)")
                    XCTAssertNotNil(result.1, "\(tier) \(capability)")
                }
            }
        }
    }

    func testPausedShortCircuitsCapability() {
        let result = locationSourceState(effective: .denied, tier: .full, paused: true)

        XCTAssertEqual(result.0, .paused)
        XCTAssertNil(result.1)
    }

    func testRestrictedUsesDistinctBody() {
        let result = locationSourceState(effective: .restricted, tier: .balanced, paused: false)

        XCTAssertEqual(result.0, .needsAttention)
        XCTAssertEqual(result.1, SourceAttention(message: LocationVocabulary.restrictedBody))
    }

    func testDeniedAndServicesDisabledUseDowngradeBody() {
        let denied = locationSourceState(effective: .denied, tier: .balanced, paused: false)
        let servicesDisabled = locationSourceState(effective: .servicesDisabled, tier: .balanced, paused: false)
        let expectedMessage = LocationVocabulary.downgradeBody(tierLabel: LocationTier.balanced.label)

        XCTAssertEqual(denied.1?.message, expectedMessage)
        XCTAssertEqual(servicesDisabled.1?.message, expectedMessage)
    }

    func testLesserGrantUsesDowngradeBody() {
        let result = locationSourceState(effective: .whenInUse(accuracy: .full), tier: .balanced, paused: false)
        let alwaysReduced = locationSourceState(effective: .always(accuracy: .reduced), tier: .full, paused: false)

        XCTAssertEqual(result.0, .needsAttention)
        XCTAssertEqual(result.1?.message, LocationVocabulary.downgradeBody(tierLabel: LocationTier.balanced.label))
        XCTAssertEqual(alwaysReduced.0, .needsAttention)
        XCTAssertEqual(alwaysReduced.1?.message, LocationVocabulary.downgradeBody(tierLabel: LocationTier.full.label))
    }
}
