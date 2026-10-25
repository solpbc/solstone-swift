// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// Diagnostics name the fault and the loss, and a bad file does not hide a later loss.
@MainActor
final class JournalGapDiagnosticsTests: XCTestCase {
    private var tempDirectory: URL!
    private var events: JournalEventStore!
    private let now = Date()

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalGapDiagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        let mobile = self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        self.events = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: mobile))
        try self.events.openGate(now: self.now)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.events = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testSnapshotNamesTheFaultTheLossTheImportAndTheCollapsedFault() throws {
        let segmentID = UUID()
        try self.events.recordDiagnostic(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: self.now,
            now: self.now,
            writerFault: true
        )
        try self.events.recordDiagnostic(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: self.now,
            now: self.now,
            writerFault: true
        )
        try self.events.recordDiagnostic(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: self.now,
            now: self.now
        )
        try self.events.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.now,
            now: self.now
        )
        try self.events.writeImportComplete(imported: 2, skipped: 1)

        let faultID = JournalEventStore.diagnosticID(segmentID: segmentID, source: .audio, reason: "audio_writer_failed", writerFault: true)
        let publishID = JournalEventStore.diagnosticID(segmentID: segmentID, source: .audio, reason: "audio_writer_failed", writerFault: false)
        guard case .events(let rows) = self.events.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        let fault = try XCTUnwrap(rows.first { $0.id == faultID })
        let publish = try XCTUnwrap(rows.first { $0.id == publishID })
        XCTAssertEqual(fault.count, 2)
        XCTAssertEqual(publish.count, 1)
        XCTAssertTrue(fault.id.hasSuffix("-fault"))
        XCTAssertFalse(publish.id.hasSuffix("-fault"))
        XCTAssertEqual(fault.reason, publish.reason)

        let log = DiagnosticLog()
        log.journalEvents = self.events
        let text = log.snapshot(tunnel: TunnelManager())
        XCTAssertEqual(text.components(separatedBy: "audio_writer_failed").count - 1, 2)
        XCTAssertTrue(text.contains("audio_capture_unfinished"))
        XCTAssertTrue(text.contains("loss"))
        XCTAssertTrue(text.contains("diagnostic"))
        XCTAssertTrue(text.contains("Import: complete, 2 imported, 1 skipped"))
        XCTAssertFalse(text.contains("-fault"))
        XCTAssertTrue(text.contains("count=2"))
        XCTAssertTrue(text.contains("first="))
        XCTAssertTrue(text.contains("last="))
    }

    func testCollapsedObserverFaultExportsCountTimesAndDetail() throws {
        let first = self.now.addingTimeInterval(-120)
        let last = self.now
        try self.events.recordDiagnostic(
            segmentID: nil,
            source: .audio,
            reason: "observer_interruption_ended",
            captureAt: nil,
            now: first,
            detail: JournalEventDetail(interruptionDuration: 3)
        )
        try self.events.recordDiagnostic(
            segmentID: nil,
            source: .audio,
            reason: "observer_interruption_ended",
            captureAt: nil,
            now: last,
            detail: JournalEventDetail(interruptionDuration: 5)
        )
        try self.events.recordDiagnostic(
            segmentID: nil,
            source: .audio,
            reason: "observer_configuration_change",
            captureAt: nil,
            now: first,
            detail: JournalEventDetail(configurationRestartSuccesses: 1, configurationRestartFailures: 0)
        )
        try self.events.recordDiagnostic(
            segmentID: nil,
            source: .audio,
            reason: "observer_configuration_change",
            captureAt: nil,
            now: last,
            detail: JournalEventDetail(configurationRestartSuccesses: 2, configurationRestartFailures: 1)
        )
        let text = self.events.diagnosticSection(now: self.now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = .current
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        XCTAssertTrue(text.contains("count=2"))
        XCTAssertTrue(text.contains("first=\(formatter.string(from: first))"))
        XCTAssertTrue(text.contains("last=\(formatter.string(from: last))"))
        XCTAssertTrue(text.contains("interruption_duration=8"))
        XCTAssertTrue(text.contains("configuration_restart_successes=3"))
        XCTAssertTrue(text.contains("configuration_restart_failures=1"))
        XCTAssertFalse(text.contains("-fault"))
    }

    func testCorruptFileIsSetAsideAndANewLossStillShows() throws {
        let losses = self.events.rootURL.appendingPathComponent("losses", isDirectory: true)
        try FileManager.default.createDirectory(at: losses, withIntermediateDirectories: true)
        let corrupt = losses.appendingPathComponent("\(UUID().uuidString)-audio.json")
        try Data("{".utf8).write(to: corrupt)
        _ = self.events.readEvents()
        XCTAssertFalse(FileManager.default.fileExists(atPath: corrupt.path))
        let aside = self.events.rootURL.appendingPathComponent("aside", isDirectory: true)
        let asideFiles = try FileManager.default.contentsOfDirectory(at: aside, includingPropertiesForKeys: nil)
        XCTAssertEqual(asideFiles.count, 1)

        let segmentID = UUID()
        try self.events.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.now,
            now: self.now
        )
        let notice = JournalGapNotice.read(store: self.events, now: self.now)
        XCTAssertTrue(notice.isShowing)
        XCTAssertEqual(notice.lossIDs, [JournalEventStore.lossID(segmentID: segmentID, source: .audio)])
    }

    func testReadErrorLeavesTheFileAndALaterReadReturnsIt() throws {
        let segmentID = UUID()
        try self.events.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.now,
            now: self.now
        )
        let id = JournalEventStore.lossID(segmentID: segmentID, source: .audio)
        let file = self.events.rootURL
            .appendingPathComponent("losses", isDirectory: true)
            .appendingPathComponent("\(JournalEventStore.fileName(for: id)).json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }

        guard case .events(let hidden) = self.events.readEvents() else {
            return XCTFail("a single unreadable file made the store unreadable")
        }
        XCTAssertFalse(hidden.contains { $0.id == id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let aside = self.events.rootURL.appendingPathComponent("aside", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        XCTAssertFalse(self.events.isSeen(id: id))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        guard case .events(let restored) = self.events.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertTrue(restored.contains { $0.id == id })
    }

    func testUndecodableDiagnosticIsSetAsideAndAReadErrorLeavesTheFile() throws {
        let blockedSegment = UUID()
        let blockedID = JournalEventStore.diagnosticID(
            segmentID: blockedSegment,
            source: .audio,
            reason: "audio_writer_failed",
            writerFault: false
        )
        let blocked = self.diagnosticFile(id: blockedID)
        try FileManager.default.createDirectory(at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        let blockedBytes = Data("still-here".utf8)
        try blockedBytes.write(to: blocked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path) }

        try self.events.recordDiagnostic(
            segmentID: blockedSegment,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: self.now,
            now: self.now
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked.path)
        XCTAssertEqual(try Data(contentsOf: blocked), blockedBytes)
        let aside = self.events.rootURL.appendingPathComponent("aside", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        // This file is not a record. A later read would set it aside, so remove it before the next write.
        try FileManager.default.removeItem(at: blocked)

        let segmentID = UUID()
        let id = JournalEventStore.diagnosticID(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            writerFault: false
        )
        let file = self.diagnosticFile(id: id)
        let garbage = Data("{".utf8)
        try garbage.write(to: file)
        try self.events.recordDiagnostic(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_writer_failed",
            captureAt: self.now,
            now: self.now
        )

        let asideFiles = try FileManager.default.contentsOfDirectory(at: aside, includingPropertiesForKeys: nil)
        XCTAssertEqual(asideFiles.count, 1)
        XCTAssertEqual(try Data(contentsOf: asideFiles[0]), garbage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNotEqual(file.standardizedFileURL, asideFiles[0].standardizedFileURL)
        guard case .events(let rows) = self.events.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        let row = try XCTUnwrap(rows.first { $0.id == id })
        XCTAssertEqual(row.kind, .diagnostic)
        XCTAssertEqual(row.count, 1)
        XCTAssertEqual(row.reason, "audio_writer_failed")
    }

    private func diagnosticFile(id: String) -> URL {
        self.events.rootURL
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("\(JournalEventStore.fileName(for: id)).json")
    }
}
