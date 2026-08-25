// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct ObserverStatusMediumWidget: Widget {
    static let kind = "SolstoneObserverStatusMedium"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ObserverStatusPlaceholderTimelineProvider()) { _ in
            Text("tbd")
        }
        .supportedFamilies([.systemMedium])
    }
}
