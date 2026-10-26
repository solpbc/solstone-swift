// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// Old errors and old watch endings stop reading as current.
@MainActor
final class StaleStatusTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_199_600)
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suite = "stale-status-\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suite)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suite)
        self.defaults = nil
        super.tearDown()
    }

    // MARK: - transfer errors

    func testAnErrorShowsWithItsAgeForFifteenMinutesThenAgesOut() {
        let status = self.status(errors: [self.t0], delivered: nil)
        let recent = TransferRecentError.evaluate(status, now: self.t0.addingTimeInterval(600))
        XCTAssertEqual(recent?.detail, "boom")
        XCTAssertEqual(recent?.count, 1)
        XCTAssertNil(TransferRecentError.evaluate(status, now: self.t0.addingTimeInterval(960)))

        let row = self.row(recentError: recent)
        let lines = syncStateSummaryLines(rows: [row], now: self.t0.addingTimeInterval(600))
        XCTAssertTrue(lines.contains("  audio recent retry error: boom 10mago (1 recent)"), lines.joined(separator: "\n"))
        let later = syncStateSummaryLines(
            rows: [self.row(recentError: TransferRecentError.evaluate(status, now: self.t0.addingTimeInterval(960)))],
            now: self.t0.addingTimeInterval(960)
        )
        XCTAssertFalse(later.contains { $0.contains("recent retry error") })
    }

    func testADeliveryAtOrAfterAnErrorClearsItAndALaterErrorShows() {
        XCTAssertNil(TransferRecentError.evaluate(
            self.status(errors: [self.t0], delivered: self.t0.addingTimeInterval(60)),
            now: self.t0.addingTimeInterval(120)
        ))
        XCTAssertNil(TransferRecentError.evaluate(
            self.status(errors: [self.t0], delivered: self.t0),
            now: self.t0.addingTimeInterval(120)
        ))
        XCTAssertNotNil(TransferRecentError.evaluate(
            self.status(errors: [self.t0.addingTimeInterval(60)], delivered: self.t0),
            now: self.t0.addingTimeInterval(120)
        ))
    }

    func testTheCountHoldsOnlyErrorsInTheWindowAfterTheLastDelivery() {
        let errors = [self.t0, self.t0.addingTimeInterval(8 * 60), self.t0.addingTimeInterval(14 * 60)]
        let now = self.t0.addingTimeInterval(20 * 60)
        let noDelivery = TransferRecentError.evaluate(self.status(errors: errors, delivered: nil), now: now)
        XCTAssertEqual(noDelivery?.at, self.t0.addingTimeInterval(14 * 60))
        XCTAssertEqual(noDelivery?.count, 2)
        let afterDelivery = TransferRecentError.evaluate(
            self.status(errors: errors, delivered: self.t0.addingTimeInterval(10 * 60)),
            now: now
        )
        XCTAssertEqual(afterDelivery?.count, 1)
    }

    func testAShareStoreErrorAloneShowsNoErrorLine() {
        var status = self.status(errors: [], delivered: nil)
        status.lastErrorDetail = nil
        XCTAssertNil(TransferRecentError.evaluate(status, now: self.t0))
        let lines = syncStateSummaryLines(rows: [self.row(name: "share", recentError: nil)], now: self.t0)
        XCTAssertFalse(lines.contains { $0.contains("recent retry error") })
    }

    func testTheEngineKeepsAnErrorRecentOnlyUntilALaterDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StaleEngine-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = makeTransferCutoverHarness(rootURL: root)
        let key = ObserverAudioTransferSource.watch

        await transfer.engine.noteDelivered(bytes: 10, sourceKey: key, at: Date().addingTimeInterval(-10))
        await transfer.engine.noteError(sourceKey: key, detail: "after the delivery")
        let first = await transfer.engine.snapshot().sources[key]
        var status = try XCTUnwrap(first)
        XCTAssertEqual(TransferRecentError.evaluate(status, now: Date())?.detail, "after the delivery")

        await transfer.engine.noteDelivered(bytes: 10, sourceKey: key, at: Date().addingTimeInterval(1))
        let second = await transfer.engine.snapshot().sources[key]
        status = try XCTUnwrap(second)
        XCTAssertNil(TransferRecentError.evaluate(status, now: Date().addingTimeInterval(2)))
        XCTAssertEqual(status.errorTimesSinceDelivery, [])
    }

    func testTheShareHolderIgnoresTheStoreErrorForRecency() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StaleShare-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = makeTransferCutoverHarness(rootURL: root.appendingPathComponent("Transfers", isDirectory: true))
        let store = ShareImportStore(cacheRootURL: root.appendingPathComponent("Share", isDirectory: true))
        store.lastError = "staging failed"
        let share = ShareTransferHolder(transferEngine: transfer.engine, mirror: transfer.mirror, store: store)
        XCTAssertEqual(share.lastError, "staging failed")
        XCTAssertNil(share.recentError(now: Date()))
    }

    // MARK: - the watch's stopped-itself day

    func testTheDayRunsFromFirstReceiptAcrossRelaunchAndRepublish() {
        let clock = WatchStoppedItselfClock(defaults: self.defaults)
        clock.note(self.stopped(session: "S", asOf: self.t0), receivedAt: self.t0)
        let relaunched = WatchStoppedItselfClock(defaults: self.defaults)
        relaunched.note(
            self.stopped(session: "S", asOf: self.t0.addingTimeInterval(20 * 3_600)),
            receivedAt: self.t0.addingTimeInterval(20 * 3_600)
        )
        let since = WatchStoppedItselfClock.since(
            context: self.stopped(session: "S", asOf: self.t0.addingTimeInterval(20 * 3_600)),
            historyEntries: [],
            record: relaunched.record
        )
        XCTAssertEqual(since, self.t0)
    }

    func testTheHistoryEndWinsAndAnOldPublishTimeBoundsAFirstReceipt() throws {
        let clock = WatchStoppedItselfClock(defaults: self.defaults)
        let old = self.stopped(session: "S", asOf: self.t0.addingTimeInterval(-30 * 3_600))
        clock.note(old, receivedAt: self.t0)
        XCTAssertEqual(WatchStoppedItselfClock.since(context: old, historyEntries: [], record: clock.record), old.asOf)
        XCTAssertEqual(
            watchRecordingStatus(context: old, now: self.t0, lastReceivedAt: nil, stoppedItselfSince: old.asOf),
            .idle
        )
        let entry = try self.historyEntry(session: "S", terminalAt: self.t0.addingTimeInterval(-2 * 3_600))
        XCTAssertEqual(
            WatchStoppedItselfClock.since(context: old, historyEntries: [entry], record: clock.record),
            self.t0.addingTimeInterval(-2 * 3_600)
        )
    }

    func testNilSessionRepublishesKeepTheRecordAndOnlyANewStartClearsIt() {
        let clock = WatchStoppedItselfClock(defaults: self.defaults)
        for hour in [0.0, 10, 20] {
            clock.note(self.stopped(session: nil, asOf: self.t0.addingTimeInterval(hour * 3_600)), receivedAt: self.t0.addingTimeInterval(hour * 3_600))
        }
        XCTAssertEqual(clock.record?.since, self.t0)

        clock.note(self.status(phase: .idle, session: nil), receivedAt: self.t0.addingTimeInterval(21 * 3_600))
        clock.note(nil, receivedAt: self.t0.addingTimeInterval(21 * 3_600))
        XCTAssertEqual(clock.record?.since, self.t0)

        clock.note(self.status(phase: .observing, session: "T"), receivedAt: self.t0.addingTimeInterval(22 * 3_600))
        XCTAssertNil(clock.record)
        clock.note(self.stopped(session: nil, asOf: self.t0.addingTimeInterval(23 * 3_600)), receivedAt: self.t0.addingTimeInterval(23 * 3_600))
        XCTAssertEqual(clock.record?.since, self.t0.addingTimeInterval(23 * 3_600))

        clock.note(self.stopped(session: "U", asOf: self.t0.addingTimeInterval(24 * 3_600)), receivedAt: self.t0.addingTimeInterval(24 * 3_600))
        XCTAssertEqual(clock.record?.sessionID, "U")
    }

    func testAnIdleStatusWithNoSessionBetweenTwoEndingsDoesNotRestartTheDay() {
        let clock = WatchStoppedItselfClock(defaults: self.defaults)
        clock.note(self.stopped(session: "S", asOf: self.t0), receivedAt: self.t0)
        clock.note(self.status(phase: .idle, session: nil), receivedAt: self.t0.addingTimeInterval(3_600))
        clock.note(self.stopped(session: "S", asOf: self.t0.addingTimeInterval(7_200)), receivedAt: self.t0.addingTimeInterval(7_200))
        XCTAssertEqual(clock.record?.since, self.t0)
    }

    // MARK: - one report for copy and share

    func testCopyAndShareGiveTheSameReportBuiltOffTheMainActorWithTheSyncBlock() async throws {
        let log = DiagnosticLog()
        let offMain = OffMainProbe()
        log.reportComposer = { head, store, now in
            offMain.record(Thread.isMainThread)
            return DiagnosticLog.composeReport(head: head, journalEvents: store, now: now)
        }
        let tunnel = TunnelManager()
        let sync = syncStateSummaryLines(rows: [self.row(recentError: nil)], now: self.t0)
        let copied = await log.report(tunnel: tunnel, syncState: sync, now: self.t0)
        let written = await log.exportFile(tunnel: tunnel, syncState: sync, now: self.t0)
        let file = try XCTUnwrap(written)
        let shared = try String(contentsOf: file, encoding: .utf8)

        XCTAssertEqual(copied, shared)
        XCTAssertTrue(copied.contains("--- sync state by source ---"))
        XCTAssertTrue(copied.contains("audio: pending=1"))
        XCTAssertEqual(offMain.calls, [false, false])
    }

    func testTheSyncBlockListsCalendarWithTheCountTheOwnerSees() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StaleStatus-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let transfer = makeTransferCutoverHarness(rootURL: root.appendingPathComponent("Transfers", isDirectory: true))
        let uploader = MobileSegmentUploader(
            transferEngine: transfer.engine,
            store: MobileSegmentStore(rootURL: root.appendingPathComponent("MobileSegment", isDirectory: true))
        )
        let mobile = MobileSegmentTransferHolder(transferEngine: transfer.engine, mirror: transfer.mirror, uploader: uploader)
        let share = ShareTransferHolder(
            transferEngine: transfer.engine,
            mirror: transfer.mirror,
            store: ShareImportStore(cacheRootURL: root.appendingPathComponent("Share", isDirectory: true))
        )
        let calendar = CalendarTransferHolder(transferEngine: transfer.engine, mirror: transfer.mirror)
        calendar.importFilesNotYetQueued = { 2 }

        let withCalendar = await syncStateSummaryLines(
            mobileSegment: mobile, watch: transfer.watch, share: share, calendar: calendar, now: self.t0
        )
        XCTAssertTrue(withCalendar.contains { $0.hasPrefix("calendar: pending=\(calendar.pendingCount) ") }, withCalendar.joined(separator: "\n"))
        XCTAssertEqual(calendar.pendingCount, 2)

        let withoutCalendar = await syncStateSummaryLines(
            mobileSegment: mobile, watch: transfer.watch, share: share, calendar: nil, now: self.t0
        )
        XCTAssertFalse(withoutCalendar.contains { $0.hasPrefix("calendar:") })
    }

    // MARK: - helpers

    private func status(errors: [Date], delivered: Date?) -> TransferSourceStatusSnapshot {
        TransferSourceStatusSnapshot(
            queuedCount: 1,
            attentionCount: 0,
            inFlightCount: 0,
            deliveredCount: 0,
            droppedCount: 0,
            lastDeliveredAt: delivered,
            lastErrorDetail: "boom",
            recentErrorCount: errors.count,
            bytesPerSecond: 0,
            lastErrorAt: errors.last,
            errorTimesSinceDelivery: errors
        )
    }

    private func row(name: String = "audio", recentError: TransferRecentError?) -> SourceSyncStateLine {
        SourceSyncStateLine(
            name: name, pending: 1, inFlight: 0, attention: 0, delivered: 0,
            lastUploadAt: nil, recentError: recentError,
            detail: SourceSyncStateDetail(
                oldestPendingItemCreatedAt: nil,
                mostRecentAttention: nil,
                attentionItemCount: 0,
                mostRecentAttentionRetryCount: 0,
                mostRecentAttentionLastRetriedAt: nil,
                refusedItems: RefusedItemsExport(manifests: [])
            )
        )
    }

    private func stopped(session: String?, asOf: Date) -> WatchStatusContext {
        WatchStatusContext(
            phase: .idle,
            sessionID: session,
            startedAt: nil,
            asOf: asOf,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0,
            confirmingCount: 0,
            confirmingHearBackSeconds: 0,
            audioTerminalReason: .audioInterrupted,
            audioTerminalDisposition: .detectedStoppedItself
        )
    }

    private func status(phase: WatchStatusContext.Phase, session: String?) -> WatchStatusContext {
        WatchStatusContext(
            phase: phase,
            sessionID: session,
            startedAt: nil,
            asOf: self.t0,
            seq: 1,
            queuedCount: 0,
            transferringCount: 0,
            confirmingCount: 0,
            confirmingHearBackSeconds: 0,
            audioTerminalReason: nil,
            audioTerminalDisposition: nil
        )
    }

    private func historyEntry(session: String, terminalAt: Date) throws -> WatchCaptureSessionHistoryEntry {
        WatchCaptureSessionHistoryEntry(
            sessionID: session,
            startedAt: terminalAt.addingTimeInterval(-600),
            terminalAt: terminalAt,
            terminalReason: .audioInterrupted,
            terminalDisposition: .detectedStoppedItself,
            startRefusalReason: nil,
            settingsRoute: nil,
            audioArmed: true,
            audioSessionIsActive: false,
            locationArmed: false,
            segmentsProduced: 1,
            batteryLevelAtEnd: nil,
            batteryStateAtEnd: nil,
            lowPowerModeEnabledAtEnd: nil,
            thermalStateAtEnd: nil,
            lastVerifiedAudioAt: nil,
            lastAudioCurrentTime: nil,
            zeroAudioCurrentTimeObservationCount: nil,
            lastObservedAt: nil,
            locationAdvisory: nil,
            persistenceAdvisory: nil
        )
    }
}

private final class OffMainProbe: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [Bool] = []

    func record(_ isMain: Bool) {
        self.lock.lock()
        self.calls.append(isMain)
        self.lock.unlock()
    }
}
