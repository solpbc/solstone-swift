// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct LocationDeliverySummary: Equatable, Sendable {
    let line: String
}

nonisolated enum LocationDetailPresentation {
    static func deliverySummary(
        pending: Int,
        failed: Int
    ) -> LocationDeliverySummary {
        if failed > 0 {
            return LocationDeliverySummary(
                line: LocationVocabulary.deliveryNeedsAttention(count: failed)
            )
        }

        if pending > 0 {
            return LocationDeliverySummary(
                line: LocationVocabulary.deliverySending(count: pending)
            )
        }

        return LocationDeliverySummary(
            line: LocationVocabulary.deliveryQuietLine
        )
    }

    static func recoveryButtonLabel(for recovery: LocationRecovery) -> String {
        switch recovery {
        case .openSettings:
            LocationVocabulary.openSettingsAction
        case .matchToAllowed:
            LocationVocabulary.matchToAllowedAction
        }
    }

    static var tierFraming: String {
        LocationVocabulary.tierChangeFraming
    }
}
