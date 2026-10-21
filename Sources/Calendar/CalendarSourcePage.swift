// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation

/// What the calendar's screens drive. The engine is the one source of truth for what will be
/// sent; the screens only ask it and show what it says.
@MainActor
protocol CalendarSourceControlling: AnyObject {
    var state: CalendarSourceState { get }
    var calendars: [CalendarSourceCalendar] { get }
    var pendingSetup: CalendarPendingSetup? { get }
    func refreshAccess()
    func requestFullAccess() async -> CalendarAccess
    func chooseSpan(_ span: CalendarSpanChoice)
    func setUp(span: CalendarSpanChoice, calendarIDs: Set<String>?) async
    func confirm() async
    func pause()
    func resume() async
    func setCalendar(_ identifier: String, followed: Bool) async
    func cancelCalendar(_ identifier: String) async
    func confirmCalendar(_ identifier: String) async
}

extension CalendarSourceEngine: CalendarSourceControlling {}

/// Puts the calendar source in the SwiftUI environment.
@MainActor
@Observable
final class CalendarSourceHandle {
    let source: any CalendarSourceControlling

    init(source: any CalendarSourceControlling) {
        self.source = source
    }
}

// MARK: the source model

/// The calendar source as the deck, `add more` and the status view show it.
@MainActor
func makeCalendarSource(_ source: any CalendarSourceControlling, isJournalPaired: Bool) -> Source {
    calendarSourceModel(state: source.state, isJournalPaired: isJournalPaired)
}

nonisolated func calendarSourceModel(state: CalendarSourceState, isJournalPaired: Bool) -> Source {
    let presentation = CalendarSourceStatus(state: state)
    return Source(
        id: "calendar",
        displayName: CalendarVocabulary.label,
        kind: .calendar,
        state: presentation.sourceState,
        isJournalPaired: isJournalPaired,
        activeSubtext: CalendarVocabulary.activeSubtext(isJournalPaired: isJournalPaired),
        subtextOverride: presentation.showsReadyToSetUpSubline ? CalendarVocabulary.readyToSetUpSubline : nil,
        attention: presentation.attention.map { SourceAttention(message: $0.text) },
        pendingStatus: .nonePending
    )
}

/// Why the calendar source needs attention once it has been on.
nonisolated enum CalendarAttentionReason: Equatable, Sendable {
    case accessRevoked
    case writeOnly
    case restricted

    var text: String {
        switch self {
        case .accessRevoked: CalendarVocabulary.accessRevoked
        case .writeOnly: CalendarVocabulary.writeOnly
        case .restricted: CalendarVocabulary.restricted
        }
    }

    /// Settings can lift everything but a device restriction.
    var opensSettings: Bool {
        self != .restricted
    }
}

/// The source's state word, sub-line and attention, from the engine's state.
nonisolated struct CalendarSourceStatus: Equatable, Sendable {
    let sourceState: SourceState
    let attention: CalendarAttentionReason?
    /// `ready to set up` between the grant and the confirm, and only then.
    let showsReadyToSetUpSubline: Bool

    init(state: CalendarSourceState) {
        guard state.everOn else {
            // Needs attention applies only after the source has been confirmed on.
            self.sourceState = .readyToSetUp
            self.attention = nil
            self.showsReadyToSetUpSubline = state.access == .full
            return
        }
        self.showsReadyToSetUpSubline = false
        switch state.access {
        case .full:
            self.sourceState = state.paused ? .paused : .active
            self.attention = nil
        case .writeOnly:
            self.sourceState = .needsAttention
            self.attention = .writeOnly
        case .restricted:
            self.sourceState = .needsAttention
            self.attention = .restricted
        case .denied, .notDetermined:
            self.sourceState = .needsAttention
            self.attention = .accessRevoked
        }
    }
}

