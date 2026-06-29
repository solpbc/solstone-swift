// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LocationDetailPresentationTests: XCTestCase {
    func testDeliverySummaryBranches() {
        let lastUploadAt = Date(timeIntervalSince1970: 1_713_624_000)

        XCTAssertEqual(
            LocationDetailPresentation.deliverySummary(pending: 2, failed: 1, lastUploadAt: lastUploadAt),
            LocationDeliverySummary(line: LocationVocabulary.deliveryNeedsAttention(count: 1), showsRetry: true)
        )
        XCTAssertEqual(
            LocationDetailPresentation.deliverySummary(pending: 2, failed: 0, lastUploadAt: lastUploadAt),
            LocationDeliverySummary(line: LocationVocabulary.deliverySending(count: 2), showsRetry: false)
        )
        XCTAssertEqual(
            LocationDetailPresentation.deliverySummary(pending: 0, failed: 0, lastUploadAt: lastUploadAt),
            LocationDeliverySummary(
                line: LocationVocabulary.deliveryLastSaved(
                    time: LocationDetailPresentation.shortTimeLabel(for: lastUploadAt)
                ),
                showsRetry: false
            )
        )
        XCTAssertEqual(
            LocationDetailPresentation.deliverySummary(pending: 0, failed: 0, lastUploadAt: nil),
            LocationDeliverySummary(line: LocationVocabulary.deliveryQuietLine, showsRetry: false)
        )
    }

    func testRecoveryButtonLabelsUseLocationVocabulary() {
        XCTAssertEqual(
            LocationDetailPresentation.recoveryButtonLabel(for: .openSettings),
            LocationVocabulary.openSettingsAction
        )
        XCTAssertEqual(
            LocationDetailPresentation.recoveryButtonLabel(for: .matchToAllowed(suggestedTier: .light)),
            LocationVocabulary.matchToAllowedAction
        )
    }

    func testTierFramingUsesLocationVocabulary() {
        XCTAssertEqual(LocationDetailPresentation.tierFraming, LocationVocabulary.tierChangeFraming)
    }

    @MainActor
    func testRecoveryActionsPerCapability() async {
        let softDowngrade = self.makeManager(capability: .whenInUse(accuracy: .full))
        await softDowngrade.start(tier: .balanced)
        XCTAssertEqual(softDowngrade.recoveryActions, [
            .openSettings,
            .matchToAllowed(suggestedTier: .light),
        ])

        let denied = self.makeManager(capability: .denied)
        await denied.start(tier: .balanced)
        XCTAssertEqual(denied.recoveryActions, [.openSettings])

        let servicesDisabled = self.makeManager(capability: .servicesDisabled)
        await servicesDisabled.start(tier: .balanced)
        XCTAssertEqual(servicesDisabled.recoveryActions, [.openSettings])

        let restricted = self.makeManager(capability: .restricted)
        await restricted.start(tier: .balanced)
        XCTAssertEqual(restricted.recoveryActions, [])
    }

    @MainActor
    func testMatchToAllowedUpdatesTier() async {
        let manager = self.makeManager(capability: .whenInUse(accuracy: .full))
        await manager.start(tier: .balanced)

        await manager.matchToAllowed()

        XCTAssertEqual(manager.tier, .light)
        XCTAssertEqual(manager.sourceState, .active)
    }

    @MainActor
    private func makeManager(capability: LocationCapability) -> LocationManager {
        let provider = MockLocationProvider()
        provider.capability = capability
        return LocationManager(
            provider: provider,
            clock: MockObserverClock(),
            defaults: nil
        )
    }
}
