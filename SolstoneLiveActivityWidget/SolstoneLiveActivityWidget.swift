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
            SolstoneLiveActivityContentView(context: context)
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
        // 🔒 Gives the paired Apple Watch a layout of our own.
        //
        // An iPhone Live Activity ALREADY appears in the watch's Smart Stack automatically, since
        // watchOS 11 — and there is no way to opt out. Without this, the system composites the
        // card from the Dynamic Island's compact leading and trailing views, which for us is a
        // bare `waveform` glyph next to an unlabelled timer. So the owner has always been seeing
        // a watch card we never designed. `.small` is the watchOS family; `.medium` is iOS/macOS.
        .supplementalActivityFamilies([.small])
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
    fileprivate static let liveGlyph = "waveform"
    /// ⛔ Not an error symbol. This renders when capture has ended, which is a normal outcome
    /// and usually one the owner asked for. It was `exclamationmark.triangle.fill`.
    fileprivate static let endedGlyph = "waveform.slash"
    fileprivate static let stopButtonTitle = "stop audio"
    fileprivate static let backlogSuffix = "waiting to sync"
    fileprivate static let unavailableLabel = "can't check what's waiting"
    /// "activity" is Apple's noun for the container, not ours for the thing. The owner turned
    /// audio on; this tells them it is off.
    fileprivate static let staleLabel = "audio ended"

    fileprivate static func modeGlyph(for rawMode: String, isStale: Bool) -> String {
        isStale ? Self.endedGlyph : Self.liveGlyph
    }

    fileprivate static func presentationLabel(
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
    fileprivate static func timerLabel(
        for context: ActivityViewContext<ObserverActivityAttributes>
    ) -> some View {
        if !context.isStale {
            Text(timerInterval: context.state.startedAt...Date.distantFuture, countsDown: false)
        }
    }

    fileprivate static func backlogCount() -> Int? {
        AppGroupMirror().snapshot()?.backlogCount
    }

    fileprivate static func backlogLabel(for backlogCount: Int?) -> String {
        guard let backlogCount else { return Self.unavailableLabel }
        // Count first, matching how the deck already says it (`DayHomeView`).
        return "\(backlogCount) \(Self.backlogSuffix)"
    }
}

/// The Live Activity's presented content, branched by the surface it is rendering on.
///
/// ⚠ **`@Environment(\.activityFamily)` is read HERE, inside the rendered view — not on the
/// `Widget` struct.** Hoisting it up to the widget makes it evaluate `.medium` unconditionally,
/// which silently disables the watch layout while looking correct.
struct SolstoneLiveActivityContentView: View {
    @Environment(\.activityFamily) private var activityFamily

    let context: ActivityViewContext<ObserverActivityAttributes>

    var body: some View {
        switch self.activityFamily {
        case .small:
            self.watchLayout
        case .medium:
            self.lockScreenLayout
        @unknown default:
            self.lockScreenLayout
        }
    }
}

private extension SolstoneLiveActivityContentView {
    /// iPhone Lock Screen and macOS. Unchanged from what shipped before the watch branch existed.
    var lockScreenLayout: some View {
        HStack(spacing: 12) {
            Image(systemName: SolstoneLiveActivityWidget.modeGlyph(
                for: self.context.state.mode,
                isStale: self.context.isStale
            ))
            .font(.title2)
            .foregroundStyle(Color.solOrange)
            VStack(alignment: .leading, spacing: 4) {
                Text("solstone")
                    .font(.custom("Comfortaa-Bold", size: 18, relativeTo: .headline))
                Text(SolstoneLiveActivityWidget.presentationLabel(for: self.context))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SolstoneLiveActivityWidget.timerLabel(for: self.context)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !self.context.isStale {
                    Text(SolstoneLiveActivityWidget.backlogLabel(for: SolstoneLiveActivityWidget.backlogCount()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !self.context.isStale {
                Button(intent: ObserverCaptureIntent(value: false)) {
                    Label(SolstoneLiveActivityWidget.stopButtonTitle, systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.solOrange, in: Circle())
                }
            }
        }
        .padding()
    }

    /// Apple Watch, in the Smart Stack.
    ///
    /// ⛔ **No wordmark and no backlog line.** The Smart Stack already attributes the card to the
    /// app, so repeating "solstone" inside it spends the only two lines this card has on
    /// something the owner can already see. The backlog count is a Lock-Screen-sized detail; at
    /// this width it truncates into nonsense.
    ///
    /// ⛔ **And no stop control yet.** The Lock Screen card has one, and watchOS 11+ does support
    /// intent-backed buttons in the Smart Stack — but whether an `AppIntent` fires from a
    /// *mirrored* Live Activity on the watch is not something we have verified on a device, and a
    /// dead stop button on a listening indicator is worse than no button. The control lands with
    /// the relevance work, where it gets device verification.
    var watchLayout: some View {
        HStack(spacing: 8) {
            Image(systemName: SolstoneLiveActivityWidget.modeGlyph(
                for: self.context.state.mode,
                isStale: self.context.isStale
            ))
            .font(.title3)
            .foregroundStyle(Color.solOrange)
            VStack(alignment: .leading, spacing: 1) {
                Text(SolstoneLiveActivityWidget.presentationLabel(for: self.context))
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                SolstoneLiveActivityWidget.timerLabel(for: self.context)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
