// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI
import WidgetKit

struct ObserverStatusAccessoryCircularWidget: Widget {
    static let kind = "SolstoneObserverStatusAccessoryCircular"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: ObserverStatusPlaceholderTimelineProvider()) { _ in
            Text("tbd")
        }
        .supportedFamilies([.accessoryCircular])
    }
}
