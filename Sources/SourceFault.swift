// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceFault: Equatable, Sendable {
    case bluetoothOff
    case unauthorized
    case unsupported
    case pendantOutOfRange
    case pendantConnectFailed
    case pendantCodecUnsupported
    case pendantAudioUnavailable
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
    /// Deliberately unproduced today: AC2's never-retry contract is "no fault maps here."
    /// Delivery retry is a real action in facts, not this slot.
    case retry
    case routeToInstallOrOpen
    case openSettings
    case matchToAllowed
}

nonisolated func sourceFaultAction(_ fault: SourceFault) -> SourceFaultAction {
    switch fault {
    case .bluetoothOff:
        // CANON DEVIATION: mobile-shell.md / copy-deck.md prescribe "open bluetooth
        // settings" for bluetooth-off. There is no public URL that opens Bluetooth
        // settings; UIApplication.openSettingsURLString opens the app's settings page
        // and cannot toggle CBManagerState.poweredOff. §2.4: a control that cannot
        // perform what it names does not exist. Jer accepted this as rule-beats-example.
        .none
    case .unauthorized, .locationDenied, .locationServicesDisabled, .locationNotDetermined, .microphoneDenied:
        .openSettings
    case .unsupported, .pendantOutOfRange, .pendantConnectFailed, .pendantCodecUnsupported, .pendantAudioUnavailable:
        .none
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

nonisolated func omiSourceFault(_ attention: OmiAttention) -> SourceFault {
    switch attention {
    case .bluetoothOff:
        .bluetoothOff
    case .unauthorized:
        .unauthorized
    case .unsupported:
        .unsupported
    case .pendantNotFound:
        .pendantOutOfRange
    case .connectFailed:
        .pendantConnectFailed
    case .codecNotOpus:
        .pendantCodecUnsupported
    case .audioUnavailable:
        .pendantAudioUnavailable
    }
}

nonisolated func omiSourceFault(state: OmiSourceState, enabled: Bool) -> SourceFault? {
    guard enabled else {
        return nil
    }
    if case .needsAttention(let attention) = state {
        return omiSourceFault(attention)
    }
    return nil
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
