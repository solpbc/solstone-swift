// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum JournalIdentity: Equatable, Sendable {
    case mark(JournalMark)
    case generic
    case unavailable

    static let unavailableWords = ["mark", "unavailable"]
    static let unavailableSpokenValue = "your journal's mark, unavailable right now"

    static func select(isPaired: Bool, sendConfirmed: Bool, mark: JournalMark?) -> JournalIdentity {
        guard isPaired, sendConfirmed else { return .generic }
        if let mark, let valid = JournalMark.validate(mark) {
            return .mark(valid)
        }
        return .unavailable
    }

    var spokenValue: String {
        switch self {
        case .mark(let mark): JournalMarkAccessibility.spokenValue(mark: mark)
        case .generic: JournalMarkGeneric.spokenValue
        case .unavailable: Self.unavailableSpokenValue
        }
    }

    var title: String {
        switch self {
        case .mark(let mark): journalPaneTitle(mark: mark)
        case .generic: journalPaneTitle(mark: nil)
        case .unavailable: Self.unavailableWords.joined(separator: " · ")
        }
    }
}
