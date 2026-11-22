// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ImportRecentPresentation {
    static func recentText(
        pendingCount: Int,
        lastDeliveredAt: Date?,
        failedCount: Int,
        readyToReviewCount: Int = 0,
        reviewExpiredCount: Int = 0,
        awaitingMarkConfirmation: Bool,
        connectionStatus: ConnectionSyncStatus,
        isStalled: Bool
    ) -> String {
        let showsAwaiting = MarkConfirmationDisplay.showsAwaitingWords(
            awaitingMarkConfirmation: awaitingMarkConfirmation,
            status: connectionStatus,
            isStalled: isStalled
        )
        let hasReview = readyToReviewCount > 0 || reviewExpiredCount > 0
        if showsAwaiting {
            if failedCount > 0 || pendingCount > 0 || hasReview {
                return SourceVocabulary.awaitingMarkConfirmationLine
            } else if lastDeliveredAt != nil {
                return SourceVocabulary.shareDeliveredProgress
            } else {
                return AppStrings.ios_app_importrecentempty()
            }
        } else {
            if failedCount > 0 {
                return AppStrings.ios_app_importstatusleadattention()
            } else if hasReview {
                return AppStrings.ios_app_importtilereadytoreview()
            } else if pendingCount > 0 {
                return SourceVocabulary.shareSendingProgress
            } else if lastDeliveredAt != nil {
                return SourceVocabulary.shareDeliveredProgress
            } else {
                return AppStrings.ios_app_importrecentempty()
            }
        }
    }
}
