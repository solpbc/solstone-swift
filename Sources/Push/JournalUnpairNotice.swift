// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class JournalUnpairNoticeStore {
    private enum DefaultsKey {
        static let notTold = "journal.unpair.notTold"
    }

    private(set) var isSet: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isSet = defaults.bool(forKey: DefaultsKey.notTold)
    }

    func markNotTold() {
        self.isSet = true
        self.defaults.set(true, forKey: DefaultsKey.notTold)
    }

    func dismiss() {
        self.isSet = false
        self.defaults.removeObject(forKey: DefaultsKey.notTold)
    }
}

struct JournalUnpairNoticeBanner: View {
    @Environment(JournalUnpairNoticeStore.self) private var noticeStore

    var body: some View {
        if self.noticeStore.isSet {
            VStack(alignment: .leading, spacing: 12) {
                Text("your journal didn't confirm the unpair, so it may still list this phone. to stop notifications from your journal, remove this phone under devices in your journal.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                Button("dismiss") {
                    self.noticeStore.dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("journal.unpair.notTold.dismiss")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("journal.unpair.notTold")
        }
    }
}
