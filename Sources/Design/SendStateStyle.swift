// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SendStateStyle {
    let foreground: Color
    let dot: Color
    let chipBackground: Color
    let compactLabel: String
    let summaryLabel: String
    let symbol: String

    static func style(for state: OnThisPhoneSendState) -> SendStateStyle {
        switch state {
        case .savedOnThisPhone:
            SendStateStyle(
                foreground: Color("SendState/SavedOnThisPhone/Foreground"),
                dot: Color("SendState/SavedOnThisPhone/Dot"),
                chipBackground: Color("SendState/SavedOnThisPhone/ChipBackground"),
                compactLabel: SourceVocabulary.sendStateCompactSaved,
                summaryLabel: SourceVocabulary.sendStateCompactSaved,
                symbol: "internaldrive"
            )
        case .sending:
            SendStateStyle(
                foreground: Color("SendState/Sending/Foreground"),
                dot: Color("SendState/Sending/Dot"),
                chipBackground: Color("SendState/Sending/ChipBackground"),
                compactLabel: SourceVocabulary.sendStateCompactOnTheWay,
                summaryLabel: SourceVocabulary.sendStateCompactOnTheWay,
                symbol: "arrow.up.circle"
            )
        case .inYourJournal:
            SendStateStyle(
                foreground: Color("SendState/InYourJournal/Foreground"),
                dot: Color("SendState/InYourJournal/Dot"),
                chipBackground: Color("SendState/InYourJournal/ChipBackground"),
                compactLabel: SourceVocabulary.sendStateCompactInJournal,
                summaryLabel: SourceVocabulary.sendStateCompactInJournal,
                symbol: "checkmark.circle"
            )
        case .needsAttention:
            SendStateStyle(
                foreground: Color("SendState/NeedsAttention/Foreground"),
                dot: Color("SendState/NeedsAttention/Dot"),
                chipBackground: Color("SendState/NeedsAttention/ChipBackground"),
                compactLabel: SourceVocabulary.needsAttention,
                summaryLabel: SourceVocabulary.needsAttention,
                symbol: "exclamationmark.triangle"
            )
        }
    }
}

struct SendStateChip: View {
    let state: OnThisPhoneSendState

    private var style: SendStateStyle {
        SendStateStyle.style(for: self.state)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(self.style.dot)
                .frame(width: 7, height: 7)
            Text(self.style.compactLabel)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(self.style.foreground)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(self.style.chipBackground, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.style.compactLabel)
    }
}
