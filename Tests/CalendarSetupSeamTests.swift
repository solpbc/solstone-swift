// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

/// The engine behaviours the calendar page relies on, over a temporary store and a fake
/// calendar that behaves as iOS does.
nonisolated final class CalendarSetupSeamTests: XCTestCase {
    @MainActor
    private static func harness() -> CalendarHarness {
        let harness = CalendarSourceEngineTests.harness()
        harness.provider.addCalendar("cal-family", title: "Family")
        harness.provider.events = [
            // Within the last 30 days, and ahead.
            CalendarSourceEngineTests.meeting("RECENT-1", title: "review", CalendarFixtures.at(2026, 10, 10, 9, 0), lastModified: "2026-10-01T10:00:00-06:00"),
            CalendarSourceEngineTests.meeting("AHEAD-1", calendar: "cal-family", title: "trip", CalendarFixtures.at(2026, 11, 20, 9, 0), lastModified: "2026-10-02T10:00:00-06:00"),
            // Older than 30 days.
            CalendarSourceEngineTests.meeting("OLD-1", title: "kickoff", CalendarFixtures.at(2026, 5, 4, 9, 0), lastModified: "2026-04-01T10:00:00-06:00"),
            CalendarSourceEngineTests.meeting("OLD-2", calendar: "cal-family", title: "wedding", CalendarFixtures.at(2019, 6, 8, 15, 0), lastModified: "2019-01-01T10:00:00-07:00"),
            CalendarSourceEngineTests.meeting("OLD-3", title: "graduation", CalendarFixtures.at(1998, 6, 1, 10, 0), lastModified: "1998-01-01T10:00:00-07:00"),
        ]
        return harness
    }

    /// What a relaunch would read from disk.
    @MainActor
    private static func storedDocument(_ harness: CalendarHarness) -> CalendarSourceDocument {
        let store = CalendarSourceStore(rootURL: harness.rootURL)
        XCTAssertTrue(store.load())
        return store.document
    }

    @MainActor
    func testPickingAllOfItBeforeConfirmReplacesTheCountAndTheFrozenSet() async {
        let harness = Self.harness()
        await harness.ensureLaunched()
        await harness.engine.setUp(span: .last30Days)
        XCTAssertEqual(harness.engine.pendingSetup?.count, 2)

        await harness.engine.chooseSpan(.everything)
        XCTAssertEqual(harness.engine.pendingSetup?.span, .everything)
        XCTAssertNil(harness.engine.pendingSetup?.count, "a different span drops the earlier count")
        await harness.engine.setUp(span: .everything)
        XCTAssertEqual(harness.engine.pendingSetup?.count, 5)
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.engine.document.imports.map(\.count), [5], "only the latest freeze is kept")

        await harness.engine.confirm()
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.delivery.lines.count, 5)
        XCTAssertEqual(Set(harness.delivery.lines.compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])?["event"] as? String
        }), ["RECENT-1", "AHEAD-1", "OLD-1", "OLD-2", "OLD-3"])
        XCTAssertEqual(harness.engine.setupStep, .on)
    }

    @MainActor
    func testANewEngineSeesTheSpanSelectionFrozenCountAndPendingSwitchOn() async {
        let harness = Self.harness()
        await harness.ensureLaunched()
        await harness.engine.chooseSpan(.last6Months)
        harness.rebuild()
        XCTAssertEqual(harness.engine.pendingSetup, CalendarPendingSetup(span: .last6Months, selection: [], count: nil))

        await harness.ensureLaunched()
        await harness.engine.setUp(span: .last6Months, calendarIDs: ["cal-work"])
        harness.rebuild()
        XCTAssertEqual(harness.engine.pendingSetup, CalendarPendingSetup(span: .last6Months, selection: ["cal-work"], count: 2))
        XCTAssertEqual(harness.engine.setupStep, .readyToConfirm(count: 2))

        await harness.ensureLaunched()
        await harness.engine.confirm()
        await harness.engine.setCalendar("cal-family", followed: true)
        harness.rebuild()
        XCTAssertNil(harness.engine.pendingSetup, "confirmed")
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-family" }?.importStep, .readyToConfirm(count: 1))
    }

    @MainActor
    func testNotNowSendsNothingFromThatCalendarAndLeavesItOff() async {
        let harness = Self.harness()
        await harness.setUpAndConfirm(.everything, calendarIDs: ["cal-work"])
        let sent = harness.delivery.lines.count
        XCTAssertEqual(sent, 3)

        await harness.engine.setCalendar("cal-family", followed: true)
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-family" }?.importStep, .readyToConfirm(count: 2))
        await harness.engine.cancelCalendar("cal-family")
        let family = harness.engine.calendars.first { $0.id == "cal-family" }
        XCTAssertEqual(family?.followed, false)
        XCTAssertNil(family?.importStep)
        XCTAssertEqual(harness.engine.state.followedCount, 1)

        harness.provider.events.append(CalendarSourceEngineTests.meeting("FAM-NEW", calendar: "cal-family", title: "party", CalendarFixtures.at(2026, 10, 30, 18, 0), lastModified: "2026-10-20T16:00:00-06:00"))
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, sent, "a routine check sends nothing from that calendar")
    }

    @MainActor
    func testASavedSpanWithNothingSetUpReadsNothing() async {
        let harness = Self.harness()
        harness.provider.accessValue = .full
        await harness.ensureLaunched()
        await harness.engine.chooseSpan(.lastYear)
        harness.rebuild()
        await harness.engine.launch()
        harness.engine.foreground()
        harness.engine.storeChanged()
        await harness.engine.backgroundRefresh()
        try? await Task.sleep(for: .milliseconds(100))
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.provider.readCount, 0)
        XCTAssertEqual(harness.engine.pendingSetup?.span, .lastYear)
        XCTAssertEqual(harness.engine.setupStep, .notSetUp)
    }

    @MainActor
    func testOwnerOperationsWaitForTheLaunch() async {
        let harness = Self.harness()
        let engine = harness.engine
        async let counted: Void = engine.setUp(span: .last30Days)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(harness.provider.readCount, 0, "nothing runs before the launch finishes")
        XCTAssertEqual(harness.delivery.stagingClears, 0)
        await engine.launch()
        await counted
        XCTAssertEqual(harness.delivery.stagingClears, 1)
        XCTAssertEqual(engine.pendingSetup?.count, 2)

        harness.settings.launchWait = .milliseconds(200)
        harness.rebuild()
        let reads = harness.provider.readCount
        await harness.engine.setUp(span: .everything)
        XCTAssertEqual(harness.provider.readCount, reads, "with no launch the operation is given up, not run early")
        XCTAssertEqual(harness.engine.pendingSetup, CalendarPendingSetup(span: .last30Days, selection: ["cal-work", "cal-family"], count: 2))
    }

    @MainActor
    func testASwitchBeforeConfirmDropsTheCountInTheSameSaveAndARelaunchCountsOnceForWhatIsOn() async {
        let harness = Self.harness()
        await harness.ensureLaunched()
        await harness.engine.setUp(span: .last30Days)
        XCTAssertEqual(harness.engine.pendingSetup, CalendarPendingSetup(span: .last30Days, selection: ["cal-work", "cal-family"], count: 2))

        // The recount fails: the calendar cannot be read for it.
        harness.provider.accessValue = .denied
        await harness.engine.setCalendar("cal-family", followed: false)
        await harness.engine.waitUntilIdle()
        XCTAssertNil(harness.engine.pendingSetup?.count)
        XCTAssertTrue(Self.storedDocument(harness).imports.isEmpty, "the old count went with the switch")

        harness.provider.accessValue = .full
        harness.rebuild()
        await harness.ensureLaunched()
        XCTAssertNil(harness.engine.pendingSetup?.count, "no stale count after a relaunch")
        let source = CountingCalendarSource(harness.engine)
        let page = CalendarPageModel(source: source)
        XCTAssertNotEqual(page.confirmLabel, .count(2))
        await page.enter()
        XCTAssertEqual(source.setUpCalls, 1)
        XCTAssertEqual(harness.engine.pendingSetup, CalendarPendingSetup(span: .last30Days, selection: ["cal-work"], count: 1))
        XCTAssertEqual(page.confirmLabel, .count(1))
    }

    @MainActor
    func testACountForAnotherSelectionNeverReadsAsTheOneShown() async {
        let harness = Self.harness()
        await harness.ensureLaunched()
        await harness.engine.setUp(span: .last30Days, calendarIDs: ["cal-work"])
        let page = CalendarPageModel(source: harness.engine)
        XCTAssertEqual(page.confirmLabel, .count(1))
        // The switches now show Work and Family; the stored count was made for Work alone.
        var document = harness.store.document
        if let index = document.calendars.firstIndex(where: { $0.identifier == "cal-family" }) {
            document.calendars[index].followed = true
        }
        harness.store.saveDocument(document)
        harness.rebuild()
        await harness.ensureLaunched()
        XCTAssertEqual(harness.engine.pendingSetup?.selection, ["cal-work"])
        XCTAssertEqual(CalendarPageModel(source: harness.engine).confirmLabel, .checking)
    }

    @MainActor
    func testASwitchOnAfterSetupWithAccessRevokedSendsNothingUntilConfirmed() async {
        let harness = Self.harness()
        await harness.setUpAndConfirm(.everything, calendarIDs: ["cal-work"])
        let sent = harness.delivery.lines.count
        XCTAssertEqual(sent, 3)

        harness.provider.accessValue = .denied
        await harness.engine.setCalendar("cal-family", followed: true)
        var family = harness.engine.calendars.first { $0.id == "cal-family" }
        XCTAssertEqual(family?.followed, false, "with no count it stays off")
        XCTAssertNil(family?.importStep)

        harness.provider.accessValue = .full
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, sent)

        await harness.engine.setCalendar("cal-family", followed: true)
        family = harness.engine.calendars.first { $0.id == "cal-family" }
        XCTAssertEqual(family?.importStep, .readyToConfirm(count: 2))
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, sent, "nothing before confirm")

        await harness.engine.confirmCalendar("cal-family")
        await harness.engine.waitUntilIdle()
        XCTAssertEqual(harness.delivery.lines.count, sent + 2)
    }

    @MainActor
    func testACountFailureLeavesTheCalendarOff() async throws {
        let harness = Self.harness()
        await harness.setUpAndConfirm(.everything, calendarIDs: ["cal-work"])
        let sent = harness.delivery.lines.count
        // The frozen set cannot be written.
        let imports = harness.rootURL.appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.removeItem(at: imports)
        try Data().write(to: imports)

        await harness.engine.setCalendar("cal-family", followed: true)
        let family = harness.engine.calendars.first { $0.id == "cal-family" }
        XCTAssertEqual(family?.followed, false)
        XCTAssertNil(family?.importStep)
        harness.rebuild()
        await harness.ensureLaunched()
        XCTAssertEqual(harness.engine.calendars.first { $0.id == "cal-family" }?.followed, false)
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(harness.delivery.lines.count, sent)
    }

    @MainActor
    func testRevokingAndRegrantingBeforeConfirmCountsOnce() async {
        let harness = Self.harness()
        await harness.ensureLaunched()
        let source = CountingCalendarSource(harness.engine)
        let page = CalendarPageModel(source: source)
        await page.enter()
        XCTAssertEqual(source.setUpCalls, 1)
        XCTAssertEqual(page.confirmLabel, .count(2))

        harness.provider.accessValue = .denied
        await page.returnedToForeground()
        await harness.engine.waitUntilIdle()
        XCTAssertNil(harness.engine.pendingSetup?.count, "a count is dropped once the calendar cannot be read")
        XCTAssertTrue(Self.storedDocument(harness).imports.isEmpty)
        XCTAssertEqual(page.enrolAction, .openSettings)

        harness.provider.accessValue = .full
        await page.returnedToForeground()
        await page.returnedToForeground()
        XCTAssertEqual(source.setUpCalls, 2, "counted once more")
        XCTAssertEqual(page.confirmLabel, .count(2))
    }

    @MainActor
    func testASpanPickedDuringACountLeavesNoConfirmableCountWithoutItsFrozenSet() async throws {
        let harness = Self.harness()
        await harness.ensureLaunched()
        let reached = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        harness.provider.readGate = {
            reached.withLock { $0 = true }
            release.wait()
        }
        let engine = harness.engine
        let first = Task { await engine.setUp(span: .last30Days) }
        while !reached.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let second = Task { await engine.chooseSpan(.lastYear) }
        try await Task.sleep(for: .milliseconds(50))
        harness.provider.readGate = nil
        release.signal()
        await first.value
        // A kill as soon as the first count has finished.
        let killed = CalendarSourceStore(rootURL: harness.rootURL)
        XCTAssertTrue(killed.load())
        XCTAssertNotEqual(killed.document.span, .last30Days, "a superseded count writes nothing")
        XCTAssertTrue(killed.document.imports.isEmpty)
        await second.value
        await engine.waitUntilIdle()

        harness.rebuild()
        await harness.ensureLaunched()
        XCTAssertEqual(harness.engine.pendingSetup, CalendarPendingSetup(span: .lastYear, selection: [], count: nil))
        let imports = harness.rootURL.appendingPathComponent("imports", isDirectory: true)
        let frozen = (try? FileManager.default.contentsOfDirectory(atPath: imports.path)) ?? []
        XCTAssertTrue(frozen.isEmpty, "no frozen set left behind")
    }

    /// Whenever the page says notes are on their way, or that the journal needs an update, the
    /// waiting count and the status breakdown include calendar, including before any of an
    /// import's files enter the transfer queue.
    @MainActor
    func testCalendarCountsAsWaitingWheneverItsDeliveryLineDoes() async throws {
        let rig = try await CalendarDeliveryRig(capabilities: ["calendar_notes"])
        rig.resolver.set(.unavailable("waiting"))
        rig.harness.settings.importWindow = 0
        rig.harness.rebuild()
        rig.addMeetings(count: 3)
        await rig.harness.setUpAndConfirm()
        let queued = await rig.engine.itemSnapshots(sourceKey: "calendar").count
        XCTAssertEqual(queued, 0, "nothing has entered the transfer queue yet")
        let model = CalendarPageModel(source: rig.harness.engine)
        XCTAssertEqual(model.deliveryLine, .sending(3))
        self.assertCalendarWaits(rig)

        let waiting = try await CalendarDeliveryRig(capabilities: [])
        waiting.addMeetings(count: 2)
        await waiting.harness.setUpAndConfirm()
        try await waiting.waitFor("the journal was read and the queue published") { waiting.holder.waitingForJournalUpdate }
        let page = CalendarPageModel(source: waiting.harness.engine)
        XCTAssertEqual(page.deliveryLine, .waitingForJournalUpdate)
        self.assertCalendarWaits(waiting)
    }

    @MainActor
    private func assertCalendarWaits(_ rig: CalendarDeliveryRig, file: StaticString = #filePath, line: UInt = #line) {
        let capture = captureUploadTotals(mobileSegment: rig.mobile, watch: rig.watch, calendar: rig.holder)
        XCTAssertGreaterThan(capture.pending + capture.failed, 0, file: file, line: line)
        let presentation = StatusPaneWaitingPresentation.build(
            mobileAggregateCount: 0,
            audioCount: 0,
            locationCount: 0,
            screencastCount: 0,
            watchCount: 0,
            calendarCount: rig.holder.pendingCount + rig.holder.failedCount
        )
        XCTAssertGreaterThan(presentation.total, 0, file: file, line: line)
        XCTAssertEqual(presentation.rows.map(\.source), [.calendar], file: file, line: line)
        XCTAssertEqual(presentation.rows.first?.route, .calendar, file: file, line: line)
    }
}

