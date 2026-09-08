// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceFault: Equatable, Sendable {
    case watchUnsupported
    case watchChecking
    case watchActivationFailed
    case watchNoWatchPaired
    case watchReadyToInstall
    case watchInstalledNeverOpened
    case watchStuck
    case locationRestricted
    case locationDenied
    case locationServicesDisabled
    case locationNotDetermined
    case locationGrantBelowTier
    case microphoneDenied
    case screencastNeedsAttention
    case screencastUnavailable
}

nonisolated enum SourceFaultAction: Equatable, Sendable {
    case none
    case routeToInstallOrOpen
    case openSettings
    case matchToAllowed
}

nonisolated func sourceFaultAction(_ fault: SourceFault) -> SourceFaultAction {
    switch fault {
    case .locationDenied, .locationServicesDisabled, .locationNotDetermined, .microphoneDenied:
        .openSettings
    case .watchUnsupported, .watchChecking, .watchActivationFailed, .watchNoWatchPaired, .watchStuck:
        .none
    case .watchReadyToInstall, .watchInstalledNeverOpened:
        .routeToInstallOrOpen
    case .locationRestricted:
        .none
    case .locationGrantBelowTier:
        .matchToAllowed
    case .screencastNeedsAttention, .screencastUnavailable:
        .none
    }
}

nonisolated func watchSourceFault(_ lane: PhoneWatchSourceLane) -> SourceFault? {
    switch lane {
    case .unsupported:
        .watchUnsupported
    case .checking:
        .watchChecking
    case .activationFailed:
        .watchActivationFailed
    case .noWatchPaired:
        .watchNoWatchPaired
    case .readyToSetUp(.installApp):
        .watchReadyToInstall
    case .installedNeverOpened:
        .watchInstalledNeverOpened
    case .installedActive(.stuck):
        .watchStuck
    case .installedActive(.stoppedItself), .installedActive(.observing),
         .installedActive(.receiving), .installedActive(.waiting), .installedActive(.idle):
        nil
    }
}

nonisolated func locationSourceFault(
    effective: LocationCapability,
    tier: LocationTier,
    paused: Bool
) -> SourceFault? {
    if paused {
        return nil
    }
    if tier.isSatisfied(by: effective) {
        return nil
    }
    switch effective {
    case .restricted:
        return .locationRestricted
    case .denied:
        return .locationDenied
    case .servicesDisabled:
        return .locationServicesDisabled
    case .notDetermined:
        return .locationNotDetermined
    case .whenInUse, .always:
        return .locationGrantBelowTier
    }
}

nonisolated func observerSourceFault(_ state: ObserverState) -> SourceFault? {
    switch state {
    case .idle, .starting, .active, .stopping:
        nil
    case .error(.permissionDenied):
        .microphoneDenied
    case .error(.audioSessionConflict), .error(.diskFull), .error(.uploadFailed), .error(.unavailable):
        nil
    }
}

nonisolated func screencastSourceFault(_ state: ScreencastManager.State) -> SourceFault? {
    switch state {
    case .off, .starting, .active:
        nil
    case .needsAttention:
        .screencastNeedsAttention
    case .unavailable:
        .screencastUnavailable
    }
}
