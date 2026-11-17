// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct ScreencastDeliverySummary: Equatable, Sendable {
    let line: String
}

nonisolated enum ScreencastDetailPresentation {
    static func deliverySummary(
        pending: Int,
        failed: Int
    ) -> ScreencastDeliverySummary {
        if failed > 0 { return ScreencastDeliverySummary(line: AppStrings.ios_delivery_screen_attention(failed)) }
        if pending > 0 { return ScreencastDeliverySummary(line: AppStrings.ios_delivery_screen_sending(pending)) }
        return ScreencastDeliverySummary(line: LocationVocabulary.deliveryQuietLine)
}
}
