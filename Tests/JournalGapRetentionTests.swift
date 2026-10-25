// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// Old rows leave. An unseen loss inside the window, and a writer fault, stay.
@MainActor
final class JournalGapRetentionTests: XCTestCase {
    private var tempDirectory: URL!
    private var events: JournalEventStore!
    private var segmentDirectory: URL!
    private var cachesMarker: URL!
    private var calendar: Calendar!

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalGapRetention-\(UUID().uuidString)", isDirectory: true)
        let mobile = self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        self.segmentDirectory = mobile.appendingPathComponent("active", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.events = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: mobile))
        self.calendar = Calendar(identifier: .gregorian)
        self.calendar.timeZone = TimeZone(identifier: "UTC")!
        try FileManager.default.createDirectory(at: self.segmentDirectory, withIntermediateDirectories: true)
        try Data("segment".utf8).write(to: self.segmentDirectory.appendingPathComponent("audio.m4a"))
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cachesMarker = caches.appendingPathComponent("journal-gap-retention-\(UUID().uuidString).marker")
        try Data("caches".utf8).write(to: self.cachesMarker)
        try self.events.openGate(now: Date())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        if let cachesMarker = self.cachesMarker {
            try? FileManager.default.removeItem(at: cachesMarker)
        }
        self.events = nil
        self.segmentDirectory = nil
        self.cachesMarker = nil
        self.calendar = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testRowsOlderThanThirtyDaysLeave() throws {
        let now = Date()
        let expired = try XCTUnwrap(self.calendar.date(byAdding: .day, value: -31, to: now))
        let kept = try XCTUnwrap(self.calendar.date(byAdding: .day, value: -29, to: now))
        let expiredID = UUID()
        let keptID = UUID()
        try self.events.recordLoss(segmentID: expiredID, source: .audio, reason: "audio_capture_unfinished", captureAt: expired, now: expired, calendar: self.calendar)
        try self.events.recordLoss(segmentID: keptID, source: .audio, reason: "audio_capture_unfinished", captureAt: kept, now: kept, calendar: self.calendar)
        try self.events.markSeen(id: JournalEventStore.lossID(segmentID: expiredID, source: .audio))
        try self.events.markSeen(id: JournalEventStore.lossID(segmentID: keptID, source: .audio))
        self.events.prune(now: now, calendar: self.calendar)
        let rows = try self.losses()
        XCTAssertFalse(rows.contains { $0.segmentID == expiredID.uuidString })
        XCTAssertTrue(rows.contains { $0.segmentID == keptID.uuidString })
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.segmentDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.cachesMarker.path))
    }

    func testCapsDropTheOldestAndKeepAnUnseenLossInsideTheWindow() throws {
        let now = Date()
        let outside = try XCTUnwrap(self.calendar.date(byAdding: .day, value: -10, to: now))
        var oldestSeen: String?
        for index in 0..<JournalEventStore.lossCap {
            let segmentID = UUID()
            let found = outside.addingTimeInterval(TimeInterval(index))
            try self.events.recordLoss(
                segmentID: segmentID,
                source: .audio,
                reason: "audio_capture_unfinished",
                captureAt: found,
                now: found,
                calendar: self.calendar
            )
            let id = JournalEventStore.lossID(segmentID: segmentID, source: .audio)
            try self.events.markSeen(id: id)
            if oldestSeen == nil { oldestSeen = id }
        }
        let protected = UUID()
        try self.events.recordLoss(
            segmentID: protected,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: now,
            now: now,
            calendar: self.calendar
        )
        self.events.prune(now: now, calendar: self.calendar)
        let rows = try self.losses()
        XCTAssertEqual(rows.count, JournalEventStore.lossCap)
        XCTAssertTrue(rows.contains { $0.segmentID == protected.uuidString })
        XCTAssertFalse(self.events.isSeen(id: JournalEventStore.lossID(segmentID: protected, source: .audio)))
        XCTAssertFalse(rows.contains { $0.id == oldestSeen })

        for index in 0..<(JournalEventStore.diagnosticCap + 1) {
            try self.events.recordDiagnostic(
                segmentID: nil,
                source: .audio,
                reason: "observer_tap_write_stall_\(index)",
                captureAt: nil,
                now: outside.addingTimeInterval(TimeInterval(index)),
                calendar: self.calendar
            )
        }
        self.events.prune(now: now, calendar: self.calendar)
        let diagnostics = try self.diagnostics()
        XCTAssertEqual(diagnostics.count, JournalEventStore.diagnosticCap)
        XCTAssertFalse(diagnostics.contains { $0.reason == "observer_tap_write_stall_0" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.segmentDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.cachesMarker.path))
    }

    func testBeganAndEndedCollapseAndTheWriterFaultRemains() throws {
        let now = Date()
        let segmentID = UUID()
        for _ in 0..<4 {
            try self.events.recordDiagnostic(
                segmentID: nil,
                source: .audio,
                reason: "observer_interruption_began",
                captureAt: nil,
                now: now,
                calendar: self.calendar
            )
            try self.events.recordDiagnostic(
                segmentID: nil,
                source: .audio,
                reason: "observer_interruption_ended",
                captureAt: nil,
                now: now,
                detail: JournalEventDetail(interruptionDuration: 2),
                calendar: self.calendar
            )
        }
        try self.events.recordDiagnostic(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: nil,
            now: now,
            writerFault: true,
            calendar: self.calendar
        )
        self.events.prune(now: now, calendar: self.calendar)
        let rows = try self.diagnostics()
        XCTAssertEqual(rows.count, 3)
        let began = try XCTUnwrap(rows.first { $0.reason == "observer_interruption_began" })
        let ended = try XCTUnwrap(rows.first { $0.reason == "observer_interruption_ended" })
        let fault = try XCTUnwrap(rows.first { $0.id.hasSuffix("-fault") })
        XCTAssertEqual(began.count, 4)
        XCTAssertEqual(ended.count, 4)
        XCTAssertEqual(ended.detail?.interruptionDuration, 8)
        XCTAssertEqual(fault.count, 1)
        XCTAssertEqual(fault.reason, "audio_writer_failed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.segmentDirectory.appendingPathComponent("audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.cachesMarker.path))
    }

    private func losses() throws -> [JournalEventRecord] {
        try self.rows().filter { $0.kind == .loss }
    }

    private func diagnostics() throws -> [JournalEventRecord] {
        try self.rows().filter { $0.kind == .diagnostic || $0.kind == .legacy }
    }

    private func rows() throws -> [JournalEventRecord] {
        guard case .events(let rows) = self.events.readEvents() else {
            XCTFail("journal events unreadable")
            return []
        }
        return rows
    }
}
