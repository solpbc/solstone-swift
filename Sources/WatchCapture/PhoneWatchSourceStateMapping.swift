// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

nonisolated enum WatchInstallState: Equatable, Sendable {
    case notSupported
    case noWatchPaired
    case pairedNoApp
    case appInstalled
}

nonisolated func watchInstallState(
    isSupported: Bool,
    isPaired: Bool,
    isWatchAppInstalled: Bool,
    activationState: WCSessionActivationState
) -> WatchInstallState {
    guard isSupported else {
        return .notSupported
    }
    guard isPaired else {
        return .noWatchPaired
    }
    guard isWatchAppInstalled && activationState == .activated else {
        return .pairedNoApp
    }
    return .appInstalled
}

nonisolated func phoneWatchSourceState(
    install: WatchInstallState,
    observing: Bool,
    enabled: Bool
) -> (SourceState, SourceAttention?) {
    guard enabled else {
        return (.off, nil)
    }

    switch install {
    case .notSupported:
        return (.off, SourceAttention(message: SourceVocabulary.watchNotSupported))
    case .noWatchPaired:
        return (.needsAttention, SourceAttention(message: SourceVocabulary.watchNoWatchPaired))
    case .pairedNoApp:
        return (.needsAttention, SourceAttention(message: SourceVocabulary.watchAppNotInstalled))
    case .appInstalled:
        return observing ? (.active, nil) : (.off, nil)
    }
}

nonisolated func isWatchObserving(
    lastReceivedAt: Date?,
    now: Date,
    window: TimeInterval = 120
) -> Bool {
    guard let lastReceivedAt, window > 0 else {
        return false
    }
    return now.timeIntervalSince(lastReceivedAt) <= window
}
