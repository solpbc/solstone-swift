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
        if failed > 0 {
            let phrase = failed == 1 ? "stretch of screen needs attention." : "stretches of screen need attention."
            return ScreencastDeliverySummary(line: "\(failed) \(phrase)")
        }

        if pending > 0 {
            let phrase = pending == 1 ? "stretch of screen on the way to your journal." : "stretches of screen on the way to your journal."
            return ScreencastDeliverySummary(line: "\(pending) \(phrase)")
        }

        return ScreencastDeliverySummary(line: "nothing waiting right now.")
    }
}
