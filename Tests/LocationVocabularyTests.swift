// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class LocationVocabularyTests: XCTestCase {
    func testLockedLocationCopyVerbatim() {
        XCTAssertEqual(LocationVocabulary.sourceDisplayName, "location")
        XCTAssertEqual(LocationVocabulary.activeSubtext, "adds where your day happens to your journal while this is on.")
        XCTAssertEqual(LocationVocabulary.preEnrollmentValue, "where your day happens — kept in your journal, yours alone. as light or complete as you want.")
        XCTAssertEqual(LocationVocabulary.tierDialHeader, "how much of your day to keep")
        XCTAssertEqual(LocationVocabulary.tierDialSubhead, "your day, your call. you can change this any time.")
        XCTAssertEqual(LocationVocabulary.lightLabel, "places only")
        XCTAssertEqual(LocationVocabulary.lightBody, "the places you stop — home, work, an event.")
        XCTAssertEqual(LocationVocabulary.balancedLabel, "places + comings and goings")
        XCTAssertEqual(LocationVocabulary.balancedBody, "your stops, plus the shape of how you move between them.")
        XCTAssertEqual(LocationVocabulary.balancedDefaultBadge, "recommended")
        XCTAssertEqual(LocationVocabulary.fullLabel, "the complete picture")
        XCTAssertEqual(LocationVocabulary.fullBody, "the full, detailed picture of where your day happened. uses more battery.")
        XCTAssertEqual(LocationVocabulary.batteryHonesty, "fuller settings run in the background and use more battery. iOS shows its location arrow whenever location is on.")
        XCTAssertEqual(LocationVocabulary.alwaysBackgroundPrimer, "to keep this when sol isn't open, iOS will ask to allow location \"Always.\" you can change it any time in iOS Settings.")
        XCTAssertEqual(LocationVocabulary.turnOnLocation, "turn on location")
        XCTAssertEqual(LocationVocabulary.alwaysPrimerHeader, "before iOS asks")
        XCTAssertEqual(LocationVocabulary.alwaysPrimerContinue, "continue")
        XCTAssertEqual(LocationVocabulary.stateBlockTitle, "state")
        XCTAssertEqual(LocationVocabulary.tierBlockTitle, "detail level")
        XCTAssertEqual(LocationVocabulary.recentBlockTitle, "recent")
        XCTAssertEqual(LocationVocabulary.deliveryBlockTitle, "on its way")
        XCTAssertEqual(LocationVocabulary.tierChangeFraming, "changes apply from now on — nothing already in your journal is altered.")
        XCTAssertEqual(LocationVocabulary.deliveryNeedsAttentionTemplate, "{N} location {update} {needs} attention.")
        XCTAssertEqual(LocationVocabulary.deliverySendingTemplate, "{N} location {update} on the way to your journal.")
        XCTAssertEqual(LocationVocabulary.deliveryQuietLine, "nothing waiting right now.")
        XCTAssertEqual(LocationVocabulary.downgradeBodyTemplate, "you chose {tier}, but iOS hasn't authorized that. your journal will show the gaps honestly — sol never fills them in.")
        XCTAssertEqual(LocationVocabulary.openSettingsAction, "open iOS Settings")
        XCTAssertEqual(LocationVocabulary.matchToAllowedAction, "match it to what's allowed")
        XCTAssertEqual(LocationVocabulary.restrictedBody, "location is turned off for sol by a restriction on this device. sol can't keep your day until that's lifted.")
        XCTAssertEqual(LocationVocabulary.honestGap, "gap here — location wasn't available.")
        XCTAssertEqual(LocationVocabulary.deleteConfirmBody, "delete everything location added to your journal? this removes where your day happened. other things in your journal stay. this can't be undone.")
        XCTAssertEqual(LocationVocabulary.deleteConfirmButton, "delete location's contributions")
        XCTAssertEqual(LocationVocabulary.deleteReceiptHeadlineTemplate, "deleted. removed from your journal: where your day happened, across {N} days.")
    }

    func testDowngradeBodySubstitutesTierLabel() {
        XCTAssertEqual(
            LocationVocabulary.downgradeBody(tierLabel: LocationTier.balanced.label),
            "you chose places + comings and goings, but iOS hasn't authorized that. your journal will show the gaps honestly — sol never fills them in."
        )
    }

    func testSharingStatusMapsEveryCapabilityVerbatim() {
        for (capability, expected) in Self.sharingStatusExpectations {
            XCTAssertEqual(LocationVocabulary.sharingStatus(for: capability), expected, "\(capability)")
        }
    }

    func testDeleteReceiptHeadlineSubstitutesDayCount() {
        XCTAssertEqual(
            LocationVocabulary.deleteReceiptHeadline(days: 4),
            "deleted. removed from your journal: where your day happened, across 4 days."
        )
    }

    func testDeliverySummaryCopySubstitutesValues() {
        XCTAssertEqual(LocationVocabulary.deliveryNeedsAttention(count: 1), "1 location update needs attention.")
        XCTAssertEqual(LocationVocabulary.deliveryNeedsAttention(count: 2), "2 location updates need attention.")
        XCTAssertEqual(LocationVocabulary.deliverySending(count: 1), "1 location update on the way to your journal.")
        XCTAssertEqual(LocationVocabulary.deliverySending(count: 3), "3 location updates on the way to your journal.")
    }

    func testRetiredLocationOwnerVisibleCopyStaysRetired() {
        let strings = self.allOwnerVisibleStrings
        let retiredExactStrings = [
            "removing location's contributions from your journal arrives in a later update.",
        ]

        for retired in retiredExactStrings {
            XCTAssertFalse(strings.contains(retired))
        }
        for string in strings {
            XCTAssertFalse(string.contains("arrives in a later update"))
        }
    }

    private var allOwnerVisibleStrings: [String] {
        let tierStrings = LocationTier.allCases.flatMap { tier in
            [
                tier.label,
                tier.body,
            ]
        }
        let presentationStrings = [
            LocationDetailPresentation.deliverySummary(pending: 0, failed: 1).line,
            LocationDetailPresentation.deliverySummary(pending: 1, failed: 0).line,
            LocationDetailPresentation.deliverySummary(pending: 0, failed: 0).line,
            LocationDetailPresentation.recoveryButtonLabel(for: .openSettings),
            LocationDetailPresentation.recoveryButtonLabel(for: .matchToAllowed(suggestedTier: .light)),
            LocationDetailPresentation.tierFraming,
        ]
        let mappingStrings = [
            locationSourceState(effective: .restricted, tier: .balanced, paused: false).1?.message,
            locationSourceState(effective: .denied, tier: .balanced, paused: false).1?.message,
            locationSourceState(effective: .whenInUse(accuracy: .full), tier: .balanced, paused: false).1?.message,
        ].compactMap { $0 }
        let sharingStatusStrings = Self.sharingStatusExpectations.map { capability, _ in
            LocationVocabulary.sharingStatus(for: capability)
        }

        return [
            LocationVocabulary.sourceDisplayName,
            LocationVocabulary.activeSubtext,
            LocationVocabulary.preEnrollmentValue,
            LocationVocabulary.tierDialHeader,
            LocationVocabulary.tierDialSubhead,
            LocationVocabulary.lightLabel,
            LocationVocabulary.lightBody,
            LocationVocabulary.balancedLabel,
            LocationVocabulary.balancedBody,
            LocationVocabulary.balancedDefaultBadge,
            LocationVocabulary.fullLabel,
            LocationVocabulary.fullBody,
            LocationVocabulary.batteryHonesty,
            LocationVocabulary.alwaysBackgroundPrimer,
            LocationVocabulary.turnOnLocation,
            LocationVocabulary.alwaysPrimerHeader,
            LocationVocabulary.alwaysPrimerContinue,
            LocationVocabulary.stateBlockTitle,
            LocationVocabulary.tierBlockTitle,
            LocationVocabulary.recentBlockTitle,
            LocationVocabulary.deliveryBlockTitle,
            LocationVocabulary.tierChangeFraming,
            LocationVocabulary.deliveryNeedsAttentionTemplate,
            LocationVocabulary.deliverySendingTemplate,
            LocationVocabulary.deliveryQuietLine,
            LocationVocabulary.downgradeBodyTemplate,
            LocationVocabulary.openSettingsAction,
            LocationVocabulary.matchToAllowedAction,
            LocationVocabulary.restrictedBody,
            LocationVocabulary.honestGap,
            LocationVocabulary.deleteConfirmBody,
            LocationVocabulary.deleteConfirmButton,
            LocationVocabulary.deleteReceiptHeadlineTemplate,
            LocationVocabulary.downgradeBody(tierLabel: LocationTier.balanced.label),
            LocationVocabulary.deleteReceiptHeadline(days: 4),
            LocationVocabulary.deliveryNeedsAttention(count: 1),
            LocationVocabulary.deliveryNeedsAttention(count: 2),
            LocationVocabulary.deliverySending(count: 1),
            LocationVocabulary.deliverySending(count: 3),
        ] + tierStrings + presentationStrings + mappingStrings + sharingStatusStrings
    }

    private static let sharingStatusExpectations: [(LocationCapability, String)] = [
        (.always(accuracy: .full), "sharing location: always · precise"),
        (.always(accuracy: .reduced), "sharing location: always · reduced precision"),
        (.whenInUse(accuracy: .full), "sharing location: while sol is open · precise"),
        (.whenInUse(accuracy: .reduced), "sharing location: while sol is open · reduced precision"),
        (.notDetermined, "sharing location: not yet decided"),
        (.servicesDisabled, "sharing location: off · location services disabled"),
        (.denied, "sharing location: off"),
        (.restricted, "sharing location: restricted"),
    ]
}
