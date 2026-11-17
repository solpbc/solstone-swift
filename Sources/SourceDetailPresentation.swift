// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SourceDetailPresentation {
    /// The running timer. The state card's verdict line already says "on", so this is the time alone.
    static func elapsedLine(formatted: String) -> String {
        formatted
    }

    static func elapsedAccessibilityLabel(formatted: String) -> String {
        AppStrings.ios_app_elapsedaccessibilitylabel("\(SourceVocabulary.observerActiveSubtext)", "\(formatted)")
    }
}

nonisolated struct AudioDeliverySummary: Equatable, Sendable {
    let line: String
}

/// The audio pane's delivery line, in audio's own words.
nonisolated enum AudioDetailPresentation {
    static func deliverySummary(pending: Int, failed: Int) -> AudioDeliverySummary {
        if failed > 0 { return AudioDeliverySummary(line: AppStrings.ios_delivery_audio_attention(failed)) }
        if pending > 0 { return AudioDeliverySummary(line: AppStrings.ios_delivery_audio_sending(pending)) }
        return AudioDeliverySummary(line: LocationVocabulary.deliveryQuietLine)
}
}
