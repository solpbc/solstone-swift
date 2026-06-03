// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct LocationDeliverySummary: Equatable, Sendable {
    let line: String
    let showsRetry: Bool
}

nonisolated enum LocationDetailPresentation {
    static func deliverySummary(
        pending: Int,
        failed: Int,
        lastUploadAt: Date?
    ) -> LocationDeliverySummary {
        if failed > 0 {
            return LocationDeliverySummary(
                line: LocationVocabulary.deliveryNeedsAttention(count: failed),
                showsRetry: true
            )
        }

        if pending > 0 {
            return LocationDeliverySummary(
                line: LocationVocabulary.deliverySending(count: pending),
                showsRetry: false
            )
        }

        if let lastUploadAt {
            return LocationDeliverySummary(
                line: LocationVocabulary.deliveryLastSaved(time: self.shortTimeLabel(for: lastUploadAt)),
                showsRetry: false
            )
        }

        return LocationDeliverySummary(
            line: LocationVocabulary.deliveryQuietLine,
            showsRetry: false
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

    static func shortTimeLabel(
        for date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
