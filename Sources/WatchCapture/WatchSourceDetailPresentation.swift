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
    let reason: String
}

nonisolated struct WatchSourceDetailRow: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String {
        self.label
    }
}

nonisolated enum WatchSourceDetailPresentation {
    static func installAffordance(install: WatchInstallState) -> WatchInstallAffordance? {
        guard install == .pairedNoApp else {
            return nil
        }
        return WatchInstallAffordance(
            title: SourceVocabulary.watchInstallTitle,
            instruction: SourceVocabulary.watchInstallInstruction
        )
    }

    static func stuckNotice(for stuck: WatchPipelineStuck) -> WatchStuckNotice? {
        guard let reason = stuck.reason else {
            return nil
        }
        return WatchStuckNotice(reason: reason)
    }
}
