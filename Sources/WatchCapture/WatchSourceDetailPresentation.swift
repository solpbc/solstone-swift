// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchSourceSyncSummary: Equatable, Sendable {
    let received: Int
    let waiting: Int
    let handedToJournal: Int
    let lastSyncAt: Date?
}

nonisolated struct WatchStuckNotice: Equatable, Sendable {
    let title: String
    let reason: String
    let nextStep: String
}

nonisolated enum WatchDetailContentMode: Equatable, Sendable {
    case setup(WatchSetupCard)
    case celebrate
    case steady
    case notice(String)
}

nonisolated enum WatchSetupCardLine: Equatable, Sendable {
    case value(String)
    case body(String)
}

nonisolated struct WatchSetupCard: Equatable, Sendable {
    let header: String
    let line: WatchSetupCardLine
    let steps: [WatchSetupStep]
}

nonisolated enum WatchSetupStepID: String, Equatable, Sendable {
    case install
    case open
    case firstMoment
}

nonisolated enum WatchSetupStepState: Equatable, Sendable {
    case pending
    case active
    case done
}

nonisolated struct WatchSetupDisclosure: Equatable, Sendable {
    let summary: String
    let body: String
}

nonisolated struct WatchSetupStep: Identifiable, Equatable, Sendable {
    let id: WatchSetupStepID
    let title: String
    let subline: String?
    let state: WatchSetupStepState
    let buttonTitle: String?
    let disclosure: WatchSetupDisclosure?
}

nonisolated struct WatchSetupDisclosureLatch: Equatable, Sendable {
    let isExpanded: Bool
    let lastHandledForegroundReturnGeneration: Int
}

nonisolated struct WatchSourceDetailRow: Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    let detail: String?

    init(label: String, value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    var id: String { self.label }
}

nonisolated struct WatchPipelineRowGroup: Equatable, Sendable {
    let label: String
    let rows: [WatchSourceDetailRow]
}

