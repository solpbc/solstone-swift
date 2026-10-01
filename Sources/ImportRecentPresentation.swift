// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ImportRecentPresentation {
    static func recentText(
        pendingCount: Int,
        lastDeliveredAt: Date?,
        failedCount: Int,
        awaitingMarkConfirmation: Bool,
        connectionStatus: ConnectionSyncStatus,
        isStalled: Bool
    ) -> String {
        let showsAwaiting = MarkConfirmationDisplay.showsAwaitingWords(
            awaitingMarkConfirmation: awaitingMarkConfirmation,
            status: connectionStatus,
            isStalled: isStalled
        )
        if showsAwaiting {
            if pendingCount > 0 {
                return SourceVocabulary.awaitingMarkConfirmationLine
            } else if lastDeliveredAt != nil {
                return SourceVocabulary.shareDeliveredProgress
            } else if failedCount > 0 {
                return SourceVocabulary.awaitingMarkConfirmationLine
            } else {
                return SourceVocabulary.recentEmpty
            }
        } else {
            if pendingCount > 0 {
                return SourceVocabulary.shareSendingProgress
            } else if lastDeliveredAt != nil {
                return SourceVocabulary.shareDeliveredProgress
            } else if failedCount > 0 {
                return SourceVocabulary.onThisPhoneWaitingExplain
            } else {
                return SourceVocabulary.recentEmpty
            }
        }
    }
}
