// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func locationSourceState(
    effective: LocationCapability,
    tier: LocationTier,
    paused: Bool
) -> (SourceState, SourceAttention?) {
    if paused {
        return (.paused, nil)
    }

    if tier.isSatisfied(by: effective) {
        return (.active, nil)
    }

    switch effective {
    case .restricted:
        return (.needsAttention, SourceAttention(message: LocationVocabulary.restrictedBody))
    case .denied, .servicesDisabled:
        return (
            .needsAttention,
            SourceAttention(message: LocationVocabulary.downgradeBody(tierLabel: tier.label))
        )
    case .notDetermined, .whenInUse, .always:
        return (
            .needsAttention,
            SourceAttention(message: LocationVocabulary.downgradeBody(tierLabel: tier.label))
        )
    }
}
