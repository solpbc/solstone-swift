// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

nonisolated enum WatchSessionReadiness: Equatable, Sendable {
    case unsupported
    case checking
    case activationFailed
    case activated(WatchActivatedReadiness)
}

nonisolated enum WatchActivatedReadiness: Equatable, Sendable {
    case noWatchPaired
    case readyToSetUp(WatchSetupRequirement)
    case installedNeverOpened
    case installedActive
}

nonisolated enum WatchSetupRequirement: Equatable, Sendable {
    case installApp
}

nonisolated enum PhoneWatchSourceLane: Equatable, Sendable {
    case unsupported
    case checking
    case activationFailed
    case noWatchPaired
    case readyToSetUp(WatchSetupRequirement)
    case installedNeverOpened
    case installedActive(InstalledFlow)

    nonisolated enum InstalledFlow: Equatable, Sendable {
        case stuck(WatchPipelineStuck)
        case stoppedItself(WatchNoticeCopy)
        case observing
        case receiving
        case waiting(WatchWaitingBreakdown)
        case idle(WatchSideWaiting)
    }
}

nonisolated enum WatchRecordingStatus: Equatable, Sendable {
    static let defaultTTL: TimeInterval = 45
    // The receipt window is defaultTTL (45s) plus a 15s decay margin so a
    // receipt landing just past the recording-status TTL does not flap.
    static let receiptCorroborationTTL: TimeInterval = 60

    case noContext
    case noContextButReceiving
    case stoppedItself(WatchNoticeCopy)
    case observing
    case idle
}

nonisolated struct WatchInstalledFlowInput: Equatable, Sendable {
    let stuck: WatchPipelineStuck
    let recordingStatus: WatchRecordingStatus
    let waiting: WatchWaitingBreakdown
}

nonisolated struct PhoneWatchSourcePresentation: Equatable, Sendable {
    let state: SourceState
    let attention: SourceAttention?
    let subtext: String?
    let statusReason: String?

    init(
        state: SourceState,
        attention: SourceAttention?,
        subtext: String?,
        statusReason: String? = nil
    ) {
        self.state = state
        self.attention = attention
        self.subtext = subtext
        self.statusReason = statusReason
    }
}

nonisolated func watchSessionReadiness(
    isSupported: Bool,
    activationState: WCSessionActivationState,
    activationFailed: Bool,
    activatedReadiness: () -> WatchActivatedReadiness
) -> WatchSessionReadiness {
    guard isSupported else {
        return .unsupported
    }
    if activationFailed {
        return .activationFailed
    }
    guard activationState == .activated else {
        return .checking
    }
    return .activated(activatedReadiness())
}

nonisolated func watchActivatedReadiness(
    isPaired: Bool,
    isWatchAppInstalled: Bool,
    facts: WatchSourceFacts.Snapshot
) -> WatchActivatedReadiness {
    guard isPaired else {
        return .noWatchPaired
    }
    if facts.hasCheckedIn {
        return .installedActive
    }
    if isWatchAppInstalled {
        return .installedNeverOpened
    }
    return .readyToSetUp(.installApp)
}

nonisolated func watchInstalledFlow(_ input: WatchInstalledFlowInput) -> PhoneWatchSourceLane.InstalledFlow {
    if case .stoppedItself(let copy) = input.recordingStatus {
        return .stoppedItself(copy)
    }
    if input.stuck != .none {
        return .stuck(input.stuck)
    }
    switch input.recordingStatus {
    case .stoppedItself:
        preconditionFailure("stopped-itself status should be handled before stuck or waiting")
    case .observing:
        return .observing
    case .noContextButReceiving:
        return .receiving
    case .noContext, .idle:
        if input.waiting.leading != nil {
            return .waiting(input.waiting)
        }
        return .idle(input.waiting.watch)
    }
}

