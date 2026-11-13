// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class SourceIntakeTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceIntakeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.root)
        self.root = nil
        super.tearDown()
    }

    /// A pane on screen reads every source's new total without being opened again, including
    /// one written by another store on the same file, as the share and Safari extensions do.
    func testAnOpenPaneReadsEveryWriteToTheStore() async throws {
        let app = self.store()
        let model = SourceIntakeModel(store: app, showsSample: false)
        let other = SourceIntakeStore(directoryURL: app.directoryURL, timeZone: app.timeZone)
        let now = Date()
        XCTAssertEqual(other.recordImport(itemID: "shared", now: now), .recorded)
        let sawImport = await Self.waitUntil {
            if case .ready(let snapshot) = model.load { return snapshot.imports.total == 1 }
            return false
        }
        XCTAssertTrue(sawImport)
        XCTAssertEqual(app.recordDuration(source: .audio, segmentID: UUID(), duration: 120, now: now), .recorded)
        let sawAudio = await Self.waitUntil {
            if case .ready(let snapshot) = model.load { return snapshot.audio.total == 120 }
            return false
        }
        XCTAssertTrue(sawAudio)
    }

    private static func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func testANewFileRecordsTheLocalDayZerosAndExcludesItselfFromBackup() throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        let store = self.store(timeZone: zone)
        let now = Date(timeIntervalSince1970: 1_794_247_200)
        XCTAssertEqual(store.load(), .ready(.empty))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.intakeFileURL.path))

        XCTAssertEqual(store.recordDuration(source: .audio, segmentID: UUID(), duration: 0.4, now: now), .recorded)
        let snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.started, "2026-11-09")
        XCTAssertEqual(snapshot.audio.total, 0)
        XCTAssertEqual(snapshot.audio.last, now)
        XCTAssertNil(snapshot.screen.last)
        XCTAssertNil(snapshot.location.last)
        XCTAssertNil(snapshot.calendar.last)
        XCTAssertNil(snapshot.safari.last)
        XCTAssertNil(snapshot.watch.last)
        XCTAssertNil(snapshot.imports.last)
        var file = store.intakeFileURL
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAudioAndScreenCountAtTheOutcomeAndAReplayDoesNot() throws {
        let intake = self.store()
        let segments = MobileSegmentStore(rootURL: self.root.appendingPathComponent("segments", isDirectory: true))
        segments.intake = intake
        let segmentID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: now,
            openedWithSources: [.audio, .screencast],
            activeSourceSetVersion: 1
        )
        let directory = try segments.createActive(manifest: manifest)
        try segments.writeOutcome(
            MobileSegmentSourceResolution(state: .noArtifact, durationS: 30, reason: "below_minimum"),
            source: .audio, manifest: &manifest, in: directory, now: now
        )
        try segments.writeOutcome(
            MobileSegmentSourceResolution(state: .failedToFinalize, durationS: 30, reason: "finalize_failed"),
            source: .screencast, manifest: &manifest, in: directory, now: now
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: intake.intakeFileURL.path))

        try segments.writeOutcome(
            MobileSegmentSourceResolution(state: .finalizedArtifact, durationS: 90.9),
            source: .audio, manifest: &manifest, in: directory, now: now
        )
        try segments.writeOutcome(
            MobileSegmentSourceResolution(state: .finalizedArtifact, durationS: 90.9),
            source: .audio, manifest: &manifest, in: directory, now: now.addingTimeInterval(5)
        )
        try segments.writeOutcome(
            MobileSegmentSourceResolution(state: .finalizedArtifact, durationS: 40),
            source: .screencast, manifest: &manifest, in: directory, now: now
        )
        try segments.writeOutcome(
            MobileSegmentSourceResolution(state: .finalizedArtifact, durationS: 12, reason: "location"),
            source: .location, manifest: &manifest, in: directory, now: now
        )
        let snapshot = try self.ready(intake)
        XCTAssertEqual(snapshot.audio.total, 90)
        XCTAssertEqual(snapshot.audio.last, now)
        XCTAssertEqual(snapshot.screen.total, 40)
        XCTAssertNil(snapshot.location.last)
        XCTAssertEqual(snapshot.location.total, 0)
    }

    func testLocationMetresFollowTheCursorAndFloorTheHaversine() throws {
        let store = self.store()
        let first = UUID()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let origin = self.reading(t0, lat: 0, lon: 0, hAcc: 1, fix: true)
        XCTAssertEqual(store.recordLocation(segmentID: first, readings: [origin], now: t0), .recorded)
        var snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.location.total, 0)
        XCTAssertEqual(snapshot.location.last, t0)
        XCTAssertEqual(
            SourceIntakeFormat.distance(0, locale: Locale(identifier: "en_US")),
            "less than a mile"
        )
        XCTAssertNotEqual(
            SourceIntakeFormat.page(lane: snapshot.location, kind: .distance, started: snapshot.started, now: t0, locale: Locale(identifier: "en_US"), calendar: self.utc).soFar,
            "nothing yet"
        )

        let equator = self.reading(t0.addingTimeInterval(10), lat: 1, lon: 0, hAcc: 1, fix: true)
        XCTAssertEqual(store.recordLocation(segmentID: first, readings: [equator], now: t0), .unchanged)
        XCTAssertEqual(store.recordLocation(segmentID: UUID(), readings: [equator], now: t0), .recorded)
        snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.location.total, 111_194)

        let north = self.store()
        XCTAssertEqual(north.recordLocation(segmentID: UUID(), readings: [
            self.reading(t0, lat: 60, lon: 0, hAcc: 1, fix: true),
            self.reading(t0.addingTimeInterval(1), lat: 60, lon: 1, hAcc: 1, fix: false),
        ], now: t0), .recorded)
        XCTAssertEqual(try self.ready(north).location.total, 55_596)

        let swapped = self.store()
        XCTAssertEqual(swapped.recordLocation(segmentID: UUID(), readings: [
            self.reading(t0, lat: 60, lon: 0, hAcc: 1, fix: true),
            self.reading(t0.addingTimeInterval(1), lat: 1, lon: 60, hAcc: 1, fix: true),
        ], now: t0), .recorded)
        XCTAssertNotEqual(try self.ready(swapped).location.total, 55_596)

        let skipped = self.store()
        XCTAssertEqual(skipped.recordLocation(segmentID: UUID(), readings: [
            self.reading(t0, lat: 10, lon: 10, hAcc: 5, fix: true),
        ], now: t0), .recorded)
        XCTAssertEqual(skipped.recordLocation(segmentID: UUID(), readings: [
            self.reading(t0.addingTimeInterval(-5), lat: 11, lon: 10, hAcc: 1, fix: true),
            self.reading(t0.addingTimeInterval(5), lat: 10.01, lon: 10, hAcc: -1, fix: true),
            self.reading(t0.addingTimeInterval(6), lat: 10.0001, lon: 10, hAcc: 50_000, fix: true),
        ], now: t0), .recorded)
        XCTAssertEqual(try self.ready(skipped).location.total, 0)
    }

    func testAFrozenLocationFileReadsBackTheSameReadings() throws {
        let t0 = Date(timeIntervalSince1970: 1_700_000_100)
        let batch = LocationSegmentBatch(
            tier: .balanced,
            accuracy: .full,
            segmentStart: t0,
            coveredSeconds: 30,
            fixes: [LocationFix(t: t0, lat: 0, lon: 0, hAcc: 3, alt: nil, vAcc: nil, speed: nil, course: nil, stationary: false)],
            visits: [LocationVisit(arrival: t0.addingTimeInterval(20), departure: nil, lat: 1, lon: 0, hAcc: 4)],
            gap: false
        )
        let frozen = try MobileSegmentLocationWriter.freeze(batch)
        let readings = MobileSegmentLocationWriter.intakeReadings(from: frozen.data)
        XCTAssertEqual(readings.map(\.isFix), [true, false])
        XCTAssertEqual(readings.map(\.latitude), [0, 1])
        let store = self.store()
        XCTAssertEqual(store.recordLocation(segmentID: UUID(), readings: readings, now: t0), .recorded)
        XCTAssertEqual(try self.ready(store).location.total, 111_194)
    }

    func testRecordLocationFinalizedCountsAndAnEmptyBatchDoesNot() throws {
        let intake = self.store()
        let segments = MobileSegmentStore(rootURL: self.root.appendingPathComponent("segments", isDirectory: true))
        segments.intake = intake
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_700_000_200))
        let transfer = makeTransferCutoverHarness(rootURL: self.root.appendingPathComponent("transfer", isDirectory: true))
        let uploader = MobileSegmentUploader(transferEngine: transfer.engine, store: segments, clock: clock)
        let emptyID = UUID()
        var empty = MobileSegmentManifest(
            segmentID: emptyID, startedAt: clock.now(), openedWithSources: [.location], activeSourceSetVersion: 1
        )
        _ = try segments.createActive(manifest: empty)
        try uploader.recordLocationFinalized(
            segmentID: emptyID,
            batch: LocationSegmentBatch(
                tier: .light, accuracy: .reduced, segmentStart: clock.now(), coveredSeconds: 0,
                fixes: [], visits: [], gap: false
            ),
            endedAt: clock.now(),
            reason: nil
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: intake.intakeFileURL.path))

        let keptID = UUID()
        var kept = MobileSegmentManifest(
            segmentID: keptID, startedAt: clock.now(), openedWithSources: [.location], activeSourceSetVersion: 1
        )
        _ = try segments.createActive(manifest: kept)
        try uploader.recordLocationFinalized(
            segmentID: keptID,
            batch: LocationSegmentBatch(
                tier: .balanced, accuracy: .full, segmentStart: clock.now(), coveredSeconds: 5,
                fixes: [LocationFix(t: clock.now(), lat: 0, lon: 0, hAcc: 5, alt: nil, vAcc: nil, speed: nil, course: nil, stationary: true)],
                visits: [], gap: false
            ),
            endedAt: clock.now(),
            reason: nil
        )
        XCTAssertEqual(try self.ready(intake).location.last, clock.now())
        XCTAssertEqual(try self.ready(intake).location.total, 0)
    }

    func testGarbageJsonIsLeftInPlaceAndTheOutcomeStillCommits() throws {
        let intake = self.store()
        let now = Date(timeIntervalSince1970: 1_700_000_300)
        XCTAssertEqual(intake.recordDuration(source: .audio, segmentID: UUID(), duration: 5, now: now), .recorded)
        try Data("not-json".utf8).write(to: intake.intakeFileURL)
        let segments = MobileSegmentStore(rootURL: self.root.appendingPathComponent("segments", isDirectory: true))
        segments.intake = intake
        let segmentID = UUID()
        var manifest = MobileSegmentManifest(
            segmentID: segmentID, startedAt: now, openedWithSources: [.audio], activeSourceSetVersion: 1
        )
        let directory = try segments.createActive(manifest: manifest)
        try segments.writeOutcome(
            MobileSegmentSourceResolution(state: .finalizedArtifact, durationS: 8),
            source: .audio, manifest: &manifest, in: directory, now: now
        )
        XCTAssertEqual(try Data(contentsOf: intake.intakeFileURL), Data("not-json".utf8))
        XCTAssertEqual(intake.load(), .unreadable)
        let model = SourceIntakeModel(store: intake, showsSample: false)
        XCTAssertNil(model.statusRows(includeSafari: true, includeWatch: true, locale: Locale(identifier: "en_US"), calendar: self.utc))
        XCTAssertNil(model.pageFacts(source: .audio, locale: Locale(identifier: "en_US"), calendar: self.utc))
    }

    func testABadLastStampIsUnreadableAndIsNotRewritten() throws {
        let store = self.store()
        let now = Date(timeIntervalSince1970: 1_700_000_400)
        XCTAssertEqual(store.recordDuration(source: .audio, segmentID: UUID(), duration: 5, now: now), .recorded)
        var text = try String(contentsOf: store.intakeFileURL, encoding: .utf8)
        text = text.replacingOccurrences(of: store.stampForTest(now), with: "not-a-time")
        try Data(text.utf8).write(to: store.intakeFileURL)
        let before = try Data(contentsOf: store.intakeFileURL)
        XCTAssertEqual(store.load(), .unreadable)
        XCTAssertEqual(store.recordDuration(source: .audio, segmentID: UUID(), duration: 5, now: now), .skipped)
        XCTAssertEqual(try Data(contentsOf: store.intakeFileURL), before)
    }

    func testTheLockFileInodeSurvivesACount() throws {
        let store = self.store()
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        XCTAssertEqual(store.recordImport(itemID: "one", now: now), .recorded)
        let inode = try XCTUnwrap(store.lockFileInode())
        XCTAssertEqual(store.recordImport(itemID: "two", now: now), .recorded)
        XCTAssertEqual(store.lockFileInode(), inode)
        XCTAssertEqual(store.recordImport(itemID: "one", now: now), .unchanged)
    }

    func testImportCountsOnceAtTheMoveAndASecondCommitAddsNothing() throws {
        let intake = self.store()
        let queue = ShareImportStore(cacheRootURL: self.root.appendingPathComponent("queue", isDirectory: true), now: { Date(timeIntervalSince1970: 1_700_000_600) })
        queue.intake = intake
        let handle = try queue.beginEnqueue()
        let delivery = ShareFileDelivery(byteCount: 4, itemTime: Date(timeIntervalSince1970: 1_700_000_600), basis: "sent", contentType: "text/plain", filename: "note.txt")
        _ = try queue.commitEnqueue(handle: handle, delivery: delivery, source: "document", targetJournal: "", originApp: nil)
        XCTAssertEqual(try self.ready(intake).imports.total, 1)
        XCTAssertThrowsError(try queue.commitEnqueue(handle: handle, delivery: delivery, source: "document", targetJournal: "", originApp: nil))
        XCTAssertEqual(try self.ready(intake).imports.total, 1)
        queue.abortEnqueue(handle)
        XCTAssertEqual(try self.ready(intake).imports.total, 1)
    }

    func testWatchCountsARecordingOnceAndLostOrZeroDoNotStampLast() async throws {
        let intake = self.store()
        let staging = self.root.appendingPathComponent("watch", isDirectory: true)
        let session = MockWatchConnectivitySession()
        let ledger = WatchSegmentLedger(fileURL: self.root.appendingPathComponent("ledger.json"))
        let receiver = try WatchRelayReceiver(session: session, ledger: ledger, stagingRootURL: staging, facts: self.watchFacts())
        receiver.intake = intake
        let counted = UUID()
        try await self.receive(receiver, id: counted, duration: 90.8, partial: false, lost: false)
        try await self.receive(receiver, id: counted, duration: 90.8, partial: false, lost: false)
        XCTAssertEqual(try self.ready(intake).watch.total, 90)
        XCTAssertNotNil(try self.ready(intake).watch.last)
        XCTAssertEqual(ledger.lifetimeReceived, 1)

        let partial = UUID()
        try await self.receive(receiver, id: partial, duration: 10, partial: true, lost: false)
        XCTAssertEqual(try self.ready(intake).watch.total, 100)

        let lost = UUID()
        let last = try self.ready(intake).watch.last
        try await self.receive(receiver, id: lost, duration: 40, partial: false, lost: true)
        XCTAssertEqual(try self.ready(intake).watch.total, 100)
        XCTAssertEqual(try self.ready(intake).watch.last, last)

        let zero = UUID()
        try await self.receive(receiver, id: zero, duration: 0, partial: false, lost: false)
        XCTAssertEqual(try self.ready(intake).watch.last, last)
        try await self.receive(receiver, id: UUID(), duration: 5, partial: false, lost: false, manifest: Data("nope".utf8))
        XCTAssertEqual(try self.ready(intake).watch.total, 100)
    }

    func testRelativeBoundariesAndDurationHours() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 8))!
        XCTAssertEqual(SourceIntakeFormat.relative(now.addingTimeInterval(-59), now: now, calendar: calendar), "just now")
        XCTAssertEqual(SourceIntakeFormat.relative(now.addingTimeInterval(-60), now: now, calendar: calendar), "1 min ago")
        XCTAssertEqual(SourceIntakeFormat.relative(now.addingTimeInterval(-3_600), now: now, calendar: calendar), "1 hour ago")
        XCTAssertEqual(SourceIntakeFormat.relative(now.addingTimeInterval(-10 * 3_600), now: now, calendar: calendar), "10 hours ago")
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 7))!
        XCTAssertEqual(SourceIntakeFormat.relative(yesterday, now: now, calendar: calendar), "yesterday")
        let older = calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 8))!
        let olderText = SourceIntakeFormat.relative(older, now: now, calendar: calendar)
        XCTAssertFalse(olderText.contains("days ago"))
        XCTAssertFalse(olderText.contains("minute ago"))
        XCTAssertEqual(SourceIntakeFormat.duration(5_400, locale: Locale(identifier: "en_US")), "1 hour")
        XCTAssertEqual(SourceIntakeFormat.duration(60, locale: Locale(identifier: "en_US")), "1 minute")
        var metricBritain = Locale.Components(identifier: "en_GB")
        metricBritain.measurementSystem = .metric
        XCTAssertEqual(SourceIntakeFormat.distance(1_000, locale: Locale(components: metricBritain)), "1 kilometer")
        var milesBritain = Locale.Components(identifier: "en_GB")
        milesBritain.measurementSystem = .uk
        XCTAssertEqual(SourceIntakeFormat.distance(1_000, locale: Locale(components: milesBritain)), "less than a mile")
        XCTAssertEqual(SourceIntakeFormat.distance(2_000, locale: Locale(identifier: "fr_FR")), "2 kilometers")
        XCTAssertEqual(SourceIntakeFormat.started("2026-03-03", now: now, calendar: calendar), "march 3")
        XCTAssertEqual(SourceIntakeFormat.started("2025-03-03", now: now, calendar: calendar), "march 3, 2025")
    }

    func testStatusRowsUseTheBareTotalAndOmitADeckThePaneDoesNotShow() {
        let now = Date(timeIntervalSince1970: 1_794_247_200)
        let snapshot = SourceIntakeSample.snapshot(now: now)
        let calendar = self.utc
        let locale = Locale(identifier: "en_US")
        let rows = SourceIntakeRows.statusRows(
            snapshot: snapshot, includeSafari: false, includeWatch: false, now: now, locale: locale, calendar: calendar
        )
        XCTAssertEqual(rows.map(\.id), ["audio", "location", "screen", "calendar", "screenshots", "obsidian", "imports"])
        XCTAssertEqual(rows[0].soFar, "1 hour")
        XCTAssertFalse(rows[0].soFar.contains("since"))
        XCTAssertEqual(rows[0].last, "10 min ago")
        XCTAssertEqual(rows[0].name, "audio")
        XCTAssertEqual(rows[2].name, "screen")
        XCTAssertEqual(rows[4].destination, .source(.screenshots))
        XCTAssertEqual(rows[5].destination, .source(.obsidian))
        XCTAssertEqual(rows[6].destination, ShellDestination.import)
        let empty = SourceIntakeRows.statusRows(
            snapshot: .empty, includeSafari: true, includeWatch: true, now: now, locale: locale, calendar: calendar
        )
        XCTAssertEqual(empty.map(\.id), ["audio", "location", "screen", "calendar", "safari", "watch", "screenshots", "obsidian", "imports"])
        XCTAssertTrue(empty.allSatisfy { $0.soFar == "nothing yet" && $0.last == "nothing yet" })
        let page = SourceIntakeFormat.page(lane: snapshot.audio, kind: .duration, started: snapshot.started, now: now, locale: locale, calendar: calendar)
        XCTAssertEqual(page.soFar, "1 hour, since march 3")
        XCTAssertEqual(page.lastTakenIn, "10 min ago")
        let quiet = SourceIntakeFormat.page(lane: .init(total: 0, last: nil), kind: .duration, started: snapshot.started, now: now, locale: locale, calendar: calendar)
        XCTAssertEqual(quiet.soFar, "nothing yet")
        XCTAssertNil(quiet.lastTakenIn)
    }

    func testSampleModeDoesNotWrite() {
        let store = self.store()
        let model = SourceIntakeModel(store: store, showsSample: true)
        model.reload()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.intakeFileURL.path))
        XCTAssertEqual(model.pageFacts(source: .calendar, locale: Locale(identifier: "en_US"), calendar: self.utc)?.soFar, "1 event, since march 3")
    }

    func testCalendarCountsAFlaggedIdentityOnceWhenTheBaselineLands() async throws {
        let harness = CalendarSourceEngineTests.harness()
        let intake = self.store()
        harness.intake = intake
        harness.rebuild()
        intake.testFailNextReplace = true
        await harness.ensureLaunched()
        XCTAssertFalse(FileManager.default.fileExists(atPath: intake.intakeFileURL.path))
        XCTAssertEqual(harness.engine.document.intakeBaselineImportIDs?.isEmpty, true)

        XCTAssertEqual(intake.recordImport(itemID: "brought-in", now: harness.now), .recorded)
        XCTAssertEqual(intake.calendarLedger()?.events, 0)
        XCTAssertEqual(intake.calendarLedger()?.seeded, false)
        harness.provider.events = [CalendarSourceEngineTests.meeting(
            "NEW-1", title: "planning", CalendarFixtures.at(2026, 10, 28, 14, 0), lastModified: "2026-10-15T10:00:00-06:00"
        )]
        await harness.engine.setUp(span: .last30Days, calendarIDs: harness.everyCalendar)
        await harness.engine.confirm()
        XCTAssertEqual(self.calendarEvents(intake), 0)
        XCTAssertTrue(harness.store.record.values.contains { $0.intakePending == true })

        await harness.relaunch()
        XCTAssertEqual(self.calendarEvents(intake), 1)
        XCTAssertFalse(harness.store.record.values.contains { $0.intakePending == true })
        await harness.relaunch()
        XCTAssertEqual(self.calendarEvents(intake), 1)

        let row = SourceIntakeRows.statusRows(
            snapshot: try self.ready(intake), includeSafari: false, includeWatch: false,
            now: harness.now, locale: Locale(identifier: "en_US"), calendar: self.utc
        ).first { $0.id == "calendar" }
        XCTAssertEqual(row?.soFar, "1 event")
        XCTAssertFalse(row?.soFar.contains("since") == true)
        XCTAssertEqual(row?.last, "just now")
    }

    func testCalendarCountsAtThePumpOnceItIsSeededAndARelaunchLeavesTheTotal() async throws {
        let harness = CalendarSourceEngineTests.harness()
        let intake = self.store()
        harness.intake = intake
        harness.rebuild()
        await harness.ensureLaunched()
        XCTAssertEqual(intake.calendarLedger()?.seeded, true)
        XCTAssertEqual(self.calendarEvents(intake), 0)

        let event = CalendarSourceEngineTests.meeting(
            "ONCE-1", title: "planning", CalendarFixtures.at(2026, 10, 28, 14, 0), lastModified: "2026-10-15T10:00:00-06:00"
        )
        harness.provider.events = [event]
        await harness.engine.setUp(span: .last30Days, calendarIDs: harness.everyCalendar)
        XCTAssertEqual(self.calendarEvents(intake), 0, "setup does not take an event in")
        await harness.engine.confirm()
        XCTAssertEqual(self.calendarEvents(intake), 1)

        harness.provider.events[0].title = "planning, moved room"
        harness.provider.events[0].lastModified = harness.now
        harness.advance(minutes: 5)
        await harness.check()
        XCTAssertEqual(self.calendarEvents(intake), 1)

        harness.provider.events = []
        harness.advance(minutes: 1)
        await harness.check()
        harness.advance(minutes: 10)
        await harness.check()
        XCTAssertEqual(self.calendarEvents(intake), 1, "a removal does not subtract")

        harness.provider.events = [event]
        harness.advance(minutes: 5)
        await harness.check()
        XCTAssertEqual(self.calendarEvents(intake), 1, "a re-add does not count again")
        await harness.relaunch()
        XCTAssertEqual(self.calendarEvents(intake), 1)
    }

    func testCalendarHistoryAndABaselineFreezeAddNothing() async throws {
        let sent = CalendarSourceEngineTests.harness()
        sent.provider.events = [CalendarSourceEngineTests.meeting(
            "SENT-1", title: "review", CalendarFixtures.at(2026, 10, 26, 9, 0), lastModified: "2026-10-18T12:00:00-06:00"
        )]
        await sent.setUpAndConfirm()
        let intake = self.store()
        sent.intake = intake
        sent.rebuild()
        await sent.ensureLaunched()
        XCTAssertEqual(self.calendarEvents(intake), 0)
        XCTAssertNotNil(sent.engine.document.intakeBaselineImportIDs)
        let delivered = sent.delivery.lines.count
        sent.provider.events[0].title = "review, new room"
        sent.provider.events[0].lastModified = sent.now
        sent.advance(minutes: 5)
        await sent.check()
        XCTAssertGreaterThan(sent.delivery.lines.count, delivered)
        XCTAssertEqual(self.calendarEvents(intake), 0)

        let frozen = CalendarSourceEngineTests.harness()
        frozen.provider.events = [CalendarSourceEngineTests.meeting(
            "FROZEN-1", title: "offsite", CalendarFixtures.at(2026, 10, 27, 9, 0), lastModified: "2026-10-12T07:00:00-06:00"
        )]
        await frozen.ensureLaunched()
        await frozen.engine.setUp(span: .last30Days, calendarIDs: frozen.everyCalendar)
        frozen.engine.pause()
        await frozen.engine.confirm()
        let importID = try XCTUnwrap(frozen.engine.document.imports.first(where: \.confirmed)?.id)
        let keys = await frozen.engine.worker.frozenIdentityKeys(importID: importID)
        let key = try XCTUnwrap(keys.first)
        try? FileManager.default.removeItem(at: frozen.store.recordURL)
        try? FileManager.default.removeItem(at: frozen.store.recordJournalURL)
        let baseline = self.store()
        frozen.intake = baseline
        frozen.rebuild()
        await frozen.ensureLaunched()
        let ledger = try XCTUnwrap(baseline.calendarLedger())
        XCTAssertEqual(ledger.events, 0)
        XCTAssertTrue(ledger.seen.contains(key))
        XCTAssertEqual(frozen.engine.document.intakeBaselineImportIDs, [importID])
        await frozen.engine.resume()
        XCTAssertEqual(self.calendarEvents(baseline), 0)
        frozen.provider.events[0].title = "offsite, confirmed"
        frozen.provider.events[0].lastModified = frozen.now
        frozen.advance(minutes: 5)
        await frozen.check()
        XCTAssertEqual(self.calendarEvents(baseline), 0)
    }

    func testAFailedCalendarIncrementAddsOnTheNextSuccess() throws {
        let store = self.store()
        let now = Date(timeIntervalSince1970: 1_700_000_700)
        XCTAssertEqual(store.seedCalendar(history: [], pending: ["a", "b", "c", "d"], now: now), .recorded)
        XCTAssertEqual(store.calendarLedger()?.events, 4)
        store.testFailNextReplace = true
        XCTAssertEqual(store.recordCalendarNew(keys: ["e", "f"], now: now), .failed)
        XCTAssertEqual(store.calendarLedger()?.events, 4)
        XCTAssertEqual(store.recordCalendarNew(keys: ["e", "f"], now: now), .recorded)
        XCTAssertEqual(store.calendarLedger()?.events, 6)
    }

    func testAnOldCalendarEntryWithoutTheIntakeKeyStillLoads() throws {
        let stored = #"{"a":1700000000,"c":1700000000,"e":"MEET","h":["cal-work"],"k":"Work","r":false,"t":"planning"}"#
        let entry = try JSONDecoder().decode(CalendarSentEntry.self, from: Data(stored.utf8))
        XCTAssertTrue(entry.wasSent)
        XCTAssertNil(entry.intakePending)
        XCTAssertEqual(entry.event, "MEET")
        XCTAssertFalse(entry.removed)

        var quiet = CalendarSentEntry(identity: CalendarIdentity(event: "QUIET", occurrence: nil))
        let omitted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quiet)) as? [String: Any]
        XCTAssertNil(omitted?["i"])
        quiet.intakePending = true
        let flagged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(quiet)) as? [String: Any]
        XCTAssertEqual(flagged?["i"] as? Bool, true)
    }

    func testSafariCountsAUrlChangeAndNotAReplayOrAHandoff() throws {
        let (browser, projection, intake) = try self.safari()
        let generation = try self.safariGeneration(browser, projection)
        let missing = try self.safariBatch(generation: generation, id: self.safariID("a"), url: nil)
        _ = try browser.exchange(connection: "c1", frame: missing, projection: projection)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intake.intakeFileURL.path))

        let first = try self.safariBatch(generation: generation, id: self.safariID("b"), url: "https://example.test/one")
        let accepted = try browser.exchange(connection: "c1", frame: first, projection: projection)
        XCTAssertEqual(try self.object(accepted[0])["result"] as? String, "accepted")
        XCTAssertEqual(try self.ready(intake).safari.total, 1)
        let state = try self.object(XCTUnwrap(accepted.last))
        XCTAssertNil(state["pages"])
        XCTAssertNil(state["total"])

        let duplicate = try browser.exchange(connection: "c1", frame: first, projection: projection)
        XCTAssertEqual(try self.object(duplicate[0])["result"] as? String, "duplicate")
        XCTAssertEqual(try self.ready(intake).safari.total, 1)

        _ = try browser.exchange(connection: "c1", frame: try self.safariBatch(
            generation: generation, id: self.safariID("c"), url: "https://example.test/one"
        ), projection: projection)
        XCTAssertEqual(try self.ready(intake).safari.total, 1)

        _ = try browser.exchange(connection: "c1", frame: try self.safariBatch(
            generation: generation, id: self.safariID("d"), url: "https://example.test/two"
        ), projection: projection)
        XCTAssertEqual(try self.ready(intake).safari.total, 2)

        _ = try browser.exchange(connection: "c1", frame: try self.safariBatch(
            generation: generation, id: self.safariID("e"), url: "https://example.test/one"
        ), projection: projection)
        XCTAssertEqual(try self.ready(intake).safari.total, 3)

        _ = try browser.exchange(connection: "c1", frame: try self.safariBatch(
            generation: generation, id: self.safariID("f"), url: "https://example.test/one", ctx: "other-tab"
        ), projection: projection)
        XCTAssertEqual(try self.ready(intake).safari.total, 4)

        _ = try browser.exchange(connection: "c2", frame: self.safariHello("inst-b"), projection: projection)
        _ = try browser.exchange(connection: "c2", frame: try self.safariBatch(
            generation: generation, id: self.safariID("g"), url: "https://example.test/one", inst: "inst-b"
        ), projection: projection)
        XCTAssertEqual(try self.ready(intake).safari.total, 5)

        _ = try browser.exchange(connection: "c1", frame: try self.safariBatch(
            generation: generation, id: self.safariID("h"), url: nil, delta: true
        ), projection: projection)
        XCTAssertEqual(try self.ready(intake).safari.total, 5)

        let rejected = try browser.exchange(connection: "c1", frame: try self.safariBatch(
            generation: UUID().uuidString, id: self.safariID("i"), url: "https://example.test/three"
        ), projection: projection)
        XCTAssertEqual(try self.object(rejected[0])["result"] as? String, "rejected")
        XCTAssertEqual(try self.ready(intake).safari.total, 5)

        let periods = try browser.prepareHandoffs()
        XCTAssertFalse(periods.isEmpty)
        for period in periods {
            try browser.adopt(id: period.id)
        }
        XCTAssertEqual(try self.ready(intake).safari.total, 5)
    }

    func testSafariRollsTheBatchBackWhenTheCountCannotTakeTheLock() throws {
        let (browser, projection, intake) = try self.safari()
        let generation = try self.safariGeneration(browser, projection)
        let frame = try self.safariBatch(generation: generation, id: self.safariID("z"), url: "https://example.test/locked")
        intake.testLockTimeout = true
        XCTAssertThrowsError(try browser.exchange(connection: "c1", frame: frame, projection: projection)) { error in
            XCTAssertEqual(error as? SourceIntakeError, .lockTimeout)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: intake.intakeFileURL.path))
        let retry = try browser.exchange(connection: "c1", frame: frame, projection: projection)
        XCTAssertEqual(try self.object(retry[0])["result"] as? String, "accepted")
        XCTAssertEqual(try self.ready(intake).safari.total, 1)
    }

    func testTheClearPathsDoNotReferenceTheCounter() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let files = [
            "Sources/Services/AppConfig.swift",
            "Sources/Services/AppGroupMirror.swift",
            "Sources/Pairing/JournalMarkStore.swift",
            "Sources/Home/DayHomeView.swift",
        ]
        for relative in files {
            let text = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            XCTAssertFalse(text.contains("SourceIntake"), relative)
            XCTAssertFalse(text.contains("intake.json"), relative)
        }
        let diagnostics = root.appendingPathComponent("Sources/Diagnostics", isDirectory: true)
        if let enumerator = FileManager.default.enumerator(at: diagnostics, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(text.contains("SourceIntake"), url.path)
                XCTAssertFalse(text.contains("intake.json"), url.path)
            }
        }
        let collector = try String(contentsOf: root.appendingPathComponent("Sources/WatchCapture/WatchRelayDiagnosticsCollector.swift"), encoding: .utf8)
        XCTAssertFalse(collector.contains("SourceIntake"))
        let pane = try String(contentsOf: root.appendingPathComponent("Sources/Home/StatusPane.swift"), encoding: .utf8)
        let content = pane.split(separator: "private var paneContent", maxSplits: 1).last.map(String.init) ?? ""
        let waiting = try XCTUnwrap(content.range(of: "self.whatIsWaitingSection"))
        let intake = try XCTUnwrap(content.range(of: "self.intakeSection"))
        let door = try XCTUnwrap(content.range(of: "if !self.appConfig.isPaired"))
        XCTAssertLessThan(waiting.lowerBound, intake.lowerBound)
        XCTAssertLessThan(intake.lowerBound, door.lowerBound)
        XCTAssertTrue(pane.contains("A row carries no number"))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func store(timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> SourceIntakeStore {
        SourceIntakeStore(directoryURL: self.root.appendingPathComponent("intake-\(UUID().uuidString)", isDirectory: true), timeZone: timeZone)
    }

    private func ready(_ store: SourceIntakeStore) throws -> SourceIntakeSnapshot {
        guard case .ready(let snapshot) = store.load() else {
            XCTFail("intake file was not readable")
            return .empty
        }
        return snapshot
    }

    private func reading(_ time: Date, lat: Double, lon: Double, hAcc: Double, fix: Bool) -> SourceIntakeReading {
        SourceIntakeReading(time: time, latitude: lat, longitude: lon, horizontalAccuracy: hAcc, isFix: fix)
    }

    private func watchFacts() -> WatchSourceFacts {
        let suite = "SourceIntakeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WatchSourceFacts(defaults: defaults)
    }

    private func calendarEvents(_ store: SourceIntakeStore) -> Int {
        store.calendarLedger()?.events ?? 0
    }

    private func safari() throws -> (SafariBrowserStore, BrowserContractProjection, SourceIntakeStore) {
        let root = self.root.appendingPathComponent("safari-\(UUID().uuidString)", isDirectory: true)
        let vendor = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("browser-contract")
        let projection = try BrowserContractProjection(rootURL: vendor)
        let browser = try SafariBrowserStore(root: root)
        let intake = self.store()
        browser.intake = intake
        try browser.setConfirmed(true)
        return (browser, projection, intake)
    }

    private func safariHello(_ inst: String) -> String {
        "{\"type\":\"hello\",\"protocol\":1,\"version\":\"0.4.0\",\"brand\":\"safari\",\"inst\":\"\(inst)\"}"
    }

    private func safariGeneration(_ browser: SafariBrowserStore, _ projection: BrowserContractProjection) throws -> String {
        let frames = try browser.exchange(connection: "c1", frame: self.safariHello("inst-a"), projection: projection)
        return try XCTUnwrap(self.object(XCTUnwrap(frames.last))["destination_generation"] as? String)
    }

    private func safariID(_ name: String) -> String {
        let encoded = name.unicodeScalars.map { String(format: "%02x", $0.value) }.joined()
        return encoded.padding(toLength: 32, withPad: "0", startingAt: 0)
    }

    private func safariBatch(generation: String, id: String, url: String?, ctx: String = "context", inst: String = "inst-a", delta: Bool = false) throws -> String {
        let record: [String: Any]
        if delta {
            record = ["t": "delta", "ts": 2000, "ctx": ctx, "inst": inst, "site": "example.test",
                      "op": "add", "block": ["id": "c", "text": "synthetic marker"]]
        } else {
            var started: [String: Any] = ["t": "segment_start", "ts": 1000, "ctx": ctx, "inst": inst,
                "n": 1, "blocks": [["id": "b", "text": "synthetic marker"]],
                "site": "example.test", "adapter": "generic", "title": "synthetic"]
            if let url { started["url"] = url }
            record = started
        }
        let value: [String: Any] = ["type": "batch", "destination_generation": generation,
            "inst": inst, "batch_id": id, "queued_at_ms": 1000, "records": [record]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func object(_ frame: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
    }

    private func receive(
        _ receiver: WatchRelayReceiver,
        id: UUID,
        duration: Double,
        partial: Bool,
        lost: Bool,
        manifest: Data? = nil
    ) async throws {
        let manifest = try manifest ?? {
            let value = WatchSegmentManifest(
                id: id, day: "20261109", segment: "180000_90", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                duration: duration, sensors: [.audio], partial: partial, lost: lost, gap: false, fixCount: 0, state: .captured
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(value)
        }()
        let bundle = try PropertyListSerialization.data(
            fromPropertyList: [WatchSegmentBundleCodec.manifestFilename: manifest], format: .binary, options: 0
        )
        let scratch = self.root.appendingPathComponent("scratch-\(UUID().uuidString)")
        try bundle.write(to: scratch)
        await receiver.receiveFile(scratch, metadata: ["id": id.uuidString])
    }

    func testObsidianLaneDecodingMissingKeyIsZero() throws {
        let store = SourceIntakeStore(directoryURL: self.root)
        let snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.obsidian.total, 0)
        XCTAssertNil(snapshot.obsidian.last)
    }

    func testObsidianLaneMalformedStaysUnreadable() throws {
        let store = SourceIntakeStore(directoryURL: self.root)
        let malformedJSON = "{\"version\":1,\"obsidian\":\"not-an-object\"}"
        try malformedJSON.write(to: store.intakeFileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(store.load(), .unreadable)
        let bytesOnDisk = try String(contentsOf: store.intakeFileURL, encoding: .utf8)
        XCTAssertEqual(bytesOnDisk, malformedJSON)
    }

    func testObsidianSeedingAndNewNotes() throws {
        let store = SourceIntakeStore(directoryURL: self.root)
        let vaultID = "vault-1"
        store.seedObsidianVault(vaultID: vaultID, seenHashes: ["h1", "h2", "h3", "h4", "h5"])
        var snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.obsidian.total, 0)

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(store.recordObsidianNew(vaultID: vaultID, seenHash: "h1", now: t1), .unchanged)
        snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.obsidian.total, 0)

        XCTAssertEqual(store.recordObsidianNew(vaultID: vaultID, seenHash: "h6", now: t1), .recorded)
        snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.obsidian.total, 1)

        XCTAssertEqual(store.recordObsidianNew(vaultID: vaultID, seenHash: "h6", now: t1), .unchanged)
        snapshot = try self.ready(store)
        XCTAssertEqual(snapshot.obsidian.total, 1)
    }
}

private extension SourceIntakeStore {
    func stampForTest(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