nonisolated enum WatchSourceDetailPresentation {
    static func contentMode(
        lane: PhoneWatchSourceLane,
        installed: Bool,
        checkedIn: Bool,
        firstSegment: Bool,
        celebrationShown: Bool
    ) -> WatchDetailContentMode {
        switch lane {
        case .unsupported:
            // Unreachable from SourcesView because unsupported watch rows are not rendered.
            return .steady
        case .checking:
            return .notice(SourceVocabulary.watchCheckingLine)
        case .activationFailed:
            return .notice(SourceVocabulary.watchActivationFailedSubtext)
        case .noWatchPaired:
            return .setup(self.noWatchSetupCard())
        case .readyToSetUp(.installApp), .installedNeverOpened:
            return .setup(self.setupCard(
                lane: lane,
                installed: installed,
                checkedIn: checkedIn,
                firstSegment: firstSegment
            ))
        case .installedActive:
            if firstSegment {
                return celebrationShown ? .steady : .celebrate
            }
            return .setup(self.setupCard(
                lane: lane,
                installed: installed,
                checkedIn: checkedIn,
                firstSegment: firstSegment
            ))
        }
    }

    static func setupCard(
        lane: PhoneWatchSourceLane,
        installed: Bool,
        checkedIn: Bool,
        firstSegment: Bool
    ) -> WatchSetupCard {
        if lane == .noWatchPaired {
            return self.noWatchSetupCard()
        }
        return WatchSetupCard(
            header: SourceVocabulary.watchSetupHeader,
            line: .value(SourceVocabulary.watchSetupValueLine),
            steps: self.stepStates(
                lane: lane,
                installed: installed,
                checkedIn: checkedIn,
                firstSegment: firstSegment
            )
        )
    }

    static func noWatchSetupCard() -> WatchSetupCard {
        WatchSetupCard(
            header: SourceVocabulary.watchSetupHeader,
            line: .body(SourceVocabulary.watchSetupNoWatchBody),
            steps: []
        )
    }

    static func stepStates(
        lane: PhoneWatchSourceLane,
        installed: Bool,
        checkedIn: Bool,
        firstSegment: Bool
    ) -> [WatchSetupStep] {
        guard lane != .noWatchPaired else {
            return []
        }

        let done = [
            installed || firstSegment,
            checkedIn || firstSegment,
            firstSegment,
        ]
        let activeIndex = done.firstIndex(of: false)

        return [
            WatchSetupStep(
                id: .install,
                title: SourceVocabulary.watchSetupInstallTitle,
                subline: SourceVocabulary.watchSetupInstallSubline,
                state: self.stepState(index: 0, done: done, activeIndex: activeIndex),
                buttonTitle: SourceVocabulary.watchSetupInstallButton,
                disclosure: WatchSetupDisclosure(
                    summary: SourceVocabulary.watchSetupInstallDisclosureSummary,
                    body: SourceVocabulary.watchSetupInstallDisclosureBody
                )
            ),
            WatchSetupStep(
                id: .open,
                title: SourceVocabulary.watchSetupOpenTitle,
                subline: SourceVocabulary.watchSetupOpenSubline,
                state: self.stepState(index: 1, done: done, activeIndex: activeIndex),
                buttonTitle: nil,
                disclosure: nil
            ),
            WatchSetupStep(
                id: .firstMoment,
                title: SourceVocabulary.watchSetupFirstMomentTitle,
                subline: nil,
                state: self.stepState(index: 2, done: done, activeIndex: activeIndex),
                buttonTitle: nil,
                disclosure: nil
            ),
        ]
    }

    static func disclosureLatch(
        current: WatchSetupDisclosureLatch,
        installTapped: Bool,
        installed: Bool,
        firstSegment: Bool,
        foregroundReturnGeneration: Int
    ) -> WatchSetupDisclosureLatch {
        let hasUnhandledReturn = foregroundReturnGeneration > current.lastHandledForegroundReturnGeneration
        if installed || firstSegment {
            return WatchSetupDisclosureLatch(
                isExpanded: false,
                lastHandledForegroundReturnGeneration: hasUnhandledReturn
                    ? foregroundReturnGeneration
                    : current.lastHandledForegroundReturnGeneration
            )
        }
        guard installTapped, hasUnhandledReturn else {
            return current
        }
        return WatchSetupDisclosureLatch(
            isExpanded: true,
            lastHandledForegroundReturnGeneration: foregroundReturnGeneration
        )
    }

    static func setupStepAccessibilityLabel(
        step: WatchSetupStep,
        index: Int,
        total: Int
    ) -> String {
        "step \(index + 1) of \(total), \(step.title), \(self.accessibilityText(for: step.state))"
    }

    static func pipelineGroups(_ rows: [WatchSourceDetailRow]) -> [WatchPipelineRowGroup] {
        [
            WatchPipelineRowGroup(label: SourceVocabulary.watchPipelineReportedGroupLabel, rows: Array(rows.prefix(2))),
            WatchPipelineRowGroup(label: SourceVocabulary.watchPipelineKnownGroupLabel, rows: Array(rows.dropFirst(2)))
        ]
    }

    static func stuckNotice(for stuck: WatchPipelineStuck) -> WatchStuckNotice? {
        guard let reason = stuck.reason else {
            return nil
        }
        let nextStep: String
        switch stuck {
        case .none:
            return nil
        case .relay:
            nextStep = SourceVocabulary.watchPipelineRelayStuckNextStep
        case .handoff:
            nextStep = SourceVocabulary.watchPipelineHandoffStuckNextStep
        case .orphan:
            nextStep = SourceVocabulary.watchPipelineOrphanStuckNextStep
        }
        return WatchStuckNotice(title: SourceVocabulary.watchStuckNoticeTitle, reason: reason, nextStep: nextStep)
    }

    private static func stepState(
        index: Int,
        done: [Bool],
        activeIndex: Int?
    ) -> WatchSetupStepState {
        if done[index] {
            return .done
        }
        return activeIndex == index ? .active : .pending
    }

    private static func accessibilityText(for state: WatchSetupStepState) -> String {
        switch state {
        case .pending:
            SourceVocabulary.watchSetupStepPending
        case .active:
            SourceVocabulary.watchSetupStepActive
        case .done:
            SourceVocabulary.watchSetupStepComplete
        }
    }
}
