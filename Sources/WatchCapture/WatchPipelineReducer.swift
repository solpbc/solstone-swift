// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

nonisolated struct WatchPipelineInput: Sendable {
    let now: Date
    let watchStatus: WatchStatusContext?
    let lifetimeReceived: Int
    let lifetimeHanded: Int
    let nonTerminalCount: Int
    let lastHandedAt: Date?
    let oldestNonTerminalReceivedAt: Date?
    let lastLedgerError: String?
    let pendingCount: Int
    let failedCount: Int
    let inFlightCount: Int
    let lastUploadAt: Date?
    let lastUploadError: String?
    let lastReceivedAt: Date?
    let lastStagingError: String?
    let isPaired: Bool
    let isWatchAppInstalled: Bool
    let activationState: WCSessionActivationState
    let isReachable: Bool
    let isJournalReachable: Bool
}

nonisolated enum WatchPipelineStuck: Equatable, Sendable {
    case none
    case relay
    case handoff
    case orphan

    var reason: String? {
        switch self {
        case .none:
            nil
        case .relay:
            SourceVocabulary.watchPipelineRelayStuckReason
        case .handoff:
            SourceVocabulary.watchPipelineHandoffStuckReason
        case .orphan:
            SourceVocabulary.watchPipelineOrphanStuckReason
        }
    }
}

nonisolated struct WatchPipelineSummary: Equatable, Sendable {
    let pipelineRows: [WatchSourceDetailRow]
    let syncSummary: WatchSourceSyncSummary
    let diagnosticsRows: [WatchSourceDetailRow]
    let diagnosticsExportText: String
    let stuck: WatchPipelineStuck
}

nonisolated enum WatchPipelineReducer {
    // 2× the 45s recording-status TTL → 90s trust boundary
    static let watchClaimFreshnessWindow: TimeInterval = WatchRecordingStatus.defaultTTL * 2
    static let relayStuckThreshold: TimeInterval = 600
    static let handoffStuckThreshold: TimeInterval = 600
    static let orphanStuckThreshold: TimeInterval = 1800

    static func reduce(_ input: WatchPipelineInput) -> WatchPipelineSummary {
        let syncSummary = self.syncSummary(input)
        let pipelineRows = self.pipelineRows(
            context: input.watchStatus,
            summary: syncSummary,
            now: input.now
        )
        let diagnosticsRows = self.diagnosticsRows(input)
        let stuck = self.stuck(input)
        let diagnosticsExportText = self.diagnosticsExportText(
            primaryRows: pipelineRows,
            diagnosticsRows: diagnosticsRows,
            stuck: stuck
        )
        return WatchPipelineSummary(
            pipelineRows: pipelineRows,
            syncSummary: syncSummary,
            diagnosticsRows: diagnosticsRows,
            diagnosticsExportText: diagnosticsExportText,
            stuck: stuck
        )
    }
}

private extension WatchPipelineReducer {
    nonisolated static func age(of date: Date?, now: Date) -> TimeInterval? {
        date.map { max(0, now.timeIntervalSince($0)) }
    }

    nonisolated static func syncSummary(_ input: WatchPipelineInput) -> WatchSourceSyncSummary {
        WatchSourceSyncSummary(
            received: max(0, input.lifetimeReceived),
            waiting: max(0, input.nonTerminalCount),
            handedToJournal: max(0, input.lifetimeHanded),
            lastSyncAt: input.lastHandedAt
        )
    }

