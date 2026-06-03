// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ActivityKit
import SwiftUI
import WidgetKit

struct LocationLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LocationActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.title2)
                    .foregroundStyle(Color.solOrange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("solstone")
                        .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))
                    Text(LocationVocabulary.liveActivityText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "solstone://location/pause")!) {
                    Image(systemName: "pause.fill")
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.solOrangeAccessible, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Pause")
                .accessibilityHint("Pauses location updates to your journal.")
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "location.fill")
                        .foregroundStyle(Color.solOrange)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("solstone")
                            .font(.custom("Comfortaa-Bold", size: 16, relativeTo: .subheadline))
                        Text(LocationVocabulary.liveActivityText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Link(destination: URL(string: "solstone://location/pause")!) {
                        Image(systemName: "pause.fill")
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(Color.solOrangeAccessible, in: Circle())
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Pause")
                    .accessibilityHint("Pauses location updates to your journal.")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.tierLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: "location.fill")
                    .foregroundStyle(Color.solOrange)
            } compactTrailing: {
                Circle()
                    .fill(Color.solOrange)
                    .frame(width: 8, height: 8)
            } minimal: {
                Image(systemName: "location.fill")
                    .foregroundStyle(Color.solOrange)
            }
        }
    }
}
