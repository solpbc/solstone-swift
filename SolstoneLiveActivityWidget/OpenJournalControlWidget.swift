// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct OpenJournalControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: openJournalControlKind) {
            ControlWidgetButton(action: OpenJournalIntent()) {
                Label(AppStrings.ios_liveactivity_yourjournalsection(), systemImage: "book.closed")
            }
        }
        .displayName(AppStrings.ios_liveactivity_yourjournalsection_resource())
        .description(AppStrings.ios_liveactivity_body2_resource())
    }
}
