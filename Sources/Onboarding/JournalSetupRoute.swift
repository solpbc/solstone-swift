// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

enum JournalSetupLink {
    static let installURL = URL(string: "https://solstone.app/install#start")!
}

struct JournalSetupRoute<PairControl: View>: View {
    @Environment(\.openURL) private var openURL
    @ViewBuilder var pairControl: () -> PairControl

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("today, your journal lives on a computer you own.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)

            Button {
                self.openURL(JournalSetupLink.installURL)
            } label: {
                Text("set one up")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("journalSetup.setOneUp")

            ShareLink(item: JournalSetupLink.installURL) {
                Text("send yourself the link")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("journalSetup.shareLink")

            self.pairControl()

            Text("what you share stays on this device and isn't processed until you connect a journal.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
    }
}

struct JournalSetupPairLabel: View {
    var body: some View {
        Text("i already have one")
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
    }
}
