// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

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

nonisolated struct WatchStuckNotice: Equatable, Sendable {
    let title: String
    let reason: String
    let nextStep: String
}

nonisolated struct WatchSourceDetailRow: Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    let detail: String?

    init(label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    var id: String { self.label }
}

nonisolated struct WatchPipelineRowGroup: Equatable, Sendable {
    let label: String
    let rows: [WatchSourceDetailRow]
}

nonisolated enum WatchSourceDetailPresentation {
    static func installAffordance(lane: PhoneWatchSourceLane) -> WatchInstallAffordance? {
        guard lane == .readyToSetUp(.installApp) else { return nil }
        return WatchInstallAffordance(
            title: SourceVocabulary.watchInstallTitle,
            instruction: SourceVocabulary.watchInstallInstruction
        )
    }

    static func pipelineGroups(_ rows: [WatchSourceDetailRow]) -> [WatchPipelineRowGroup] {
        [
            WatchPipelineRowGroup(label: SourceVocabulary.watchPipelineReportedGroupLabel, rows: Array(rows.prefix(2))),
            WatchPipelineRowGroup(label: SourceVocabulary.watchPipelineKnownGroupLabel, rows: Array(rows.dropFirst(2)))
        ]
    }

    static func stuckNotice(for stuck: WatchPipelineStuck) -> WatchStuckNotice? {
        guard let reason = stuck.reason else {
            return nil
        }
        let nextStep: String
        switch stuck {
        case .none:
            return nil
        case .relay:
            nextStep = SourceVocabulary.watchPipelineRelayStuckNextStep
        case .handoff:
            nextStep = SourceVocabulary.watchPipelineHandoffStuckNextStep
        case .orphan:
            nextStep = SourceVocabulary.watchPipelineOrphanStuckNextStep
        }
        return WatchStuckNotice(title: SourceVocabulary.watchStuckNoticeTitle, reason: reason, nextStep: nextStep)
    }
}
