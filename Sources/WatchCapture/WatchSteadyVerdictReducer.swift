// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum WatchSteadyVerdictKind: Equatable, Sendable {
    case stuck(WatchPipelineStuck)
    case stoppedItself(WatchNoticeCopy)
    case observing
    case receiving
    case watchWaiting
    case phoneSyncing
    case caughtUp
    case quiet
}

nonisolated struct WatchSteadyVerdict: Equatable, Sendable {
    let kind: WatchSteadyVerdictKind
    let state: SourceState
    let headline: String
    let sentence: String
    let nextStep: String?
    let presenceLine: String?
    let todayLine: String?
    let detailsSummary: String
    let accessibilityLabel: String
}

extension WatchWaitingBreakdown {
    nonisolated var freshWatchWaitingCount: Int {
        guard case let .reported(count, .fresh) = self.watch else {
            return 0
        }
        return max(0, count)
    }
}

nonisolated enum WatchSteadyVerdictReducer {
    static func reduce(
        _ input: WatchPipelineInput,
        waiting: WatchWaitingBreakdown,
        facts: WatchSourceFacts.Snapshot,
        calendar: Calendar
    ) -> WatchSteadyVerdict {
        let recordingStatus = watchRecordingStatus(
            context: input.watchStatus,
            now: input.now,
            lastReceivedAt: input.lastReceivedAt
        )
        let detailsSummary = SourceVocabulary.watchSteadyDetailsSummary(
            watchWaiting: waiting.freshWatchWaitingCount,
            phoneWaiting: max(0, waiting.phone.count)
        )
        let presenceLine = self.presenceLine(input: input, facts: facts)
        let todayLine = self.todayLine(input: input, calendar: calendar)

        if case .stoppedItself(let copy) = recordingStatus {
            return self.verdict(
                kind: .stoppedItself(copy),
                headline: copy.title,
                sentence: copy.body,
                nextStep: nil,
                presenceLine: presenceLine,
                todayLine: todayLine,
                detailsSummary: detailsSummary
            )
        }

        let stuck = WatchPipelineReducer.stuckState(input)
        if stuck != .none, let reason = stuck.reason {
            return self.verdict(
                kind: .stuck(stuck),
                headline: SourceVocabulary.watchStuckNoticeTitle,
                sentence: reason,
                nextStep: stuck.nextStep,
                presenceLine: presenceLine,
                todayLine: todayLine,
                detailsSummary: detailsSummary
            )
        }

        switch recordingStatus {
        case .stoppedItself:
            preconditionFailure("stopped-itself status should be handled before stuck or waiting")
        case .observing:
            return self.verdict(
                kind: .observing,
                headline: SourceVocabulary.watchSteadyObservingHeadline,
                sentence: SourceVocabulary.watchObservingSentence(
                    elapsedMinutes: self.elapsedMinutes(startedAt: input.watchStatus?.startedAt, now: input.now)
                ),
                nextStep: nil,
                presenceLine: presenceLine,
                todayLine: todayLine,
                detailsSummary: detailsSummary
            )
        case .noContextButReceiving:
            return self.verdict(
                kind: .receiving,
                headline: SourceVocabulary.watchSteadyReceivingHeadline,
                sentence: SourceVocabulary.watchReceivingNowSubtext,
                nextStep: nil,
                presenceLine: presenceLine,
                todayLine: todayLine,
                detailsSummary: detailsSummary
            )
        case .noContext, .idle:
            break
        }

        if case .some(.watch) = waiting.leading,
           waiting.freshWatchWaitingCount > 0 {
            return self.verdict(
                kind: .watchWaiting,
                headline: SourceVocabulary.watchSteadyWatchWaitingHeadline,
                sentence: SourceVocabulary.watchSteadyWatchWaitingSentence(waiting.freshWatchWaitingCount),
                nextStep: nil,
                presenceLine: presenceLine,
                todayLine: todayLine,
                detailsSummary: detailsSummary
            )
        }

        if case let .some(.phone(count)) = waiting.leading,
           count > 0 {
            return self.verdict(
                kind: .phoneSyncing,
                headline: SourceVocabulary.watchSteadyPhoneSyncingHeadline,
                sentence: SourceVocabulary.watchSteadyPhoneSyncingSentence(count),
                nextStep: nil,
                presenceLine: presenceLine,
                todayLine: todayLine,
                detailsSummary: detailsSummary
            )
        }

        if case .available = input.phoneLedgerSnapshot,
           waiting.freshWatchWaitingCount == 0,
           max(0, waiting.phone.count) == 0,
           facts.hasCheckedIn || input.lifetimeReceived > 0 || input.lifetimeHanded > 0 {
            return self.verdict(
                kind: .caughtUp,
                headline: SourceVocabulary.syncedHeadline,
                sentence: SourceVocabulary.watchSteadyCaughtUpSentence,
                nextStep: nil,
                presenceLine: presenceLine,
                todayLine: todayLine,
                detailsSummary: detailsSummary
            )
        }

        return self.verdict(
            kind: .quiet,
            headline: SourceVocabulary.watchSteadyQuietHeadline,
            sentence: SourceVocabulary.watchIdleNowSubtext,
            nextStep: nil,
            presenceLine: presenceLine,
            todayLine: todayLine,
            detailsSummary: detailsSummary
        )
    }
}

