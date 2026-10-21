// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import Observation
import XCTest

/// A calendar source the page drives in these tests. It records every call, can hold a count
/// until the test lets it finish, and freezes counts the way the engine does.
@MainActor
@Observable
final class PageFakeCalendarSource: CalendarSourceControlling {
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
    var calendars: [CalendarSourceCalendar] = [
        CalendarSourceCalendar(id: "work", title: "Work", accountName: "iCloud", followed: true, importStep: nil),
        CalendarSourceCalendar(id: "family", title: "Family", accountName: "iCloud", followed: true, importStep: nil),
    ]
    var pendingSetup: CalendarPendingSetup?

    /// Events per calendar, per span: a count is the sum over the calendars switched on.
    var eventsPerCalendar: [CalendarSpanChoice: Int] = [.last30Days: 3, .last6Months: 9, .lastYear: 14, .everything: 40, .fromToday: 0]
    var accessAfterRequest: CalendarAccess = .full
    var failCounts = false
    var holdCounts = false
    var switchOnCount = 5
    /// A switch-on after setup that cannot be counted leaves the calendar off, as the engine does.
    var failSwitchOn = false

    private(set) var accessRequests = 0
    private(set) var setUpCalls: [CalendarSpanChoice] = []
    private(set) var chosenSpans: [CalendarSpanChoice] = []
    private(set) var confirmed: CalendarPendingSetup?
    private(set) var resumes = 0
    private(set) var pauses = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    var heldCount: Int { self.held.count }

    func release(_ index: Int) {
        self.held.remove(at: index).resume()
    }

    func refreshAccess() {}

    func requestFullAccess() async -> CalendarAccess {
        self.accessRequests += 1
        if self.state.access == .notDetermined {
            self.state.access = self.accessAfterRequest
        }
        return self.state.access
    }

    func chooseSpan(_ span: CalendarSpanChoice) async {
        self.chosenSpans.append(span)
        if self.pendingSetup?.span != span {
            self.pendingSetup = CalendarPendingSetup(span: span, selection: self.selection, count: nil)
        }
    }

    func setUp(span: CalendarSpanChoice, calendarIDs: Set<String>?) async {
        self.setUpCalls.append(span)
        let selection = self.selection
        await self.waitIfHeld()
        self.freeze(span: span, selection: selection)
    }

    func confirm() async {
        self.confirmed = self.pendingSetup
        self.pendingSetup = nil
        self.state.everOn = true
        self.state.setupStep = .on
    }

    func pause() {
        self.pauses += 1
        self.state.paused = true
    }

    func resume() async {
        self.resumes += 1
        self.state.paused = false
    }

    func setCalendar(_ identifier: String, followed: Bool) async {
        guard let index = self.calendars.firstIndex(where: { $0.id == identifier }) else { return }
        let old = self.calendars[index]
        if self.state.everOn {
            let counted = followed && !self.failSwitchOn
            self.calendars[index] = CalendarSourceCalendar(
                id: old.id, title: old.title, accountName: old.accountName, followed: counted,
                importStep: counted ? .readyToConfirm(count: self.switchOnCount) : nil
            )
            return
        }
        self.calendars[index] = CalendarSourceCalendar(id: old.id, title: old.title, accountName: old.accountName, followed: followed, importStep: nil)
        // Before confirm, a switch re-counts.
        let span = self.pendingSetup?.span ?? .last30Days
        let selection = self.selection
        self.setUpCalls.append(span)
        await self.waitIfHeld()
        self.freeze(span: span, selection: selection)
    }

    func cancelCalendar(_ identifier: String) async {
        guard let index = self.calendars.firstIndex(where: { $0.id == identifier }) else { return }
        let old = self.calendars[index]
        self.calendars[index] = CalendarSourceCalendar(id: old.id, title: old.title, accountName: old.accountName, followed: false, importStep: nil)
    }

    func confirmCalendar(_ identifier: String) async {
        guard let index = self.calendars.firstIndex(where: { $0.id == identifier }) else { return }
        let old = self.calendars[index]
        self.calendars[index] = CalendarSourceCalendar(id: old.id, title: old.title, accountName: old.accountName, followed: true, importStep: nil)
    }

