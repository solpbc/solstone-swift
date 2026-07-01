// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import WatchConnectivity

nonisolated struct WatchSourceSyncSummary: Equatable, Sendable {
    let received: Int
    let waiting: Int
    let handedToJournal: Int
    let lastSyncAt: Date?
}

nonisolated struct WatchInstallAffordance: Equatable, Sendable {
    let title: String
    let instruction: String
}

nonisolated struct WatchSourceDetailRow: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String {
        self.label
    }
}

nonisolated enum WatchSourceDetailPresentation {
    static func syncSummary(
        received: Int,
        pending: Int,
        failed: Int,
        lastUploadAt: Date?
    ) -> WatchSourceSyncSummary {
        let safeReceived = max(0, received)
        let unresolved = max(0, pending) + max(0, failed)
        let waiting = min(safeReceived, unresolved)
        let handed = lastUploadAt == nil ? 0 : max(0, safeReceived - waiting)
        return WatchSourceSyncSummary(
            received: safeReceived,
            waiting: waiting,
            handedToJournal: handed,
            lastSyncAt: lastUploadAt
        )
    }

    static func installAffordance(install: WatchInstallState) -> WatchInstallAffordance? {
        guard install == .pairedNoApp else {
            return nil
        }
        return WatchInstallAffordance(
            title: SourceVocabulary.watchInstallTitle,
            instruction: SourceVocabulary.watchInstallInstruction
        )
    }

    static func syncRows(summary: WatchSourceSyncSummary, now: Date) -> [WatchSourceDetailRow] {
        [
            WatchSourceDetailRow(label: SourceVocabulary.watchReceivedLabel, value: "\(summary.received)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchNotYetInJournalLabel, value: "\(summary.waiting)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchHandedToJournalLabel, value: "\(summary.handedToJournal)"),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastSyncLabel, value: self.lastSyncText(summary.lastSyncAt, now: now))
        ]
    }

    static func diagnosticsRows(
        activationState: WCSessionActivationState,
        isPaired: Bool,
        isWatchAppInstalled: Bool,
        watchStatus: WatchStatusContext? = nil,
        lastReceivedAt: Date?,
        lastStagingError: String?,
        lastUploadAt: Date?,
        lastUploadError: String?,
        now: Date
    ) -> [WatchSourceDetailRow] {
        [
            WatchSourceDetailRow(label: SourceVocabulary.watchActivationLabel, value: self.activationText(activationState)),
            WatchSourceDetailRow(label: SourceVocabulary.watchPairedWithPhoneLabel, value: self.booleanText(isPaired)),
            WatchSourceDetailRow(label: SourceVocabulary.watchInstalledLabel, value: self.booleanText(isWatchAppInstalled)),
            WatchSourceDetailRow(label: SourceVocabulary.watchStatusLabel, value: self.watchStatusText(watchStatus, now: now)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastReceivedLabel, value: self.lastReceivedText(lastReceivedAt, now: now)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastStagingDetailLabel, value: self.detailText(lastStagingError)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastSyncDetailLabel, value: self.lastSyncText(lastUploadAt, now: now)),
            WatchSourceDetailRow(label: SourceVocabulary.watchLastUploadErrorLabel, value: self.detailText(lastUploadError))
        ]
    }

    static func diagnosticsExportText(
        syncRows: [WatchSourceDetailRow],
        diagnosticsRows: [WatchSourceDetailRow]
    ) -> String {
        let rows = syncRows + diagnosticsRows
        return ([SourceVocabulary.watchDiagnosticsExportTitle] + rows.map { "\($0.label): \($0.value)" })
            .joined(separator: "\n")
    }

    static func lastSyncText(_ date: Date?, now: Date) -> String {
        guard let date else {
            return SourceVocabulary.watchLastSyncNever
        }
        return self.relativeText(secondsAgo: max(0, now.timeIntervalSince(date)))
    }

    static func lastReceivedText(_ date: Date?, now: Date) -> String {
        guard let date else {
            return SourceVocabulary.watchLastReceivedNever
        }
        return self.relativeText(secondsAgo: max(0, now.timeIntervalSince(date)))
    }

    static func booleanText(_ value: Bool) -> String {
        value ? SourceVocabulary.watchBooleanYes : SourceVocabulary.watchBooleanNo
    }

    static func activationText(_ state: WCSessionActivationState) -> String {
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

    static func detailText(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return SourceVocabulary.watchDetailNone
        }
        return value
    }

    static func relativeText(secondsAgo: TimeInterval) -> String {
        if secondsAgo < 60 {
            return SourceVocabulary.watchRelativeJustNow
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(fromTimeInterval: -secondsAgo)
    }

    static func watchStatusText(_ status: WatchStatusContext?, now: Date) -> String {
        guard let status else {
            return SourceVocabulary.watchDetailNone
        }
        return "\(status.phase.rawValue) · \(self.relativeText(secondsAgo: max(0, now.timeIntervalSince(status.asOf))))"
    }
}