private extension WatchSteadyVerdictReducer {
    nonisolated static func verdict(
        kind: WatchSteadyVerdictKind,
        headline: String,
        sentence: String,
        nextStep: String?,
        presenceLine: String?,
        todayLine: String?,
        detailsSummary: String
    ) -> WatchSteadyVerdict {
        WatchSteadyVerdict(
            kind: kind,
            state: self.state(for: kind),
            headline: headline,
            sentence: sentence,
            nextStep: nextStep,
            presenceLine: presenceLine,
            todayLine: todayLine,
            detailsSummary: detailsSummary,
            accessibilityLabel: self.accessibilityLabel(
                headline: headline,
                sentence: sentence,
                nextStep: nextStep,
                presenceLine: presenceLine,
                todayLine: todayLine
            )
        )
    }

    nonisolated static func state(for kind: WatchSteadyVerdictKind) -> SourceState {
        switch kind {
        case .stuck, .stoppedItself:
            .needsAttention
        case .observing, .receiving:
            .active
        case .watchWaiting, .phoneSyncing, .caughtUp, .quiet:
            .off
        }
    }

    nonisolated static func accessibilityLabel(
        headline: String,
        sentence: String,
        nextStep: String?,
        presenceLine: String?,
        todayLine: String?
    ) -> String {
        [headline, sentence, nextStep, presenceLine, todayLine]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    nonisolated static func elapsedMinutes(startedAt: Date?, now: Date) -> Int? {
        guard let startedAt else {
            return nil
        }
        let minutes = Int(max(0, now.timeIntervalSince(startedAt)) / 60)
        return minutes >= 1 ? minutes : nil
    }

    nonisolated static func presenceLine(
        input: WatchPipelineInput,
        facts: WatchSourceFacts.Snapshot
    ) -> String? {
        if input.isReachable {
            return SourceVocabulary.watchPresenceConnectedNow
        }

        if let lastHeardAt = self.mostRecent(input.lastReceivedAt, input.watchStatus?.asOf) {
            let age = max(0, input.now.timeIntervalSince(lastHeardAt))
            return SourceVocabulary.watchPresenceLastHeard(
                relative: WatchPipelineReducer.relativeText(secondsAgo: age)
            )
        }

        if facts.hasCheckedIn {
            return nil
        }
        return SourceVocabulary.watchPresenceNeverHeard
    }

    nonisolated static func mostRecent(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            max(lhs, rhs)
        case let (.some(lhs), .none):
            lhs
        case let (.none, .some(rhs)):
            rhs
        case (.none, .none):
            nil
        }
    }

    nonisolated static func todayLine(input: WatchPipelineInput, calendar: Calendar) -> String? {
        guard case let .available(snapshot) = input.phoneLedgerSnapshot,
              let interval = calendar.dateInterval(of: .day, for: input.now)
        else {
            return nil
        }
        let handedToday = snapshot.entriesByID.values.filter { entry in
            guard let handedAt = entry.handedAt else {
                return false
            }
            return interval.contains(handedAt)
        }.count
        guard handedToday > 0 else {
            return nil
        }
        return SourceVocabulary.watchTodayHandedLine(handedToday)
    }
}

private extension WatchPipelineStuck {
    nonisolated var nextStep: String? {
        switch self {
        case .none:
            nil
        case .relay:
            SourceVocabulary.watchPipelineRelayStuckNextStep
        case .handoff:
            SourceVocabulary.watchPipelineHandoffStuckNextStep
        case .orphan:
            SourceVocabulary.watchPipelineOrphanStuckNextStep
        }
    }
}
