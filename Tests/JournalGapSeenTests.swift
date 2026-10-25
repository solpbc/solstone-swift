// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// A visit marks the losses on screen. A later loss waits for the next visit.
@MainActor
final class JournalGapSeenTests: XCTestCase {
    private var tempDirectory: URL!
    private var events: JournalEventStore!
    private let now = Date(timeIntervalSince1970: 1_793_199_600)

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalGapSeen-\(UUID().uuidString)", isDirectory: true)
        let root = self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        self.events = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: root))
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        try self.events.openGate(now: self.now)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.events = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testVisitMarksExactlyTheLossesOnScreen() throws {
        let first = try self.recordLoss()
        let second = try self.recordLoss()
        let live = try self.live()
        let visit = JournalGapVisit()
        visit.beginNewVisit(live: live, store: self.events)
        XCTAssertEqual(Set(visit.captured.map(\.id)), [first, second])
        XCTAssertTrue(self.events.isSeen(id: first))
        XCTAssertTrue(self.events.isSeen(id: second))
        XCTAssertEqual(Set(visit.displayed(live: live).map(\.id)), [first, second])
        XCTAssertTrue(try self.live().isEmpty)
    }

    func testLossWrittenDuringTheVisitStaysUnseenUntilTheNextVisit() throws {
        let shown = try self.recordLoss()
        let visit = JournalGapVisit()
        visit.beginNewVisit(live: try self.live(), store: self.events)
        let arrived = try self.recordLoss()
        XCTAssertFalse(self.events.isSeen(id: arrived))
        XCTAssertTrue(self.events.isSeen(id: shown))
        let live = try self.live()
        XCTAssertEqual(live.map(\.id), [arrived])
        XCTAssertEqual(Set(visit.displayed(live: live).map(\.id)), [shown, arrived])

        visit.beginNewVisit(live: live, store: self.events)
        XCTAssertTrue(self.events.isSeen(id: arrived))
        XCTAssertTrue(try self.live().isEmpty)
        XCTAssertEqual(visit.displayed(live: []).map(\.id), [arrived])
        XCTAssertEqual(visit.captured.map(\.id), [arrived])
    }

    func testVisitBeforeTheGateMarksNothing() throws {
        try? FileManager.default.removeItem(at: self.events.rootURL)
        let segmentID = UUID()
        let id = try self.writeLossFile(segmentID: segmentID)
        let visit = JournalGapVisit()
        let before = JournalGapNotice.read(store: self.events, now: self.now)
        XCTAssertEqual(before, .absent)
        visit.beginNewVisit(live: before.losses, store: self.events)
        XCTAssertTrue(visit.didCapture)
        XCTAssertFalse(self.events.isSeen(id: id))

        try self.events.openGate(now: self.now)
        let live = try self.live()
        XCTAssertEqual(live.map(\.id), [id])
        XCTAssertFalse(self.events.isSeen(id: id))
        XCTAssertEqual(visit.displayed(live: live).map(\.id), [id])
        visit.beginNewVisit(live: live, store: self.events)
        XCTAssertTrue(self.events.isSeen(id: id))
    }

    func testEmptyVisitShowsALaterLossWithoutMarkingIt() throws {
        let visit = JournalGapVisit()
        visit.foreground(live: [], store: self.events)
        XCTAssertTrue(visit.didCapture)
        XCTAssertTrue(visit.captured.isEmpty)
        let id = try self.recordLoss()
        let live = try self.live()
        XCTAssertFalse(self.events.isSeen(id: id))
        XCTAssertEqual(visit.displayed(live: live).map(\.id), [id])
        visit.beginNewVisit(live: live, store: self.events)
        XCTAssertTrue(self.events.isSeen(id: id))
        XCTAssertEqual(visit.captured.map(\.id), [id])
    }

    func testSeenFileSurvivesANewVisitAfterRelaunch() throws {
        let id = try self.recordLoss()
        let first = JournalGapVisit()
        first.beginNewVisit(live: try self.live(), store: self.events)
        XCTAssertTrue(self.events.isSeen(id: id))

        let relaunched = JournalGapVisit()
        let live = try self.live()
        XCTAssertTrue(live.isEmpty)
        relaunched.beginNewVisit(live: live, store: self.events)
        XCTAssertTrue(relaunched.didCapture)
        XCTAssertTrue(relaunched.captured.isEmpty)
        XCTAssertTrue(self.events.isSeen(id: id))
        XCTAssertEqual(relaunched.displayedNotice(live: live, now: self.now), .absent)
    }

    func testFailedSeenWriteLeavesThatLossUnseen() throws {
        let id = try self.recordLoss()
        let seen = self.events.rootURL.appendingPathComponent("seen", isDirectory: false)
        try Data("blocked".utf8).write(to: seen)
        let visit = JournalGapVisit()
        let live = try self.live()
        visit.beginNewVisit(live: live, store: self.events)
        XCTAssertTrue(visit.didCapture)
        XCTAssertFalse(self.events.isSeen(id: id))
        XCTAssertTrue(visit.captured.isEmpty)
        XCTAssertEqual(visit.displayed(live: live).map(\.id), [id])
    }

    func testLossWrittenWhileAMarkIsInProgressStaysUnseen() throws {
        let shown = try self.recordLoss()
        let concurrent = try self.recordLoss()
        let snapshot = try self.live().filter { $0.id == shown }
        let visit = JournalGapVisit()
        visit.beginNewVisit(live: snapshot, store: self.events)
        XCTAssertTrue(self.events.isSeen(id: shown))
        XCTAssertFalse(self.events.isSeen(id: concurrent))
        XCTAssertEqual(visit.displayed(live: try self.live()).map(\.id), [shown, concurrent])
    }

    func testReturningToTheForegroundMarksTheLossThatArrivedWhileAway() throws {
        let first = try self.recordLoss()
        let visit = JournalGapVisit()
        visit.foreground(live: try self.live(), store: self.events)
        XCTAssertEqual(visit.captured.map(\.id), [first])
        let second = try self.recordLoss()
        XCTAssertFalse(self.events.isSeen(id: second))
        visit.background()
        XCTAssertFalse(self.events.isSeen(id: second))
        XCTAssertFalse(visit.didCapture)
        visit.foreground(live: try self.live(), store: self.events)
        XCTAssertTrue(self.events.isSeen(id: second))
        XCTAssertEqual(visit.captured.map(\.id), [second])
    }

    func testInactiveSceneMarksNothing() throws {
        XCTAssertFalse(RootShellView.journalGapVisitMayStart(sceneIsActive: false, surfaceVisible: true))
        XCTAssertFalse(RootShellView.journalGapVisitMayStart(sceneIsActive: true, surfaceVisible: false))
        XCTAssertTrue(RootShellView.journalGapVisitMayStart(sceneIsActive: true, surfaceVisible: true))
        let id = try self.recordLoss()
        let visit = JournalGapVisit()
        visit.background()
        XCTAssertFalse(self.events.isSeen(id: id))
        XCTAssertTrue(visit.displayed(live: try self.live()).isEmpty)
    }

    func testOpenStatusReadsTheNoticeAfterTheRefresh() {
        var refreshed = false
        let losses = RootShellView.refreshedLosses {
            refreshed = true
        } notice: {
            XCTAssertTrue(refreshed)
            return []
        }
        XCTAssertTrue(losses.isEmpty)
        XCTAssertTrue(refreshed)
    }

    func testSelectingThePillAgainStartsANewVisit() throws {
        let first = try self.recordLoss()
        let visit = JournalGapVisit()
        visit.beginNewVisit(live: try self.live(), store: self.events)
        let second = try self.recordLoss()
        XCTAssertFalse(self.events.isSeen(id: second))
        visit.beginNewVisit(live: try self.live(), store: self.events)
        XCTAssertTrue(self.events.isSeen(id: first))
        XCTAssertTrue(self.events.isSeen(id: second))
        XCTAssertEqual(visit.captured.map(\.id), [second])
        XCTAssertTrue(try self.live().isEmpty)
    }

    // MARK: - Helpers

    private func recordLoss() throws -> String {
        let segmentID = UUID()
        try self.events.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.now,
            now: self.now
        )
        return JournalEventStore.lossID(segmentID: segmentID, source: .audio)
    }

    private func live() throws -> [JournalEventRecord] {
        guard case .events(let rows) = self.events.unseenLosses(now: self.now) else {
            XCTFail("journal events unreadable")
            return []
        }
        return rows
    }

    private func writeLossFile(segmentID: UUID) throws -> String {
        let id = JournalEventStore.lossID(segmentID: segmentID, source: .audio)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: self.now)
        let object: [String: Any] = [
            "id": id,
            "kind": "loss",
            "source": "audio",
            "reason": "audio_capture_unfinished",
            "segment_id": segmentID.uuidString,
            "found_at": stamp,
            "last_at": stamp,
            "capture_at": stamp,
            "count": 1,
        ]
        let url = self.events.rootURL
            .appendingPathComponent("losses", isDirectory: true)
            .appendingPathComponent("\(id).json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return id
    }
}
