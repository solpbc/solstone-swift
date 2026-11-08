// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated enum LocationEnrollmentEvent: Equatable, Sendable {
    case tierSelected(LocationTier)
    case startRequested(LocationTier)
}

nonisolated struct LocationEnrollmentPresentation: Equatable, Sendable {
    let preEnrollmentValue: String
    let tierDialHeader: String
    let tierDialSubhead: String
    let batteryHonesty: String
    let turnOnLocation: String

    static func current(isJournalPaired: Bool) -> LocationEnrollmentPresentation {
        LocationEnrollmentPresentation(
            preEnrollmentValue: LocationVocabulary.preEnrollmentValue(isJournalPaired: isJournalPaired),
            tierDialHeader: LocationVocabulary.tierDialHeader,
            tierDialSubhead: LocationVocabulary.tierDialSubhead,
            batteryHonesty: LocationVocabulary.batteryHonesty,
            turnOnLocation: LocationVocabulary.turnOnLocation
        )
    }
}

@MainActor
@Observable
final class LocationEnrollmentCoordinator {
    var selectedTier: LocationTier

    @ObservationIgnored private let manager: LocationManager
    @ObservationIgnored private let recordEvent: @MainActor @Sendable (LocationEnrollmentEvent) -> Void

    init(
        manager: LocationManager,
        selectedTier: LocationTier = .defaultTier,
        recordEvent: @escaping @MainActor @Sendable (LocationEnrollmentEvent) -> Void = { _ in }
    ) {
        self.manager = manager
        self.selectedTier = selectedTier
        self.recordEvent = recordEvent
    }

    func selectTier(_ tier: LocationTier) {
        self.selectedTier = tier
        self.emit(.tierSelected(tier))
    }

    func confirm() async {
        self.emit(.startRequested(self.selectedTier))
        await self.manager.start(tier: self.selectedTier)
    }
}

private extension LocationEnrollmentCoordinator {
    func emit(_ event: LocationEnrollmentEvent) {
        self.recordEvent(event)
    }
}
