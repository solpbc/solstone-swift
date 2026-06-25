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

nonisolated enum WatchRecordingStatus: Equatable, Sendable {
    static let defaultTTL: TimeInterval = 45

    case noContext
    case observing
    case idle
}

nonisolated struct PhoneWatchSourcePresentation: Equatable, Sendable {
    let state: SourceState
    let attention: SourceAttention?
    let subtext: String
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
    recordingStatus: WatchRecordingStatus
) -> (SourceState, SourceAttention?) {
    let presentation = phoneWatchSourcePresentation(
        install: install,
        recordingStatus: recordingStatus
    )
    return (presentation.state, presentation.attention)
}

nonisolated func phoneWatchSourcePresentation(
    install: WatchInstallState,
    recordingStatus: WatchRecordingStatus
) -> PhoneWatchSourcePresentation {
    switch install {
    case .notSupported:
        return PhoneWatchSourcePresentation(
            state: .off,
            attention: SourceAttention(message: SourceVocabulary.watchNotSupported),
            subtext: SourceState.off.subtext(activeSubtext: SourceVocabulary.watchListeningSubtext)
        )
    case .noWatchPaired:
        return PhoneWatchSourcePresentation(
            state: .needsAttention,
            attention: SourceAttention(message: SourceVocabulary.watchNoWatchPaired),
            subtext: SourceState.needsAttention.subtext(activeSubtext: SourceVocabulary.watchListeningSubtext)
        )
    case .pairedNoApp:
        return PhoneWatchSourcePresentation(
            state: .needsAttention,
            attention: SourceAttention(message: SourceVocabulary.watchAppNotInstalled),
            subtext: SourceState.needsAttention.subtext(activeSubtext: SourceVocabulary.watchListeningSubtext)
        )
    case .appInstalled:
        switch recordingStatus {
        case .noContext:
            return PhoneWatchSourcePresentation(
                state: .off,
                attention: nil,
                subtext: SourceVocabulary.watchNoContextSubtext
            )
        case .observing:
            return PhoneWatchSourcePresentation(
                state: .active,
                attention: nil,
                subtext: SourceVocabulary.watchListeningSubtext
            )
        case .idle:
            return PhoneWatchSourcePresentation(
                state: .off,
                attention: nil,
                subtext: SourceVocabulary.watchIdleSubtext
            )
        }
    }
}

nonisolated func watchRecordingStatus(
    context: WatchStatusContext?,
    now: Date,
    ttl: TimeInterval = WatchRecordingStatus.defaultTTL
) -> WatchRecordingStatus {
    guard let context else {
        return .noContext
    }
    switch context.phase {
    case .idle, .stopping:
        return .idle
    case .observing:
        let elapsed = max(0, now.timeIntervalSince(context.asOf))
        return elapsed < ttl ? .observing : .idle
    }
}
