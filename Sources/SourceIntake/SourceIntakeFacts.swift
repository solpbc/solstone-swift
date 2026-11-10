// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The two intake facts on a source page. Absent while the record cannot be read.
/// `last taken in` is absent while nothing has been taken in.
struct SourceIntakeFacts: View {
    let source: SourceIntakeSource

    @Environment(SourceIntakeModel.self) private var model: SourceIntakeModel?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        if let model, let facts = model.pageFacts(source: self.source, locale: self.locale, calendar: self.calendar) {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent(SourceIntakePhrases.soFar, value: facts.soFar)
                    .accessibilityIdentifier("intake.\(self.source.rawValue).soFar")
                if let last = facts.lastTakenIn {
                    LabeledContent(SourceIntakePhrases.lastTakenIn, value: last)
                        .accessibilityIdentifier("intake.\(self.source.rawValue).last")
                }
            }
            .accessibilityElement(children: .combine)
            .onAppear { model.reload() }
            .onChange(of: self.scenePhase) { _, phase in
                if phase == .active { model.reload() }
            }
        }
    }
}
