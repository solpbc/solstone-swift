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
                    Self.timerLabel(for: context)
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
                        Self.timerLabel(for: context)
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
                Self.timerLabel(for: context)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: context.isStale ? Self.endedGlyph : Self.liveGlyph)
                    .foregroundStyle(Color.solOrange)
            }
        }
    }

    /// 🔒 **One glyph for capture, whatever the mode.**
    ///
    /// This used to branch on `ObserverMode`, returning a distinct symbol for a meeting and a
    /// voice memo. That defeated the decision `ObserverLiveActivitySubtitleTests` protects:
    /// the subtitle deliberately collapses to one neutral word so the Lock Screen never
    /// advertises *what kind* of session is being captured. The test guarded the label and
    /// nothing guarded the glyph, so the icon leaked exactly what the words withhold.
    ///
    /// `waveform` is the app's own glyph for this source (`SourceKind.glyph`).
    private static let liveGlyph = "waveform"
    /// ⛔ Not an error symbol. This renders when capture has ended, which is a normal outcome
    /// and usually one the owner asked for. It was `exclamationmark.triangle.fill`.
    private static let endedGlyph = "waveform.slash"
    private static let stopButtonTitle = "stop audio"
    private static let backlogSuffix = "waiting to sync"
    private static let unavailableLabel = "can't check what's waiting"
    /// "activity" is Apple's noun for the container, not ours for the thing. The owner turned
    /// audio on; this tells them it is off.
    private static let staleLabel = "audio ended"

    private static func modeGlyph(for rawMode: String, isStale: Bool) -> String {
        isStale ? Self.endedGlyph : Self.liveGlyph
    }

    private static func presentationLabel(
        for context: ActivityViewContext<ObserverActivityAttributes>
    ) -> String {
        context.isStale ? Self.staleLabel : observerModeLabel(for: context.state.mode)
    }

    /// The running timer, and **nothing at all** once the session is over.
    ///
    /// ⚠ This used to render `staleLabel` in the ended state — but so does
    /// `presentationLabel(for:)`, and the Lock Screen layout stacks them, so the owner saw
    /// "audio ended" printed twice. Neither function knew the other was doing it, and the
    /// duplication was invisible in the live state where the two render different things.
    /// The ended message belongs to `presentationLabel` alone.
    @ViewBuilder
    private static func timerLabel(
        for context: ActivityViewContext<ObserverActivityAttributes>
    ) -> some View {
        if !context.isStale {
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
        }
    }

    private static func backlogCount() -> Int? {
        AppGroupMirror().snapshot()?.backlogCount
    }

    private static func backlogLabel(for backlogCount: Int?) -> String {
        guard let backlogCount else { return Self.unavailableLabel }
        // Count first, matching how the deck already says it (`DayHomeView`).
        return "\(backlogCount) \(Self.backlogSuffix)"
    }
}