/// The deck tile's switch. It never asks for access or starts setup: before the source has
/// been confirmed on, and in needs attention, the tile has no switch and opens the page.
nonisolated func calendarTileControl(_ status: CalendarSourceStatus) -> HomeSourceTileControl {
    switch status.sourceState {
    case .active, .paused:
        .toggle
    case .off, .enrolling, .readyToSetUp, .checking, .needsAttention:
        .none
    }
}

/// The tile's switch pauses and resumes, and does nothing else.
@MainActor
func setCalendarTile(_ source: any CalendarSourceControlling, on: Bool) async {
    if on {
        await source.resume()
    } else {
        source.pause()
    }
}

// MARK: the page

/// What the confirm button says.
nonisolated enum CalendarConfirmLabel: Equatable, Sendable {
    case checking
    case count(Int)
    case startFromToday
    case failed
}

/// What the page offers before the source has been on, under the span choice.
nonisolated enum CalendarEnrolAction: Equatable, Sendable {
    /// Only this asks iOS for access.
    case turnOn
    /// iOS will not ask again: access was declined, or set to adding events only.
    case openSettings
    /// A device restriction: nothing on the page can lift it.
    case restricted
    /// Access is full: the calendars and the confirm button.
    case chooseCalendars(CalendarConfirmLabel)
}

/// What the page's delivery line says.
nonisolated enum CalendarDeliveryLine: Equatable, Sendable {
    case quiet
    case sending(Int)
    case needsAttention(Int)
    /// Replaces the delivery line while the journal does not take calendar notes yet.
    case waitingForJournalUpdate
}

/// Which of its five states the page is in.
nonisolated enum CalendarPageMode: String, Equatable, Sendable {
    case beforeOn
    case confirm
    case on
    case needsAttention
    case waitingForUpdate
}

/// The calendar page's state, worked out from the engine and the page model.
@MainActor
@Observable
final class CalendarPageModel {
    let source: any CalendarSourceControlling
    /// The span shown as chosen. Saved in the engine as soon as it is picked.
    private(set) var span: CalendarSpanChoice
    private(set) var countFailed = false
    private var latestCount = 0
    private var finishedCount = 0
    /// A calendar whose switch-on is being counted.
    private(set) var switchingOn: String?
    private var entered = false

    init(source: any CalendarSourceControlling) {
        self.source = source
        self.span = source.pendingSetup?.span ?? CalendarVocabulary.spanOrder[0]
    }

    var state: CalendarSourceState {
        self.source.state
    }

    var status: CalendarSourceStatus {
        CalendarSourceStatus(state: self.source.state)
    }

    var isCounting: Bool {
        self.latestCount != self.finishedCount
    }

    /// The engine holds a frozen count for the span and calendars shown. The shown count, the
    /// frozen set and the visible switches always describe the same selection.
    private var frozenCount: Int? {
        guard let pending = self.source.pendingSetup, pending.span == self.span,
              pending.selection == Set(self.source.calendars.filter(\.followed).map(\.id))
        else {
            return nil
        }
        return pending.count
    }

    var confirmLabel: CalendarConfirmLabel {
        if self.isCounting { return .checking }
        if self.countFailed { return .failed }
        guard let count = self.frozenCount else { return .checking }
        return count == 0 ? .startFromToday : .count(count)
    }

    /// Confirm is offered only for the count shown, never while counting.
    var canConfirm: Bool {
        switch self.confirmLabel {
        case .count, .startFromToday: true
        case .checking, .failed: false
        }
    }

    var enrolAction: CalendarEnrolAction {
        switch self.source.state.access {
        case .notDetermined:
            .turnOn
        case .denied, .writeOnly:
            .openSettings
        case .restricted:
            .restricted
        case .full:
            .chooseCalendars(self.confirmLabel)
        }
    }

    var mode: CalendarPageMode {
        let state = self.source.state
        guard state.everOn else {
            if case .chooseCalendars = self.enrolAction { return .confirm }
            return .beforeOn
        }
        if self.status.attention != nil { return .needsAttention }
        if state.waitingForJournalUpdate { return .waitingForUpdate }
        return .on
    }