    nonisolated static func pipelineRows(
        context: WatchStatusContext?,
        summary: WatchSourceSyncSummary,
        now: Date
    ) -> [WatchSourceDetailRow] {
        [
            WatchSourceDetailRow(
                label: SourceVocabulary.watchPipelineSaved,
                value: self.pipelineValue(
                    context: context,
                    count: context?.queuedCount ?? 0,
                    now: now
                )
            ),
            WatchSourceDetailRow(
                label: SourceVocabulary.watchPipelineSending,
                value: self.pipelineValue(
                    context: context,
                    count: context?.transferringCount ?? 0,
                    now: now
                )
            ),
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "\(summary.received)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "\(summary.waiting)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "\(summary.handedToJournal)")
        ]
    }

    nonisolated static func diagnosticsRows(_ input: WatchPipelineInput) -> [WatchSourceDetailRow] {
        var rows = [
            WatchSourceDetailRow(label: SourceVocabulary.watchActivationLabel, value: self.activationText(input.activationState)),
            WatchSourceDetailRow(label: SourceVocabulary.watchPairedWithPhoneLabel, value: self.booleanText(input.isPaired)),
            WatchSourceDetailRow(label: SourceVocabulary.watchInstalledLabel, value: self.booleanText(input.isWatchAppInstalled)),
            WatchSourceDetailRow(label: SourceVocabulary.watchReachableLabel, value: self.booleanText(input.isReachable)),
            WatchSourceDetailRow(label: SourceVocabulary.watchStatusLabel, value: self.watchStatusText(input.watchStatus, now: input.now)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastReceivedLabel, value: self.lastReceivedText(input.lastReceivedAt, now: input.now)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastStagingDetailLabel, value: self.detailText(input.lastStagingError))
        ]
        if let lastLedgerError = input.lastLedgerError, !lastLedgerError.isEmpty {
            rows.append(WatchSourceDetailRow(label: SourceVocabulary.watchLastLedgerDetailLabel, value: lastLedgerError))
        }
        rows.append(WatchSourceDetailRow(label: SourceVocabulary.watchLastSyncDetailLabel, value: self.lastSyncText(input.lastUploadAt, now: input.now)))
        rows.append(WatchSourceDetailRow(label: SourceVocabulary.watchLastUploadErrorLabel, value: self.detailText(input.lastUploadError)))
        return rows
    }

    nonisolated static func diagnosticsExportText(
        primaryRows: [WatchSourceDetailRow],
        diagnosticsRows: [WatchSourceDetailRow],
        stuck: WatchPipelineStuck
    ) -> String {
        let rows = primaryRows + diagnosticsRows
        var lines = [SourceVocabulary.watchDiagnosticsExportTitle] + rows.map { "\($0.label): \($0.value)" }
        if let reason = stuck.reason {
            lines.append(reason)
        }
        return lines.joined(separator: "\n")
    }

    nonisolated static func stuck(_ input: WatchPipelineInput) -> WatchPipelineStuck {
        if self.isOrphanStuck(input) {
            return .orphan
        }
        if self.isHandoffStuck(input) {
            return .handoff
        }
        if self.isRelayStuck(input) {
            return .relay
        }
        return .none
    }

    nonisolated static func isRelayStuck(_ input: WatchPipelineInput) -> Bool {
        guard let watchStatus = input.watchStatus,
              let claimAge = self.age(of: watchStatus.asOf, now: input.now),
              claimAge <= self.watchClaimFreshnessWindow,
              max(0, watchStatus.queuedCount) > 0,
              input.isPaired,
              input.isWatchAppInstalled,
              input.activationState == .activated,
              let receivedAge = self.age(of: input.lastReceivedAt, now: input.now)
        else {
            return false
        }
        return receivedAge >= self.relayStuckThreshold
    }

    nonisolated static func isHandoffStuck(_ input: WatchPipelineInput) -> Bool {
        guard let age = self.age(of: input.oldestNonTerminalReceivedAt, now: input.now),
              age >= self.handoffStuckThreshold,
              input.isJournalReachable
        else {
            return false
        }
        return self.uploadQueueCount(input) > 0
    }

    nonisolated static func isOrphanStuck(_ input: WatchPipelineInput) -> Bool {
        guard let age = self.age(of: input.oldestNonTerminalReceivedAt, now: input.now),
              age >= self.orphanStuckThreshold
        else {
            return false
        }
        return self.uploadQueueCount(input) == 0
    }

    nonisolated static func uploadQueueCount(_ input: WatchPipelineInput) -> Int {
        max(0, input.pendingCount) + max(0, input.failedCount) + max(0, input.inFlightCount)
    }

    nonisolated static func lastSyncText(_ date: Date?, now: Date) -> String {
        guard let secondsAgo = self.age(of: date, now: now) else {
            return SourceVocabulary.watchLastSyncNever
        }
        return self.relativeText(secondsAgo: secondsAgo)
    }

    nonisolated static func lastReceivedText(_ date: Date?, now: Date) -> String {
        guard let secondsAgo = self.age(of: date, now: now) else {
            return SourceVocabulary.watchLastReceivedNever
        }
        return self.relativeText(secondsAgo: secondsAgo)
    }

    nonisolated static func booleanText(_ value: Bool) -> String {
        value ? SourceVocabulary.watchBooleanYes : SourceVocabulary.watchBooleanNo
    }

    nonisolated static func activationText(_ state: WCSessionActivationState) -> String {
        switch state {
        case .activated:
            SourceVocabulary.watchActivationActivated
        case .inactive:
            SourceVocabulary.watchActivationInactive
        case .notActivated:
            SourceVocabulary.watchActivationNotActivated
        @unknown default:
            SourceVocabulary.watchActivationNotActivated
        }
    }

    nonisolated static func detailText(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return SourceVocabulary.watchDetailNone
        }
        return value
    }

    nonisolated static func pipelineValue(
        context: WatchStatusContext?,
        count: Int,
        now: Date
    ) -> String {
        guard let context else {
            return SourceVocabulary.watchPipelineUnknown
        }
        let safeCount = max(0, count)
        let secondsAgo = self.age(of: context.asOf, now: now) ?? 0
        guard secondsAgo > self.watchClaimFreshnessWindow else {
            return "\(safeCount)"
        }
        return "\(safeCount) · \(self.relativeText(secondsAgo: secondsAgo))"
    }

    nonisolated static func relativeText(secondsAgo: TimeInterval) -> String {
        if secondsAgo < 60 {
            return SourceVocabulary.watchRelativeJustNow
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(fromTimeInterval: -secondsAgo)
    }

    nonisolated static func watchStatusText(_ status: WatchStatusContext?, now: Date) -> String {
        guard let status else {
            return SourceVocabulary.watchDetailNone
        }
        return "\(status.phase.rawValue) · \(self.relativeText(secondsAgo: self.age(of: status.asOf, now: now) ?? 0))"
    }
}
