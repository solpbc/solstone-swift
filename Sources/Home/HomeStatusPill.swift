// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SwiftUI

/// The status pill's five states, per the shell contract.
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

    nonisolated static func resolve(
        isPaired: Bool,
        status: ConnectionSyncStatus,
        hasBacklog: Bool
    ) -> HomeStatusPillState {
        guard isPaired else { return .notPaired }
        switch status {
        case .connectedIdle, .connectedWaiting, .connectedTransferring:
            return hasBacklog ? .syncing : .caughtUp
        // .unreachable only fires mid-retry-loop (the sub-second gap as a countdown
        // expires and a fresh attempt begins) or for the non-retryable .revoked
        // error, which already surfaces its own RePairBanner — never a state where
        // nothing is happening, so it reads as "connecting", not "offline".
        case .connecting, .waitingForHome, .reconnecting, .unreachable:
            return .connecting
        case .offline:
            return .offline
        }
    }

    var label: String {
        switch self {
        case .caughtUp: SourceVocabulary.connectedLabel
        case .syncing: SourceVocabulary.syncingLabel
        case .connecting: SourceVocabulary.statusConnectingLabel
        case .offline: SourceVocabulary.statusOfflineLabel
        case .notPaired: SourceVocabulary.dayLocalityNoJournal
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
        if self.reduceMotion { return false }
        if case .syncing = self.state { return true }
        return false
    }

    private var tint: Color {
        switch self.state {
        case .caughtUp: .solSavedGreen
        case .syncing: .solOrange
        case .connecting, .offline, .notPaired: .secondary
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
            if let count = self.countText {
                Text(count)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Text(self.state.label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(self.countText == nil ? .primary : .secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
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
