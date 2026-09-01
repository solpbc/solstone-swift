// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

struct SourceDetailVerdictLine: View {
    let state: SourceState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: self.state.symbol)
            Text(self.state.label)
        }
        .font(.headline)
    }
}

struct SourceDetailReasonLine: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

struct SourceFaultActionControl: View {
    let action: SourceFaultAction
    let title: String
    let hint: String
    let perform: () -> Void

    var body: some View {
        if self.action != .none {
            Button(self.title, action: self.perform)
                .buttonStyle(.borderedProminent)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHint(self.hint)
        }
    }
}

struct SourceHomeTileControl: View {
    let sourceID: String
    @AppStorage(UserSettings.hiddenHomeSourceIDsKey) private var hiddenHomeSourceIDsData = Data()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(SourceVocabulary.giveThisATileOnHome, isOn: self.isOnHome)
                .font(ShellFont.tileName)
                .tint(.solOrange)
                .frame(minHeight: 44)
            Text(SourceVocabulary.hidingThisNeverTurnsItOff)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ShellMetrics.surfacePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.deckSurface, in: ShellMetrics.cardShape)
        .overlay {
            ShellMetrics.cardShape.stroke(Color.deckHairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("source.homeTile.\(self.sourceID)")
    }

    private var isOnHome: Binding<Bool> {
        Binding(
            get: {
                !UserSettings.decodeHiddenHomeSourceIDs(self.hiddenHomeSourceIDsData).contains(self.sourceID)
            },
            set: { onHome in
                var ids = UserSettings.decodeHiddenHomeSourceIDs(self.hiddenHomeSourceIDsData)
                if onHome {
                    ids.remove(self.sourceID)
                } else {
                    ids.insert(self.sourceID)
                }
                self.hiddenHomeSourceIDsData = UserSettings.encodeHiddenHomeSourceIDs(ids)
            }
        )
    }
}
