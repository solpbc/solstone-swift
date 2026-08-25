// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct SolstoneLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        SolstoneLiveActivityWidget()
        ObserverCaptureControlWidget()
        OpenJournalControlWidget()
        ObserverStatusSmallWidget()
        ObserverStatusMediumWidget()
        ObserverStatusAccessoryCircularWidget()
    }
}

struct SolstoneLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ObserverActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: Self.modeGlyph(for: context.state.mode, isStale: context.isStale))
                    .font(.title2)
                    .foregroundStyle(Color.solOrange)
                VStack(alignment: .leading, spacing: 4) {
                    Text("solstone")
                        .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))
                    Text(Self.presentationLabel(for: context))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Self.timeOrStaleLabel(for: context)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if !context.isStale {
                        Text(Self.backlogLabel(for: Self.backlogCount()))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !context.isStale {
                    Button(intent: ObserverCaptureIntent(value: false)) {
                        Label(Self.stopButtonTitle, systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(Color.solOrange, in: Circle())
                    }
                }
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: Self.modeGlyph(for: context.state.mode, isStale: context.isStale))
                        .foregroundStyle(Color.solOrange)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(Self.presentationLabel(for: context))
                        .font(.custom("Comfortaa-Bold", size: 16, relativeTo: .subheadline))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !context.isStale {
                        Button(intent: ObserverCaptureIntent(value: false)) {
                            Label(Self.stopButtonTitle, systemImage: "stop.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(Color.solOrange, in: Circle())
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        Self.timeOrStaleLabel(for: context)
                            .font(.subheadline.monospacedDigit())
                        if !context.isStale {
                            Text(Self.backlogLabel(for: Self.backlogCount()))
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: Self.modeGlyph(for: context.state.mode, isStale: context.isStale))
                    .foregroundStyle(Color.solOrange)
            } compactTrailing: {
                Self.timeOrStaleLabel(for: context)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.isStale ? Self.minimalStaleMarkPlaceholder : Self.minimalLiveMarkPlaceholder)
                    .foregroundStyle(Color.solOrange)
            }
        }
    }

    // tbd: meeting glyph
    private static let meetingGlyphPlaceholder = "questionmark.circle"
    // tbd: voice memo glyph
    private static let voiceMemoGlyphPlaceholder = "waveform"
    // tbd: minimal live mark
    private static let minimalLiveMarkPlaceholder = "questionmark.circle.fill"
    // tbd: minimal stale mark
    private static let minimalStaleMarkPlaceholder = "exclamationmark.triangle.fill"
    private static let stopButtonTitle = "tbd"
    private static let backlogPrefix = "tbd: waiting to sync"
    private static let unavailableLabel = "tbd: unavailable"
    private static let staleLabel = "tbd: activity ended"

    private static func modeGlyph(for rawMode: String, isStale: Bool) -> String {
        guard !isStale else { return Self.minimalStaleMarkPlaceholder }
        return switch ObserverMode(rawValue: rawMode) {
        case .meeting:
            Self.meetingGlyphPlaceholder
        case .voiceMemo:
            Self.voiceMemoGlyphPlaceholder
        case nil:
            Self.minimalLiveMarkPlaceholder
        }
    }

    private static func presentationLabel(
        for context: ActivityViewContext<ObserverActivityAttributes>
    ) -> String {
        context.isStale ? Self.staleLabel : observerModeLabel(for: context.state.mode)
    }

    @ViewBuilder
    private static func timeOrStaleLabel(
        for context: ActivityViewContext<ObserverActivityAttributes>
    ) -> some View {
        if context.isStale {
            Text(Self.staleLabel)
        } else {
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
        }
    }

    private static func backlogCount() -> Int? {
        AppGroupMirror().snapshot()?.backlogCount
    }

    private static func backlogLabel(for backlogCount: Int?) -> String {
        guard let backlogCount else { return Self.unavailableLabel }
        return "\(Self.backlogPrefix) \(backlogCount)"
    }
}
