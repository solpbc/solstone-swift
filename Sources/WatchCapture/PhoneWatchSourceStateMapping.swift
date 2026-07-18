// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

nonisolated enum WatchInstallState: Equatable, Sendable {
    case notSupported
    case noWatchPaired
    case pairedNoApp
    case receivingUnconfirmedInstall
    case appInstalled
}

nonisolated enum WatchRecordingStatus: Equatable, Sendable {
    static let defaultTTL: TimeInterval = 45
    // The receipt window is defaultTTL (45s) plus a 15s decay margin so a
    // receipt landing just past the recording-status TTL does not flap.
    static let receiptCorroborationTTL: TimeInterval = 60

    case noContext
    case noContextButReceiving
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
    activationState: WCSessionActivationState,
    now: Date,
    lastReceivedAt: Date?
) -> WatchInstallState {
    guard isSupported else {
        return .notSupported
    }
    guard isPaired else {
        return .noWatchPaired
    }
    if isWatchAppInstalled && activationState == .activated {
        return .appInstalled
    }
    return hasFreshReceipt(lastReceivedAt, now: now) ? .receivingUnconfirmedInstall : .pairedNoApp
}

nonisolated func phoneWatchSourceState(
    install: WatchInstallState,
    recordingStatus: WatchRecordingStatus,
    isReachable: Bool,
    isJournalPaired: Bool
) -> (SourceState, SourceAttention?) {
    let presentation = phoneWatchSourcePresentation(
        install: install,
        recordingStatus: recordingStatus,
        isReachable: isReachable,
        isJournalPaired: isJournalPaired
    )
    return (presentation.state, presentation.attention)
}

nonisolated func phoneWatchSourcePresentation(
    install: WatchInstallState,
    recordingStatus: WatchRecordingStatus,
    isReachable: Bool,
    isJournalPaired: Bool
) -> PhoneWatchSourcePresentation {
    switch install {
    case .notSupported:
        return PhoneWatchSourcePresentation(
            state: .off,
            attention: SourceAttention(message: SourceVocabulary.watchNotSupported),
            subtext: SourceState.off.subtext(
                activeSubtext: SourceVocabulary.watchListeningSubtext,
                isJournalPaired: isJournalPaired
            )
        )
    case .noWatchPaired:
        return PhoneWatchSourcePresentation(
            state: .needsAttention,
            attention: SourceAttention(message: SourceVocabulary.watchNoWatchPaired),
            subtext: SourceState.needsAttention.subtext(
                activeSubtext: SourceVocabulary.watchListeningSubtext,
                isJournalPaired: isJournalPaired
            )
        )
    case .pairedNoApp:
        return PhoneWatchSourcePresentation(
            state: .needsAttention,
            attention: SourceAttention(message: SourceVocabulary.watchAppNotInstalled),
            subtext: SourceState.needsAttention.subtext(
                activeSubtext: SourceVocabulary.watchListeningSubtext,
                isJournalPaired: isJournalPaired
            )
        )
    case .receivingUnconfirmedInstall:
        return PhoneWatchSourcePresentation(
            state: .off,
            attention: nil,
            subtext: SourceVocabulary.watchReceivingSubtext
        )
    case .appInstalled:
        switch recordingStatus {
        case .noContext:
            if isReachable {
                return PhoneWatchSourcePresentation(
                    state: .off,
                    attention: nil,
                    subtext: SourceVocabulary.watchConnectedNowSubtext
                )
            }
            return PhoneWatchSourcePresentation(
                state: .off,
                attention: nil,
                subtext: SourceVocabulary.watchNoContextSubtext
            )
        case .noContextButReceiving:
            return PhoneWatchSourcePresentation(
                state: .off,
                attention: nil,
                subtext: SourceVocabulary.watchReceivingSubtext
            )
        case .observing:
            return PhoneWatchSourcePresentation(
                state: .active,
                attention: nil,
                subtext: SourceVocabulary.watchListeningSubtext
            )
        case .idle:
            if isReachable {
                return PhoneWatchSourcePresentation(
                    state: .off,
                    attention: nil,
                    subtext: SourceVocabulary.watchConnectedNowSubtext
                )
            }
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
    ttl: TimeInterval = WatchRecordingStatus.defaultTTL,
    lastReceivedAt: Date?
) -> WatchRecordingStatus {
    guard let context else {
        return hasFreshReceipt(lastReceivedAt, now: now) ? .noContextButReceiving : .noContext
    }
    switch context.phase {
    case .idle, .stopping:
        return .idle
    case .observing:
        let elapsed = max(0, now.timeIntervalSince(context.asOf))
        return elapsed < ttl ? .observing : .idle
    }
}

private nonisolated func hasFreshReceipt(_ lastReceivedAt: Date?, now: Date) -> Bool {
    guard let lastReceivedAt else {
        return false
    }
    let elapsed = max(0, now.timeIntervalSince(lastReceivedAt))
    return elapsed < WatchRecordingStatus.receiptCorroborationTTL
}
