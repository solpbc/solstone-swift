// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum SegmentWireTimeFormatter {
    static func configure(_ formatter: DateFormatter) {
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
    }

    /// The whole seconds a segment name ends with. Never below 1, and 1 for a duration that is
    /// not a number or whose rounding does not fit in `Int`: a stored manifest can decode any
    /// `Double`, and a name must still be written for it.
    static func durationSuffix(seconds: Double) -> Int {
        max(1, Int(exactly: seconds.rounded()) ?? 1)
    }
}
