// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

nonisolated enum LocationEnrollmentEvent: Equatable, Sendable {
    case tierSelected(LocationTier)
    case primerShown
    case startRequested(LocationTier)
}

nonisolated struct LocationEnrollmentPresentation: Equatable, Sendable {
    let preEnrollmentValue: String
    let tierDialHeader: String
    let tierDialSubhead: String
    let batteryHonesty: String
    let alwaysBackgroundPrimer: String
    let turnOnLocation: String
    let alwaysPrimerHeader: String
    let alwaysPrimerContinue: String

    static let current = LocationEnrollmentPresentation(
        preEnrollmentValue: LocationVocabulary.preEnrollmentValue,
        tierDialHeader: LocationVocabulary.tierDialHeader,
        tierDialSubhead: LocationVocabulary.tierDialSubhead,
        batteryHonesty: LocationVocabulary.batteryHonesty,
        alwaysBackgroundPrimer: LocationVocabulary.alwaysBackgroundPrimer,
        turnOnLocation: LocationVocabulary.turnOnLocation,
        alwaysPrimerHeader: LocationVocabulary.alwaysPrimerHeader,
        alwaysPrimerContinue: LocationVocabulary.alwaysPrimerContinue
    )
}

@MainActor
@Observable
final class LocationEnrollmentCoordinator {
    var selectedTier: LocationTier
    var showingPrimer = false

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
        guard !self.showingPrimer else { return }

        switch self.selectedTier.requiredAuthorization {
        case .whenInUse:
            self.emit(.startRequested(self.selectedTier))
            await self.manager.start(tier: self.selectedTier)
        case .always:
            if self.manager.isAuthorizationSufficient(for: self.selectedTier) {
                self.emit(.startRequested(self.selectedTier))
                await self.manager.start(tier: self.selectedTier)
            } else {
                self.showingPrimer = true
                self.emit(.primerShown)
            }
        }
    }

    func acknowledgePrimer() async {
        self.showingPrimer = false
        self.emit(.startRequested(self.selectedTier))
        await self.manager.start(tier: self.selectedTier)
    }
}

private extension LocationEnrollmentCoordinator {
    func emit(_ event: LocationEnrollmentEvent) {
        self.recordEvent(event)
    }
}
