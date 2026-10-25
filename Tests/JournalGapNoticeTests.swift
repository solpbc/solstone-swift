// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// The notice names the day and takes the caught-up slot only while nothing else is waiting.
@MainActor
final class JournalGapNoticeTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: MobileSegmentStore!
    private var events: JournalEventStore!
    private var clock: MockObserverClock!

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalGapNotice-\(UUID().uuidString)", isDirectory: true)
        self.store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        self.events = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: self.store.rootURL))
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_793_199_600))
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.events = nil
        self.store = nil
        self.clock = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testPillTakesTheCaughtUpSlotOnlyWhenTheGapIsTheWholeStory() {
        let gap = HomeStatusPillState.resolve(
            isPaired: true,
            status: .connectedIdle,
            hasBacklog: false,
            isStalled: false,
            awaitingMarkConfirmation: false,
            hasJournalGap: true
        )
        XCTAssertEqual(gap, .journalGap)
        XCTAssertEqual(
            HomeStatusPillState.resolve(
                isPaired: true,
                status: .connectedWaiting,
                hasBacklog: false,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasJournalGap: true
            ),
            .journalGap
        )
        XCTAssertEqual(
            HomeStatusPillState.resolve(
                isPaired: true,
                status: .connectedTransferring,
                hasBacklog: false,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasJournalGap: true
            ),
            .journalGap
        )
        XCTAssertEqual(
            HomeStatusPillState.resolve(
                isPaired: true,
                status: .connectedIdle,
                hasBacklog: true,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasJournalGap: true
            ),
            .syncing
        )
        XCTAssertEqual(
            HomeStatusPillState.resolve(
                isPaired: true,
                status: .connectedIdle,
                hasBacklog: false,
                isStalled: true,
                awaitingMarkConfirmation: false,
                hasJournalGap: true
            ),
            .stalled
        )
        XCTAssertEqual(
            HomeStatusPillState.resolve(
                isPaired: false,
                status: .connectedIdle,
                hasBacklog: false,
                isStalled: false,
                awaitingMarkConfirmation: false,
                hasJournalGap: true
            ),
            .notPaired
        )
        XCTAssertFalse(gap.shouldPulse(reduceMotion: false))
        XCTAssertEqual(gap.label, SourceVocabulary.journalGapHeadline)
        let lead = StatusPaneLead.resolve(pillState: .journalGap, waitingTotal: 0, showsConnectionDetails: true, gapDayLine: SourceVocabulary.journalGapToday)
        XCTAssertEqual(lead.headline, SourceVocabulary.journalGapHeadline)
        XCTAssertFalse(lead.showsJournalGapNotice)
        let beside = StatusPaneLead.resolve(pillState: .syncing, waitingTotal: 1, showsConnectionDetails: true, gapDayLine: SourceVocabulary.journalGapToday)
        XCTAssertTrue(beside.showsJournalGapNotice)
        XCTAssertNotEqual(beside.headline, SourceVocabulary.journalGapHeadline)
    }

    func testDayLineNamesTodayYesterdayAWeekdayAndASpan() throws {
        let calendar = Self.utc
        let now = self.clock.now()
        XCTAssertEqual(calendar.component(.weekday, from: now), 4)
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let monday = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: today))

        let todayNotice = try self.notice(found: now, captures: [now], now: now, calendar: calendar)
        XCTAssertEqual(todayNotice.dayLine, SourceVocabulary.journalGapToday)

        let yesterdayNotice = try self.notice(found: now, captures: [yesterday], now: now, calendar: calendar)
        XCTAssertEqual(yesterdayNotice.dayLine, SourceVocabulary.journalGapYesterday)

        let weekdayNotice = try self.notice(found: now, captures: [monday], now: now, calendar: calendar)
        XCTAssertEqual(weekdayNotice.dayLine, SourceVocabulary.journalGapOn(weekday: "monday"))

        let sinceWeekday = try self.notice(found: now, captures: [monday, yesterday], now: now, calendar: calendar)
        XCTAssertEqual(sinceWeekday.dayLine, SourceVocabulary.journalGapSince(earliest: "monday"))

        let sinceYesterday = try self.notice(found: now, captures: [yesterday, now], now: now, calendar: calendar)
        XCTAssertEqual(sinceYesterday.dayLine, SourceVocabulary.journalGapSince(earliest: "yesterday"))

        let undated = try self.notice(found: now, captures: [nil], now: now, calendar: calendar)
        XCTAssertEqual(undated.dayLine, SourceVocabulary.journalGapUndated)
    }

    func testCaptureFromNineDaysAgoFoundTodayStaysUndatedAndShowing() throws {
        let calendar = Self.utc
        let now = self.clock.now()
        let capture = try XCTUnwrap(calendar.date(byAdding: .day, value: -9, to: now))
        let notice = try self.notice(found: now, captures: [capture], now: now, calendar: calendar)
        XCTAssertTrue(notice.isShowing)
        XCTAssertEqual(notice.dayLine, SourceVocabulary.journalGapUndated)
    }

    func testUnseenLossOutsideTheWindowIsAbsent() throws {
        let calendar = Self.utc
        let now = self.clock.now()
        let found = try XCTUnwrap(calendar.date(byAdding: .day, value: -8, to: now))
        let notice = try self.notice(found: found, captures: [found], now: now, calendar: calendar)
        XCTAssertEqual(notice, .absent)
        guard case .events(let rows) = self.events.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertEqual(rows.count, 1)
    }

    func testWindowUsesCalendarDaysAcrossTheDaylightSavingBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))
        let window = try XCTUnwrap(JournalEventStore.windowStart(now: now, calendar: calendar))
        let raw = now.addingTimeInterval(-6 * 86_400)
        XCTAssertLessThan(window, raw)
        let found = window.addingTimeInterval(30 * 60)
        XCTAssertLessThan(found, raw)
        let notice = try self.notice(found: found, captures: [found], now: now, calendar: calendar)
        XCTAssertTrue(notice.isShowing)
    }

    func testDelayUntilTheNextLocalDayIsAtLeastOneSecond() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 23, minute: 0)))
        XCTAssertEqual(JournalGapNotice.delayUntilNextDay(from: now, calendar: calendar), 60 * 60)
        let almost = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0, minute: 0)))
            .addingTimeInterval(-0.2)
        XCTAssertEqual(JournalGapNotice.delayUntilNextDay(from: almost, calendar: calendar), 1)
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0, minute: 0)))
        XCTAssertEqual(JournalGapNotice.delayUntilNextDay(from: midnight, calendar: calendar), 24 * 60 * 60)
    }

    func testAppSnapshotTaskWritesTheJournalGapField() throws {
        let root = self.tempDirectory.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mirror = AppGroupMirror(rootURLProvider: { root })
        guard case .success = writeObserverWidgetSnapshot(
            mirror: mirror,
            pairing: AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: [.observer: .active],
            backlogCount: 0,
            awaitingMarkConfirmation: false,
            journalGap: true
        ) else {
            return XCTFail("snapshot write failed")
        }
        let decoded = try JSONDecoder().decode(
            AppGroupMirror.Snapshot.self,
            from: Data(contentsOf: root.appendingPathComponent(AppGroupMirror.Snapshot.fileName))
        )
        XCTAssertTrue(decoded.journalGap)
    }

    func testForegroundClockChangeDoesNotWriteTheStore() throws {
        let calendar = Self.utc
        let now = self.clock.now()
        _ = try self.notice(found: now, captures: [now], now: now, calendar: calendar)
        let before = try self.snapshotFiles()
        let later = now.addingTimeInterval(60)
        _ = JournalGapNotice.read(store: self.events, now: later, calendar: calendar)
        let visit = JournalGapVisit()
        visit.foreground(live: [], store: self.events)
        visit.beginNewVisit(live: [], store: self.events)
        visit.foreground(live: [], store: self.events)
        XCTAssertEqual(try self.snapshotFiles(), before)
    }

    func testMissingJournalGapDecodesFalseAndTheOldKeyIsNotAGap() throws {
        let root = self.tempDirectory.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mirror = AppGroupMirror(rootURLProvider: { root })
        let gap = self.snapshot(journalGap: true, backlog: 0, needsAttention: false)
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: gap, sourceKind: .observer), .journalGap)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: gap), .journalGap)
        XCTAssertEqual(ObserverStatusPresentations.circular(snapshot: gap), .journalGap)

        let waiting = self.snapshot(journalGap: true, backlog: 2, needsAttention: false)
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: waiting, sourceKind: .observer), .waiting(count: 2))
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: waiting), .waiting(count: 2))
        XCTAssertEqual(ObserverStatusPresentations.circular(snapshot: waiting), .waiting(count: 2))

        let attention = self.snapshot(journalGap: true, backlog: 0, needsAttention: true)
        XCTAssertEqual(ObserverStatusPresentations.small(snapshot: attention, sourceKind: .observer), .needsAttention)
        XCTAssertEqual(ObserverStatusPresentations.medium(snapshot: attention), .needsAttention)
        XCTAssertEqual(ObserverStatusPresentations.circular(snapshot: attention), .needsAttention)

        guard case .success = mirror.updateSessionAndSources(
            pairing: AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: [.observer: .active],
            backlogCount: 0,
            awaitingMarkConfirmation: false,
            journalGap: true
        ) else {
            return XCTFail("snapshot write failed")
        }
        var stored = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(AppGroupMirror.Snapshot.fileName))) as? [String: Any]
        )
        stored.removeValue(forKey: "journalGap")
        stored["audioInterrupted"] = true
        let decoded = try JSONDecoder().decode(AppGroupMirror.Snapshot.self, from: JSONSerialization.data(withJSONObject: stored))
        XCTAssertFalse(decoded.journalGap)
        XCTAssertNotEqual(ObserverStatusPresentations.medium(snapshot: decoded), .journalGap)
    }

    func testSnapshotIsRewrittenAfterTheLossIsSeen() throws {
        let root = self.tempDirectory.appendingPathComponent("app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let mirror = AppGroupMirror(rootURLProvider: { root })
        let uploader = MobileSegmentUploader(store: self.store, clock: self.clock)
        let now = self.clock.now()
        try uploader.journalEvents.openGate(now: now)
        try uploader.journalEvents.recordLoss(
            segmentID: UUID(),
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: now,
            now: now,
            calendar: Self.utc
        )
        uploader.refreshCounts()
        XCTAssertTrue(uploader.journalGapNotice.isShowing)
        guard case .success = mirror.updateSessionAndSources(
            pairing: AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: [.observer: .active],
            backlogCount: 0,
            awaitingMarkConfirmation: false,
            journalGap: uploader.journalGapNotice.isShowing
        ) else {
            return XCTFail("snapshot write failed")
        }
        XCTAssertEqual(mirror.snapshot()?.journalGap, true)
        let lossID = try XCTUnwrap(uploader.journalGapNotice.lossIDs.first)
        try uploader.journalEvents.markSeen(id: lossID)
        uploader.refreshCounts()
        XCTAssertFalse(uploader.journalGapNotice.isShowing)
        guard case .success = mirror.updateSessionAndSources(
            pairing: AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: [.observer: .active],
            backlogCount: 0,
            awaitingMarkConfirmation: false,
            journalGap: uploader.journalGapNotice.isShowing
        ) else {
            return XCTFail("snapshot rewrite failed")
        }
        XCTAssertEqual(mirror.snapshot()?.journalGap, false)
    }

    // MARK: - Helpers

    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func notice(
        found: Date,
        captures: [Date?],
        now: Date,
        calendar: Calendar
    ) throws -> JournalGapNotice {
        try? FileManager.default.removeItem(at: self.events.rootURL)
        try self.events.openGate(now: found)
        for capture in captures {
            try self.events.recordLoss(
                segmentID: UUID(),
                source: .audio,
                reason: "audio_capture_unfinished",
                captureAt: capture,
                now: found,
                calendar: calendar
            )
        }
        return JournalGapNotice.read(store: self.events, now: now, calendar: calendar)
    }

    private func snapshot(journalGap: Bool, backlog: Int, needsAttention: Bool) -> AppGroupMirror.Snapshot {
        AppGroupMirror.Snapshot(
            schemaVersion: AppGroupMirror.Snapshot.currentSchemaVersion,
            writtenAt: Date(),
            pairing: AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true),
            microphonePermission: .granted,
            session: .notLive,
            sourceStates: [.observer: needsAttention ? .needsAttention : .active],
            backlogCount: backlog,
            awaitingMarkConfirmation: false,
            journalGap: journalGap
        )
    }

    private func snapshotFiles() throws -> [String: Date] {
        guard FileManager.default.fileExists(atPath: self.events.rootURL.path) else { return [:] }
        let urls = FileManager.default.enumerator(at: self.events.rootURL, includingPropertiesForKeys: [.contentModificationDateKey])
        var files: [String: Date] = [:]
        while let url = urls?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            files[url.path] = values.contentModificationDate
        }
        return files
    }
}
