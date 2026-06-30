// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum ImporterSourceDetailPresentation {
    static func recentText(pendingCount: Int, lastDeliveredAt: Date?, failedCount: Int) -> String {
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
