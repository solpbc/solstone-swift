// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SolstoneLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ObserverActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "ear")
                    .font(.title2)
                    .foregroundStyle(Color.solOrange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("solstone")
                        .font(.custom("Comfortaa-Bold", size: 18))
                    Text(observerModeLabel(for: context.state.mode))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "solstone://observer/stop")!) {
                    Image(systemName: "stop.fill")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.solOrange, in: Circle())
                }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "ear")
                        .foregroundStyle(Color.solOrange)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(observerModeLabel(for: context.state.mode))
                        .font(.custom("Comfortaa-Bold", size: 16))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: URL(string: "solstone://observer/stop")!) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.solOrange, in: Circle())
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(Self.elapsedString(for: context.state.elapsed))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "ear")
                    .foregroundStyle(Color.solOrange)
            } compactTrailing: {
                Text(Self.elapsedString(for: context.state.elapsed))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "ear")
                    .foregroundStyle(Color.solOrange)
            }
        }
    }

    private static func elapsedString(for elapsed: TimeInterval) -> String {
        let totalSeconds = Int(elapsed)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