/// Passes everything to the engine, counting the counts the page asks for.
@MainActor
final class CountingCalendarSource: CalendarSourceControlling {
    private let engine: CalendarSourceEngine
    private(set) var setUpCalls = 0

    init(_ engine: CalendarSourceEngine) {
        self.engine = engine
    }

    var state: CalendarSourceState { self.engine.state }
    var calendars: [CalendarSourceCalendar] { self.engine.calendars }
    var pendingSetup: CalendarPendingSetup? { self.engine.pendingSetup }
    func refreshAccess() { self.engine.refreshAccess() }
    func requestFullAccess() async -> CalendarAccess { await self.engine.requestFullAccess() }
    func chooseSpan(_ span: CalendarSpanChoice) async { await self.engine.chooseSpan(span) }

    func setUp(span: CalendarSpanChoice, calendarIDs: Set<String>?) async {
        self.setUpCalls += 1
        await self.engine.setUp(span: span, calendarIDs: calendarIDs)
    }

    func confirm() async { await self.engine.confirm() }
    func pause() { self.engine.pause() }
    func resume() async { await self.engine.resume() }
    func setCalendar(_ identifier: String, followed: Bool) async { await self.engine.setCalendar(identifier, followed: followed) }
    func cancelCalendar(_ identifier: String) async { await self.engine.cancelCalendar(identifier) }
    func confirmCalendar(_ identifier: String) async { await self.engine.confirmCalendar(identifier) }
}