nonisolated func phoneWatchSourceLane(
    session: WatchSessionReadiness,
    flow: WatchInstalledFlowInput
) -> PhoneWatchSourceLane {
    switch session {
    case .unsupported:
        return .unsupported
    case .checking:
        return .checking
    case .activationFailed:
        return .activationFailed
    case .activated(.noWatchPaired):
        return .noWatchPaired
    case .activated(.readyToSetUp(let requirement)):
        return .readyToSetUp(requirement)
    case .activated(.installedNeverOpened):
        return .installedNeverOpened
    case .activated(.installedActive):
        return .installedActive(watchInstalledFlow(flow))
    }
}

nonisolated func phoneWatchSourcePresentation(
    lane: PhoneWatchSourceLane
) -> PhoneWatchSourcePresentation {
    switch lane {
    case .unsupported:
        return PhoneWatchSourcePresentation(state: .off, attention: nil, subtext: nil)
    case .checking:
        return PhoneWatchSourcePresentation(state: .checking, attention: nil, subtext: nil)
    case .activationFailed:
        return PhoneWatchSourcePresentation(
            state: .off,
            attention: nil,
            subtext: SourceVocabulary.watchActivationFailedSubtext
        )
    case .noWatchPaired:
        return PhoneWatchSourcePresentation(
            state: .off,
            attention: nil,
            subtext: SourceVocabulary.watchNoWatchPairedSubtext
        )
    case .readyToSetUp(.installApp):
        return PhoneWatchSourcePresentation(
            state: .readyToSetUp,
            attention: nil,
            subtext: SourceVocabulary.watchReadyToSetUpSubtext
        )
    case .installedNeverOpened:
        return PhoneWatchSourcePresentation(
            state: .enrolling,
            attention: nil,
            subtext: SourceVocabulary.watchInstalledNeverOpenedSubtext
        )
    case .installedActive(.stuck(let stuck)):
        let reason = stuck.reason
        return PhoneWatchSourcePresentation(
            state: .needsAttention,
            attention: reason.map { SourceAttention(message: $0) },
            subtext: reason
        )
    case .installedActive(.stoppedItself(let copy)):
        return PhoneWatchSourcePresentation(
            state: .needsAttention,
            attention: SourceAttention(message: copy.body),
            subtext: copy.title
        )
    case .installedActive(.observing):
        return PhoneWatchSourcePresentation(
            state: .active,
            attention: nil,
            subtext: SourceVocabulary.watchListeningSubtext
        )
    case .installedActive(.receiving):
        return PhoneWatchSourcePresentation(
            state: .active,
            attention: nil,
            subtext: SourceVocabulary.watchReceivingNowSubtext
        )
    case .installedActive(.waiting(let waiting)):
        let status = watchWaitingStatusPresentation(waiting.watch)
        return PhoneWatchSourcePresentation(
            state: .off,
            attention: nil,
            subtext: status.subtext ?? waiting.leading.map { SourceVocabulary.watchWaitingToSyncFromWatch($0.count) },
            statusReason: status.reason
        )
    case .installedActive(.idle(let watchWaiting)):
        let status = watchWaitingStatusPresentation(watchWaiting)
        return PhoneWatchSourcePresentation(
            state: .off,
            attention: nil,
            subtext: status.subtext ?? SourceVocabulary.watchIdleNowSubtext,
            statusReason: status.reason
        )
    }
}

private nonisolated func watchWaitingStatusPresentation(
    _ waiting: WatchSideWaiting
) -> (subtext: String?, reason: String?) {
    switch waiting {
    case .unknown:
        return (
            SourceVocabulary.watchStatusUnknownSubtext,
            SourceVocabulary.watchStatusUnknownReason
        )
    case .reported(_, .fresh):
        return (nil, nil)
    case .reported(_, .stale(_, let age)):
        let text = SourceVocabulary.watchStatusAsOf(
            WatchPipelineReducer.relativeText(secondsAgo: age)
        )
        return (text, text)
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
    if let copy = WatchNoticeCopy(
        terminalReason: context.audioTerminalReason,
        terminalDisposition: context.audioTerminalDisposition
    ) {
        return .stoppedItself(copy)
    }
    if context.audioTerminalDisposition == .ownerStopped {
        return .idle
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
