// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func locationAttentionLine(fault: SourceFault) -> String? {
    switch fault {
    case .locationRestricted:
        LocationVocabulary.locationAttentionRestricted
    case .locationDenied:
        LocationVocabulary.locationAttentionDenied
    case .locationServicesDisabled:
        LocationVocabulary.locationAttentionServicesOff
    case .locationNotDetermined:
        LocationVocabulary.locationAttentionNotAllowedYet
    case .locationGrantBelowTier:
        LocationVocabulary.locationAttentionBelowChosen
    case .watchUnsupported,
         .watchChecking,
         .watchActivationFailed,
         .watchNoWatchPaired,
         .watchReadyToInstall,
         .watchInstalledNeverOpened,
         .watchStuck,
         .microphoneDenied,
         .screencastNeedsAttention,
         .screencastUnavailable:
        nil
    }
}

nonisolated func locationSourceState(
    effective: LocationCapability,
    tier: LocationTier,
    paused: Bool
) -> (SourceState, SourceAttention?, String?) {
    if paused {
        return (.paused, nil, nil)
    }

    if tier.isSatisfied(by: effective) {
        return (.active, nil, nil)
    }

    let fault = locationSourceFault(effective: effective, tier: tier, paused: paused)
    let line = fault.flatMap { locationAttentionLine(fault: $0) }

    switch effective {
    case .restricted:
        return (.needsAttention, SourceAttention(message: LocationVocabulary.restrictedBody), line)
    case .denied, .servicesDisabled:
        return (
            .needsAttention,
            SourceAttention(message: LocationVocabulary.downgradeBody(tierLabel: tier.label)),
            line
        )
    case .notDetermined, .whenInUse, .always:
        return (
            .needsAttention,
            SourceAttention(message: LocationVocabulary.downgradeBody(tierLabel: tier.label)),
            line
        )
    }
}
