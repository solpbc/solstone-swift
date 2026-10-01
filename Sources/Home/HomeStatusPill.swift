// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The status pill's states, per the shell contract.
///
/// The shipped pill rendered `connectionSyncStatus.statusLine` verbatim, which for a
/// transferring connection reads `connected · syncing` — two statuses at once, and
/// the word `connected` doing no work next to `syncing`. Here the pill
/// resolves to exactly one state and leads with the count while there is one.
nonisolated enum HomeStatusPillState: Equatable, Sendable {
    /// A journal, reachable, nothing waiting.
    case caughtUp
    /// Material is moving or queued to move.
    case syncing
    /// Connecting or reconnecting to the journal.
    case connecting
    /// No route to the journal right now.
    case offline
    /// No journal yet.
    case notPaired
    /// No response from the journal within stall window.
    case stalled
    /// Paired and connected, but awaiting owner confirmation of the journal mark.
    case awaitingMarkConfirmation

    nonisolated static func resolve(
        isPaired: Bool,
        status: ConnectionSyncStatus,
        hasBacklog: Bool,
        isStalled: Bool,
        awaitingMarkConfirmation: Bool
    ) -> HomeStatusPillState {
        guard isPaired else { return .notPaired }
        if isStalled { return .stalled }
        switch status {
        case .connecting, .waitingForHome, .reconnecting, .unreachable:
            return .connecting
        case .offline:
            return .offline
        case .connectedIdle, .connectedWaiting, .connectedTransferring:
            if awaitingMarkConfirmation {
                return .awaitingMarkConfirmation
            }
            return hasBacklog ? .syncing : .caughtUp
        }
    }

    func composedText(backlog: WatchAwareBacklog) -> String {
        let count = backlog.knownCount
        if count > 0 {
            return "\(SourceVocabulary.confirmTheMarkAction) · \(count) waiting"
        } else {
            return SourceVocabulary.confirmTheMarkAction
        }
    }

    func accessibilityLabel(backlog: WatchAwareBacklog) -> String {
        self.composedText(backlog: backlog)
    }

    var accessibilityValue: String {
        SourceVocabulary.awaitingMarkConfirmationLine
    }

    func label(hasBacklog: Bool) -> String {
        switch self {
        case .caughtUp: SourceVocabulary.connectedLabel
        case .syncing: SourceVocabulary.syncingLabel
        case .connecting: SourceVocabulary.statusConnectingLabel
        case .offline: SourceVocabulary.statusOfflineLabel
        case .notPaired: SourceVocabulary.dayLocalityNoJournal
        case .stalled: hasBacklog ? SourceVocabulary.stallWaitingLabel : SourceVocabulary.stallNotConnectedLabel
        case .awaitingMarkConfirmation: SourceVocabulary.confirmTheMarkAction
        }
    }

    var label: String { self.label(hasBacklog: false) }

    func shouldPulse(reduceMotion: Bool) -> Bool {
        if reduceMotion { return false }
        if case .syncing = self { return true }
        return false
    }

    var uiTestStateName: String {
        switch self {
        case .caughtUp: "caughtUp"
        case .syncing: "syncing"
        case .connecting: "connecting"
        case .offline: "offline"
        case .notPaired: "notPaired"
        case .stalled: "stalled"
        case .awaitingMarkConfirmation: "awaitingMarkConfirmation"
        }
    }
}

/// The pill's own dot. A live connection pulses; everything else is calm, so motion
/// is never decorative — it means material is moving right now.
struct HomeStatusDot: View {
    let state: HomeStatusPillState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    /// Scales with the label it sits beside; a fixed 8 pt dot beside accessibility-
    /// sized text reads as a stray speck rather than as that text's state.
    @ScaledMetric(relativeTo: .subheadline) private var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(self.tint)
            .frame(width: self.size, height: self.size)
            .opacity(self.shouldPulse && self.pulsing ? 0.35 : 1)
            .animation(
                self.shouldPulse
                    ? .easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                    : .default,
                value: self.pulsing
            )
            .onAppear { if self.shouldPulse { self.pulsing = true } }
            .accessibilityHidden(true)
    }

    private var shouldPulse: Bool {
        self.state.shouldPulse(reduceMotion: self.reduceMotion)
    }

    private var tint: Color {
        switch self.state {
        case .caughtUp: .solSavedGreen
        case .syncing: .solOrange
        case .connecting, .offline, .notPaired, .stalled, .awaitingMarkConfirmation: .secondary
        }
    }
}

/// The trailing toolbar control on home.
///
/// The count leads the words while there is one: it is the only number the shell
/// shows, and the thing an owner checks the pill *for*. `+` is the wrist's
/// "there may be more than this" flag — it is the flag itself, not a second number,
/// which is why no separate glyph rides beside it. (A `questionmark.circle` did, as a
/// declared placeholder; it read as a help affordance and is gone.)
struct HomeStatusPillLabel: View {
    let state: HomeStatusPillState
    let backlog: WatchAwareBacklog

    var body: some View {
        // Centre-aligned, not baseline-aligned: a baseline guide on a circle drifts
        // away from its label as the text scales, and at accessibility sizes the dot
        // ended up detached below the word it belongs to.
        HStack(alignment: .center, spacing: 6) {
            HomeStatusDot(state: self.state)
            if self.state == .awaitingMarkConfirmation {
                Text(self.state.composedText(backlog: self.backlog))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if let count = self.countText {
                    Text(count)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                Text(self.state.label(hasBacklog: self.backlog.knownCount > 0))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(self.countText == nil ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Only shown when there is something waiting. `known(0)` is not a number worth
    /// putting on the pill — `connected` already says it, in words.
    private var countText: String? {
        switch self.backlog {
        case .known(let count):
            count > 0 ? "\(count)" : nil
        case .partiallyUnknown(let known, _):
            "\(known)+"
        }
    }
}

#if DEBUG
struct UITestStateProbe: View {
    let identifier: String

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("--ui-test") {
            Text("")
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .allowsHitTesting(false)
                .accessibilityIdentifier(self.identifier)
        }
    }
}
#endif
