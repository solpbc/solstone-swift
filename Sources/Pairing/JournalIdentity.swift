// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum JournalIdentity: Equatable, Sendable {
    case mark(JournalMark)
    case generic
    /// Paired, and the owner has not answered the mark question. Drawn as the generic mark: the
    /// journal exists, so it speaks differently from a device with nothing set up.
    case awaitingConfirmation
    case unavailable

    static let unavailableWords = ["mark", "unavailable"]
    static let unavailableSpokenValue = "your journal's mark, unavailable right now"

    static func select(isPaired: Bool, sendConfirmed: Bool, mark: JournalMark?) -> JournalIdentity {
        guard isPaired else { return .generic }
        guard sendConfirmed else { return .awaitingConfirmation }
        if let mark, let valid = JournalMark.validate(mark) {
            return .mark(valid)
        }
        return .unavailable
    }

    var spokenValue: String {
        switch self {
        case .mark(let mark): JournalMarkAccessibility.spokenValue(mark: mark)
        case .generic: JournalMarkGeneric.spokenValue
        case .awaitingConfirmation: JournalMarkGeneric.awaitingConfirmationSpokenValue
        case .unavailable: Self.unavailableSpokenValue
        }
    }

    var title: String {
        switch self {
        case .mark(let mark): journalPaneTitle(mark: mark)
        case .generic, .awaitingConfirmation: journalPaneTitle(mark: nil)
        case .unavailable: Self.unavailableWords.joined(separator: " · ")
        }
    }

    var words: [String] {
        switch self {
        case .mark(let mark): mark.words
        case .generic, .awaitingConfirmation: JournalMarkGeneric.words
        case .unavailable: Self.unavailableWords
        }
    }
}