    private var selection: Set<String> {
        Set(self.calendars.filter(\.followed).map(\.id))
    }

    private func waitIfHeld() async {
        guard self.holdCounts else { return }
        await withCheckedContinuation { self.held.append($0) }
    }

    private func freeze(span: CalendarSpanChoice, selection: Set<String>) {
        let count = self.failCounts ? nil : (self.eventsPerCalendar[span] ?? 0) * selection.count
        self.pendingSetup = CalendarPendingSetup(span: span, selection: selection, count: count)
    }
}

nonisolated final class CalendarPageTests: XCTestCase {
    @MainActor
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: access requests

    @MainActor
    func testNothingAsksForAccessBeforeTurnOnNorFromTheTileOrAddMore() async {
        let source = PageFakeCalendarSource()
        let model = CalendarPageModel(source: source)
        await model.enter()
        XCTAssertEqual(source.accessRequests, 0)
        XCTAssertTrue(source.setUpCalls.isEmpty, "opening the page in ready to set up starts nothing")
        XCTAssertEqual(model.enrolAction, .turnOn)

        // The tile before the source is on, and in needs attention, has no switch.
        XCTAssertEqual(calendarTileControl(CalendarSourceStatus(state: source.state)), .none)
        _ = makeCalendarSource(source, isJournalPaired: true)

        await model.turnOn()
        XCTAssertEqual(source.accessRequests, 1)

        // Once on, the tile's switch only pauses and resumes.
        await model.confirm()
        XCTAssertEqual(calendarTileControl(CalendarSourceStatus(state: source.state)), .toggle)
        let requestsBefore = source.accessRequests
        let setUpsBefore = source.setUpCalls.count
        await setCalendarTile(source, on: false)
        await setCalendarTile(source, on: true)
        XCTAssertEqual(source.pauses, 1)
        XCTAssertEqual(source.resumes, 1)
        XCTAssertEqual(source.accessRequests, requestsBefore)
        XCTAssertEqual(source.setUpCalls.count, setUpsBefore)
        source.state.access = .denied
        XCTAssertEqual(calendarTileControl(CalendarSourceStatus(state: source.state)), .none)
    }

    @MainActor
    func testTheLast30DaysIsPreselected() {
        let model = CalendarPageModel(source: PageFakeCalendarSource())
        XCTAssertEqual(model.span, .last30Days)
        XCTAssertEqual(CalendarVocabulary.spanOrder.first, .last30Days)
        XCTAssertEqual(CalendarVocabulary.spanOrder.count, 5)
    }

    // MARK: confirm

    @MainActor
    func testTheConfirmLabelShowsTheCountTheCheckingWordAndTheZeroCase() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.holdCounts = true
        let model = CalendarPageModel(source: source)
        let entering = Task { await model.enter() }
        await self.waitUntil { source.heldCount == 1 }
        XCTAssertEqual(model.confirmLabel, .checking)
        XCTAssertFalse(model.canConfirm, "confirm is disabled while counting")
        source.release(0)
        await entering.value
        XCTAssertEqual(model.confirmLabel, .count(6))
        XCTAssertTrue(model.canConfirm)

        source.holdCounts = false
        await model.pick(.fromToday)
        XCTAssertEqual(model.confirmLabel, .startFromToday)
        await model.pick(.lastYear)
        XCTAssertEqual(model.confirmLabel, .count(28))
    }

    @MainActor
    func testACalendarSwitchedDuringACountConfirmsTheSelectionOfTheCountShown() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.holdCounts = true
        let model = CalendarPageModel(source: source)
        let entering = Task { await model.enter() }
        await self.waitUntil { source.heldCount == 1 }
        let switching = Task { await model.setUpCalendar("family", on: false) }
        await self.waitUntil { source.heldCount == 2 }
        // The newer count lands first, then the older one.
        source.release(1)
        await switching.value
        XCTAssertEqual(model.confirmLabel, .count(3))
        source.holdCounts = false
        source.release(0)
        await entering.value
        await self.waitUntil { !model.isCounting && source.pendingSetup?.count == 3 }
        XCTAssertEqual(model.confirmLabel, .count(3))
        await model.confirm()
        XCTAssertEqual(source.confirmed?.selection, ["work"])
        XCTAssertEqual(source.confirmed?.count, 3)
    }

    @MainActor
    func testAFailedCountShowsTheFailureAndTryAgainCountsAgain() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.failCounts = true
        let model = CalendarPageModel(source: source)
        await model.enter()
        XCTAssertEqual(model.confirmLabel, .failed)
        XCTAssertEqual(model.enrolAction, .chooseCalendars(.failed))
        XCTAssertFalse(model.canConfirm)
        source.failCounts = false
        await model.count()
        XCTAssertEqual(model.confirmLabel, .count(6))
    }

    // MARK: relaunch

    @MainActor
    func testARelaunchAtTheConfirmStepShowsTheStoredCountWithNoCalls() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.pendingSetup = CalendarPendingSetup(span: .lastYear, selection: ["work", "family"], count: 17)
        let model = CalendarPageModel(source: source)
        await model.enter()
        XCTAssertEqual(model.span, .lastYear)
        XCTAssertEqual(model.confirmLabel, .count(17))
        XCTAssertTrue(source.setUpCalls.isEmpty)
        XCTAssertTrue(source.chosenSpans.isEmpty)
    }

    @MainActor
    func testARelaunchAtTheConfirmStepWithNoFrozenCountCountsExactlyOnce() async {
        for failing in [false, true] {
            let source = PageFakeCalendarSource()
            source.state.access = .full
            source.failCounts = failing
            source.pendingSetup = CalendarPendingSetup(span: .last6Months, selection: ["work", "family"], count: nil)
            let model = CalendarPageModel(source: source)
            await model.enter()
            await model.enter()
            XCTAssertEqual(source.setUpCalls, [.last6Months])
            XCTAssertEqual(model.confirmLabel, failing ? .failed : .count(18), "never the checking word forever")
        }
    }

    // MARK: declining

    @MainActor
    func testADeclineOrAPriorDenialOrWriteOnlyOffersOpenSettingsAndRestrictedOffersNothing() async {
        let declined = PageFakeCalendarSource()
        declined.accessAfterRequest = .denied
        let model = CalendarPageModel(source: declined)
        XCTAssertEqual(model.enrolAction, .turnOn)
        await model.turnOn()
        XCTAssertEqual(model.enrolAction, .openSettings, "without leaving the page")
        XCTAssertEqual(model.status.sourceState, .readyToSetUp)
        XCTAssertEqual(model.mode, .beforeOn)

        for (access, action) in [(CalendarAccess.denied, CalendarEnrolAction.openSettings), (.writeOnly, .openSettings), (.restricted, .restricted)] {
            let source = PageFakeCalendarSource()
            source.state.access = access
            let page = CalendarPageModel(source: source)
            await page.enter()
            XCTAssertEqual(page.enrolAction, action)
            XCTAssertTrue(source.setUpCalls.isEmpty)
            XCTAssertEqual(source.accessRequests, 0)
        }
    }

    @MainActor
    func testReturningFromSettingsWithFullAccessUsesTheSavedSpan() async {
        let source = PageFakeCalendarSource()
        source.state.access = .denied
        let before = CalendarPageModel(source: source)
        await before.pick(.lastYear)
        XCTAssertEqual(source.chosenSpans, [.lastYear])
        XCTAssertTrue(source.setUpCalls.isEmpty)

        // iOS ended the app; the owner allowed full access in Settings.
        source.state.access = .full
        let after = CalendarPageModel(source: source)
        await after.enter()
        XCTAssertEqual(after.span, .lastYear)
        XCTAssertEqual(source.setUpCalls, [.lastYear])
        XCTAssertEqual(after.mode, .confirm)
        XCTAssertEqual(after.confirmLabel, .count(28))
    }

    @MainActor
    func testReturningFromSettingsWithoutARelaunchShowsTheCalendarsAndCountsOnce() async {
        let source = PageFakeCalendarSource()
        source.accessAfterRequest = .denied
        let model = CalendarPageModel(source: source)
        await model.enter()
        await model.turnOn()
        XCTAssertEqual(model.enrolAction, .openSettings)
        XCTAssertTrue(source.setUpCalls.isEmpty)

        // The owner allowed full access in Settings and came back to the same page. The app
        // read the new access on the way back, before the page did.
        source.state.access = .full
        await model.returnedToForeground()
        XCTAssertEqual(source.setUpCalls, [.last30Days])
        XCTAssertEqual(model.mode, .confirm)
        XCTAssertEqual(model.enrolAction, .chooseCalendars(.count(6)))
        await model.returnedToForeground()
        await model.enter()
        XCTAssertEqual(source.setUpCalls, [.last30Days], "exactly one count")
    }

    @MainActor
    func testAccessRevokedBeforeConfirmReadsReadyToSetUpWithNoConfirmAndNoAttention() async {
        let source = PageFakeCalendarSource()
        source.state.access = .denied
        source.pendingSetup = CalendarPendingSetup(span: .last30Days, selection: ["work"], count: 3)
        let model = CalendarPageModel(source: source)
        await model.enter()
        XCTAssertEqual(model.status.sourceState, .readyToSetUp)
        XCTAssertNil(model.status.attention)
        XCTAssertEqual(model.enrolAction, .openSettings)
        XCTAssertEqual(source.state.notesNeedingAttention, 0)
        XCTAssertNil(calendarSourceModel(state: source.state, isJournalPaired: true).attention)
        source.state.access = .notDetermined
        XCTAssertEqual(model.enrolAction, .turnOn)
    }

    // MARK: once on

    @MainActor
    func testEachNeedsAttentionCaseAppearsOnlyAfterConfirm() {
        let expected: [(CalendarAccess, CalendarAttentionReason, Bool)] = [
            (.denied, .accessRevoked, true),
            (.writeOnly, .writeOnly, true),
            (.restricted, .restricted, false),
        ]
        for (access, reason, opensSettings) in expected {
            let source = PageFakeCalendarSource()
            source.state.access = access
            let model = CalendarPageModel(source: source)
            XCTAssertNil(model.status.attention)
            XCTAssertNotEqual(model.status.sourceState, .needsAttention)
            source.state.everOn = true
            XCTAssertEqual(model.status.attention, reason)
            XCTAssertEqual(model.status.sourceState, .needsAttention)
            XCTAssertEqual(reason.opensSettings, opensSettings)
            XCTAssertEqual(model.mode, .needsAttention)
            XCTAssertEqual(calendarTileControl(model.status), .none)
        }
    }

    @MainActor
    func testWaitingForAJournalUpdateReplacesTheDeliveryLineAndIsNotNeedsAttention() {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.state.everOn = true
        source.state.notesWaiting = 4
        let model = CalendarPageModel(source: source)
        XCTAssertEqual(model.deliveryLine, .sending(4))
        source.state.waitingForJournalUpdate = true
        XCTAssertEqual(model.deliveryLine, .waitingForJournalUpdate)
        XCTAssertNil(model.status.attention)
        XCTAssertEqual(model.status.sourceState, .active)
        XCTAssertEqual(model.mode, .waitingForUpdate)
        source.state.waitingForJournalUpdate = false
        source.state.notesNeedingAttention = 2
        XCTAssertEqual(model.deliveryLine, .needsAttention(2))
        source.state.notesNeedingAttention = 0
        source.state.notesWaiting = 0
        XCTAssertEqual(model.deliveryLine, .quiet)
    }

    @MainActor
    func testSwitchingACalendarOnShowsItsCountAndNotNowLeavesItOff() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.state.everOn = true
        source.calendars.append(CalendarSourceCalendar(id: "club", title: "Club", accountName: "Exchange", followed: false, importStep: nil))
        let model = CalendarPageModel(source: source)
        XCTAssertEqual(model.followedFact.followed, 2)
        XCTAssertEqual(model.followedFact.total, 3)

        await model.setCalendar("club", on: true)
        XCTAssertEqual(source.calendars.first { $0.id == "club" }?.importStep, .readyToConfirm(count: 5))
        XCTAssertEqual(model.pendingSwitchOn, "club")
        XCTAssertEqual(model.followedFact.followed, 2, "not followed until confirmed")
        // Other switches wait while one switch-on is pending.
        await model.setCalendar("work", on: false)
        XCTAssertEqual(source.calendars.first { $0.id == "work" }?.followed, true)

        // A relaunch returns to its confirm, still not followed.
        let relaunched = CalendarPageModel(source: source)
        XCTAssertEqual(relaunched.pendingSwitchOn, "club")
        XCTAssertEqual(relaunched.followedFact.followed, 2)

        await relaunched.notNow("club")
        XCTAssertEqual(source.calendars.first { $0.id == "club" }?.followed, false)
        XCTAssertNil(source.calendars.first { $0.id == "club" }?.importStep)
        XCTAssertNil(relaunched.pendingSwitchOn)
        XCTAssertEqual(relaunched.followedFact.followed, 2)
    }

    @MainActor
    func testASwitchOnThatCannotBeCountedStaysOffAndOffersTryAgain() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.state.everOn = true
        source.calendars.append(CalendarSourceCalendar(id: "club", title: "Club", accountName: "Exchange", followed: false, importStep: nil))
        source.failSwitchOn = true
        let model = CalendarPageModel(source: source)
        await model.setCalendar("club", on: true)
        XCTAssertEqual(model.failedSwitchOn, "club")
        XCTAssertEqual(source.calendars.first { $0.id == "club" }?.followed, false)
        XCTAssertNil(model.pendingSwitchOn)

        source.failSwitchOn = false
        await model.setCalendar("club", on: true)
        XCTAssertNil(model.failedSwitchOn)
        XCTAssertEqual(source.calendars.first { $0.id == "club" }?.importStep, .readyToConfirm(count: 5))
    }

    @MainActor
    func testCalendarSwitchesWaitForFullAccess() async {
        for access in [CalendarAccess.denied, .writeOnly, .restricted, .notDetermined] {
            let source = PageFakeCalendarSource()
            source.state.access = access
            source.state.everOn = true
            source.calendars.append(CalendarSourceCalendar(id: "club", title: "Club", accountName: "Exchange", followed: false, importStep: nil))
            let model = CalendarPageModel(source: source)
            XCTAssertFalse(model.canChangeCalendars)
            await model.setCalendar("club", on: true)
            await model.setCalendar("work", on: false)
            XCTAssertEqual(source.calendars.map(\.followed), [true, true, false], "\(access)")
            XCTAssertNil(model.failedSwitchOn)
        }
    }

    @MainActor
    func testInNeedsAttentionTheReasonIsTheWholeSubLineAndPauseAndResumeStay() async {
        for (access, reason) in [(CalendarAccess.denied, CalendarAttentionReason.accessRevoked), (.writeOnly, .writeOnly), (.restricted, .restricted)] {
            let source = PageFakeCalendarSource()
            source.state.access = access
            source.state.everOn = true
            let tile = calendarSourceModel(state: source.state, isJournalPaired: true)
            XCTAssertEqual(tile.state, .needsAttention)
            XCTAssertEqual(tile.subtextOverride, reason.text)
            XCTAssertNotEqual(tile.subtext, SourceVocabulary.needsAttentionSubtext)
            let model = CalendarPageModel(source: source)
            XCTAssertTrue(model.offersPauseResume)
            await model.pauseOrResume()
            XCTAssertEqual(source.pauses, 1)
            XCTAssertTrue(model.offersPauseResume)
            await model.pauseOrResume()
            XCTAssertEqual(source.resumes, 1)
        }
        XCTAssertFalse(CalendarPageModel(source: PageFakeCalendarSource()).offersPauseResume)
    }

    @MainActor
    func testAnUntitledChangeShowsTheChangeWordAloneAndLastCheckedHasItsDateWhenNotToday() {
        for kind in [CalendarRecentKind.added, .moved, .changed, .removed] {
            XCTAssertEqual(CalendarVocabulary.recent(kind, title: nil), kind.rawValue)
            XCTAssertEqual(CalendarVocabulary.recent(kind, title: ""), kind.rawValue)
            XCTAssertTrue(CalendarVocabulary.recent(kind, title: "standup").hasSuffix("standup"))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 16, minute: 30))!
        let earlierToday = calendar.date(byAdding: .hour, value: -3, to: now)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(
            CalendarVocabulary.lastCheckedTime(earlierToday, now: now, calendar: calendar),
            earlierToday.formatted(date: .omitted, time: .shortened)
        )
        XCTAssertEqual(
            CalendarVocabulary.lastCheckedTime(yesterday, now: now, calendar: calendar),
            yesterday.formatted(date: .abbreviated, time: .shortened)
        )
    }

    @MainActor
    func testPauseAndResumeWorkAsOnLocation() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.state.everOn = true
        let model = CalendarPageModel(source: source)
        XCTAssertEqual(model.status.sourceState, .active)
        await model.pauseOrResume()
        XCTAssertEqual(model.status.sourceState, .paused)
        XCTAssertEqual(calendarTileControl(model.status), .toggle)
        await model.pauseOrResume()
        XCTAssertEqual(model.status.sourceState, .active)
        XCTAssertEqual(source.pauses, 1)
        XCTAssertEqual(source.resumes, 1)
    }

    @MainActor
    func testTheDeckTilesAccessibleValueIsTheStateWordAlone() {
        let source = PageFakeCalendarSource()
        let states: [(CalendarAccess, Bool, Bool, SourceState)] = [
            (.notDetermined, false, false, .readyToSetUp),
            (.full, false, false, .readyToSetUp),
            (.full, true, false, .active),
            (.full, true, true, .paused),
            (.denied, true, false, .needsAttention),
        ]
        for (access, everOn, paused, expected) in states {
            source.state.access = access
            source.state.everOn = everOn
            source.state.paused = paused
            let tile = calendarSourceModel(state: source.state, isJournalPaired: true)
            XCTAssertEqual(tile.state, expected)
            XCTAssertEqual(tile.kind, .calendar)
            // `HomeSourceTile` sets its accessibility value to the source's state word and nothing else.
            XCTAssertEqual(HomeSourceTile.accessibilityValue(for: tile), tile.state.label)
        }
    }

    // MARK: superseded counts

    @MainActor
    func testAnOlderCountLandingAfterANewerOneIsNeverShownAndConfirmSendsTheNewer() async {
        let source = PageFakeCalendarSource()
        source.state.access = .full
        source.holdCounts = true
        let model = CalendarPageModel(source: source)
        var shown: [CalendarConfirmLabel] = []
        let first = Task { await model.enter() }
        await self.waitUntil { source.heldCount == 1 }
        let second = Task { await model.pick(.lastYear) }
        await self.waitUntil { source.heldCount == 2 }
        source.release(1)
        await second.value
        shown.append(model.confirmLabel)
        source.holdCounts = false
        source.release(0)
        await first.value
        shown.append(model.confirmLabel)
        await self.waitUntil { source.pendingSetup?.span == .lastYear && source.pendingSetup?.count != nil && !model.isCounting }
        shown.append(model.confirmLabel)
        XCTAssertFalse(shown.contains(.count(6)), "the last 30 days' count is never shown")
        XCTAssertEqual(shown.last, .count(28))
        await model.confirm()
        XCTAssertEqual(source.confirmed?.span, .lastYear)
    }

    @MainActor
    func testTheTileInNeedsAttentionHasNoSwitchAndOpensThePage() {
        let source = PageFakeCalendarSource()
        source.state.access = .writeOnly
        source.state.everOn = true
        let status = CalendarSourceStatus(state: source.state)
        XCTAssertEqual(status.sourceState, .needsAttention)
        XCTAssertEqual(calendarTileControl(status), .none)
        XCTAssertEqual(ShellDestination.source(.calendar), .source(SourceRoute.calendar))
        XCTAssertEqual(SourceRoute.calendar.id, "calendar")
    }
}
