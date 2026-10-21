// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import Foundation
import Observation

/// A calendar source seeded from a launch argument, so UI tests can open the calendar page in
/// each of its states with no calendar access and no real calendars:
/// `--ui-test-calendar=beforeOn|confirm|on|needsAttention|waitingForUpdate`, with `--ui-test`.
@MainActor
@Observable
final class CalendarUITestSource: CalendarSourceControlling {
    static let argumentPrefix = "--ui-test-calendar="

    private(set) var state: CalendarSourceState
    private(set) var calendars: [CalendarSourceCalendar]
    private(set) var pendingSetup: CalendarPendingSetup?

    static func seeded(arguments: [String] = ProcessInfo.processInfo.arguments) -> CalendarUITestSource? {
        guard arguments.contains("--ui-test"),
              let raw = arguments.first(where: { $0.hasPrefix(Self.argumentPrefix) }),
              let mode = CalendarPageMode(rawValue: String(raw.dropFirst(Self.argumentPrefix.count)))
        else {
            return nil
        }
        return CalendarUITestSource(mode: mode)
    }

    init(mode: CalendarPageMode) {
        let calendars = [
            CalendarSourceCalendar(id: "ui-test-work", title: "Work", accountName: "iCloud", followed: true, importStep: nil),
            CalendarSourceCalendar(id: "ui-test-family", title: "Family", accountName: "iCloud", followed: true, importStep: nil),
            CalendarSourceCalendar(id: "ui-test-holidays", title: "US Holidays", accountName: "Subscribed Calendars", followed: mode != .on, importStep: nil),
        ]
        let now = Date()
        let recent = [
            CalendarRecentNote(kind: .added, title: "design review", changedAt: CalendarWire.wholeSeconds(now)),
            CalendarRecentNote(kind: .moved, title: "standup", changedAt: CalendarWire.wholeSeconds(now) - 600),
            CalendarRecentNote(kind: .changed, title: "school play", changedAt: CalendarWire.wholeSeconds(now) - 1_200),
            CalendarRecentNote(kind: .removed, title: "dentist", changedAt: CalendarWire.wholeSeconds(now) - 1_800),
        ]
        var state = CalendarSourceState(
            setupStep: .notSetUp,
            access: .notDetermined,
            everOn: false,
            paused: false,
            lastCompletedCheck: nil,
            followedCount: 0,
            calendarCount: 0,
            recent: [],
            notesWaiting: 0,
            notesNeedingAttention: 0,
            waitingForJournalUpdate: false
        )
        switch mode {
        case .beforeOn:
            self.calendars = []
            self.pendingSetup = nil
        case .confirm:
            state.setupStep = .readyToConfirm(count: 42)
            state.access = .full
            self.calendars = calendars
            self.pendingSetup = CalendarPendingSetup(span: .last30Days, selection: Set(calendars.map(\.id)), count: 42)
        case .on, .needsAttention, .waitingForUpdate:
            state.setupStep = .on
            state.access = mode == .needsAttention ? .denied : .full
            state.everOn = true
            state.lastCompletedCheck = now
            state.recent = recent
            state.notesWaiting = mode == .on ? 3 : 5
            state.waitingForJournalUpdate = mode == .waitingForUpdate
            self.calendars = calendars
            self.pendingSetup = nil
        }
        let shown = mode == .beforeOn ? [] : calendars
        state.followedCount = shown.filter(\.followed).count
        state.calendarCount = shown.count
        self.state = state
    }

    func refreshAccess() {}

    func requestFullAccess() async -> CalendarAccess {
        self.state.access
    }

    func chooseSpan(_ span: CalendarSpanChoice) async {}

    func setUp(span: CalendarSpanChoice, calendarIDs: Set<String>?) async {}

    func confirm() async {}

    func pause() {
        self.state.paused = true
    }

    func resume() async {
        self.state.paused = false
    }

    func setCalendar(_ identifier: String, followed: Bool) async {}

    func cancelCalendar(_ identifier: String) async {}

    func confirmCalendar(_ identifier: String) async {}
}
#endif
