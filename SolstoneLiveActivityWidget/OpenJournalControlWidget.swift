// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct OpenJournalControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: openJournalControlKind) {
            ControlWidgetButton(action: OpenJournalIntent()) {
                Label("your journal", systemImage: "book.closed")
            }
        }
        .displayName("your journal")
        .description("go straight to your journal.")
    }
}