    var deliveryLine: CalendarDeliveryLine {
        let state = self.source.state
        if state.waitingForJournalUpdate { return .waitingForJournalUpdate }
        if state.notesNeedingAttention > 0 { return .needsAttention(state.notesNeedingAttention) }
        if state.notesWaiting > 0 { return .sending(state.notesWaiting) }
        return .quiet
    }

    /// Calendars followed, out of the total. A calendar whose switch-on is not yet confirmed is
    /// not followed yet.
    var followedFact: (followed: Int, total: Int) {
        let calendars = self.source.calendars
        let followed = calendars.filter { calendar in
            guard calendar.followed else { return false }
            switch calendar.importStep {
            case .counting, .readyToConfirm: return false
            case .importing, nil: return true
            }
        }
        return (followed.count, calendars.count)
    }

    /// While one calendar's switch-on is pending, the other switches wait.
    var pendingSwitchOn: String? {
        if let switchingOn { return switchingOn }
        return self.source.calendars.first { calendar in
            switch calendar.importStep {
            case .counting, .readyToConfirm: true
            case .importing, nil: false
            }
        }?.id
    }

    // MARK: actions

    /// Opening the page: with access full and no frozen count for the stored span, counts
    /// exactly once. A stored count is shown with no call.
    func enter() async {
        self.source.refreshAccess()
        guard !self.entered else { return }
        self.entered = true
        guard !self.source.state.everOn, self.source.state.access == .full, self.frozenCount == nil else { return }
        await self.count()
    }

    /// Access may have changed in iOS Settings while the page was away.
    func returnedToForeground() async {
        let before = self.source.state.access
        self.source.refreshAccess()
        guard !self.source.state.everOn, before != .full, self.source.state.access == .full, self.frozenCount == nil else { return }
        await self.count()
    }

    func pick(_ span: CalendarSpanChoice) async {
        guard span != self.span else { return }
        self.span = span
        self.source.chooseSpan(span)
        if self.source.state.access == .full {
            await self.count()
        }
    }

    /// The only control that asks iOS for access.
    func turnOn() async {
        self.source.chooseSpan(self.span)
        let access = await self.source.requestFullAccess()
        if access == .full {
            await self.count()
        }
    }

    func count() async {
        await self.counting { await self.source.setUp(span: self.span, calendarIDs: nil) }
    }

    /// Before confirm, a calendar switch re-counts in the engine.
    func setUpCalendar(_ identifier: String, on: Bool) async {
        await self.counting { await self.source.setCalendar(identifier, followed: on) }
    }

    func confirm() async {
        guard self.canConfirm else { return }
        await self.source.confirm()
    }

    /// After setup, switching a calendar on counts its setup span; off stops its notes.
    func setCalendar(_ identifier: String, on: Bool) async {
        guard self.pendingSwitchOn == nil || self.pendingSwitchOn == identifier else { return }
        if on {
            self.switchingOn = identifier
            await self.source.setCalendar(identifier, followed: true)
            self.switchingOn = nil
        } else {
            await self.source.setCalendar(identifier, followed: false)
        }
    }

    func confirmCalendar(_ identifier: String) async {
        await self.source.confirmCalendar(identifier)
    }

    func notNow(_ identifier: String) async {
        await self.source.cancelCalendar(identifier)
    }

    func pauseOrResume() async {
        if self.source.state.paused {
            await self.source.resume()
        } else {
            self.source.pause()
        }
    }

    /// A count superseded by a newer request is never shown: only the latest request's result
    /// counts, and if an older one lands after it and leaves the engine holding a different
    /// span, the page counts the shown span again.
    private func counting(_ request: () async -> Void) async {
        self.latestCount += 1
        let generation = self.latestCount
        self.countFailed = false
        await request()
        if generation == self.latestCount {
            self.finishedCount = generation
            self.countFailed = self.frozenCount == nil
        } else if self.latestCount == self.finishedCount, self.frozenCount == nil {
            await self.count()
        }
    }
}
