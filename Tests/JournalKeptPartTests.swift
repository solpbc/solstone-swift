// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// A kept or numbered part stays on disk until its journal event is written, and then it is recorded.
@MainActor
final class JournalKeptPartTests: XCTestCase {
    private var tempDirectory: URL!
    private var store: MobileSegmentStore!
    private var clock: MockObserverClock!
    private var uploader: MobileSegmentUploader!

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalKeptPart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
        self.uploader = MobileSegmentUploader(store: self.store, clock: self.clock)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.uploader = nil
        self.store = nil
        self.clock = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testFinishedFinalKeepsTheOldPartUntilDirectoryRemovalRecordsIt() async throws {
        let segmentID = UUID()
        let directory = try self.openActive(segmentID: segmentID, sources: [.screencast])
        let oldPart = Data("old-canonical-part".utf8)
        try oldPart.write(to: self.store.screenPartURL(in: directory))
        try Data("finished-final".utf8).write(to: self.store.screenURL(in: directory))
        try self.blockLosses()

        await self.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())
        let parked = try XCTUnwrap(self.store.findDirectory(segmentID: segmentID))
        let parkedPart = parked.url.appendingPathComponent(MobileSegmentScreencastPaths.screenPartFilename)
        XCTAssertEqual(try Data(contentsOf: parkedPart), oldPart)

        try self.store.writeTombstone(segmentID: segmentID, kind: "uploaded", reason: "delivered", now: self.clock.now())
        await self.uploader.resumeFromDisk()
        let kept = try XCTUnwrap(self.store.findDirectory(segmentID: segmentID))
        XCTAssertEqual(
            try Data(contentsOf: kept.url.appendingPathComponent(MobileSegmentScreencastPaths.screenPartFilename)),
            oldPart
        )
        try self.unblockLosses()
        XCTAssertFalse(try self.lossRecorded(segmentID: segmentID))

        await self.uploader.resumeFromDisk()
        XCTAssertNil(self.store.findDirectory(segmentID: segmentID))
        let loss = try self.loss(segmentID: segmentID)
        XCTAssertEqual(loss.source, .screencast)
        XCTAssertEqual(loss.reason, JournalKeptPart.reason)
    }

    func testAFinalWhoseSizeCannotBeReadKeepsBothFiles() throws {
        let segmentID = UUID()
        let directory = try self.openActive(segmentID: segmentID, sources: [.screencast])
        let partURL = self.store.screenPartURL(in: directory)
        let finalURL = self.store.screenURL(in: directory)
        try Data("window-just-recorded".utf8).write(to: partURL)
        try Data("previous-final".utf8).write(to: finalURL)
        let fileManager = StatFailingFileManager()
        fileManager.blockedPath = finalURL.path

        let handoff = try MobileSegmentScreencastJSONStore.finalizePart(
            partURL: partURL,
            finalURL: finalURL,
            fileManager: fileManager,
            replacement: JournalFinalReplacement(
                segmentID: segmentID,
                source: .screencast,
                captureAt: self.clock.now(),
                now: self.clock.now(),
                eventsRoot: self.uploader.journalEvents.rootURL
            )
        )
        XCTAssertEqual(handoff, .keptBoth)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partURL.path))
        XCTAssertEqual(try Data(contentsOf: finalURL), Data("previous-final".utf8))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(MobileSegmentScreencastPaths.screenDiagnosticFilename).path
        ))
    }

    func testReconcileKeepsANumberedPartUntilItsLossIsWritten() async throws {
        let segmentID = UUID()
        let directory = try self.openActive(segmentID: segmentID, sources: [.screencast])
        let window = Data("window-still-in-part-1".utf8)
        let numbered = directory.appendingPathComponent("\(MobileSegmentScreencastPaths.screenPartFilename).1")
        try window.write(to: numbered)
        try self.blockLosses()

        await self.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())
        let keptDirectory = try XCTUnwrap(self.store.findDirectory(segmentID: segmentID)).url
        XCTAssertEqual(try Data(contentsOf: keptDirectory.appendingPathComponent(numbered.lastPathComponent)), window)
        try self.unblockLosses()
        XCTAssertFalse(try self.lossRecorded(segmentID: segmentID))

        await self.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())
        XCTAssertNil(self.store.findDirectory(segmentID: segmentID))
        let loss = try self.loss(segmentID: segmentID)
        XCTAssertEqual(loss.source, .screencast)
        XCTAssertEqual(loss.reason, JournalKeptPart.reason)
    }

    func testKeepBothLeavesTheWindowUnmovedUntilALaterPassRecordsIt() async throws {
        let segmentID = UUID()
        let directory = try self.openActive(segmentID: segmentID, sources: [.screencast])
        let partURL = self.store.screenPartURL(in: directory)
        let finalURL = self.store.screenURL(in: directory)
        let window = Data("window-just-recorded".utf8)
        let previous = Data("previous-final".utf8)
        try window.write(to: partURL)
        try previous.write(to: finalURL)
        try self.blockLosses()

        let handoff = try MobileSegmentScreencastJSONStore.finalizePart(
            partURL: partURL,
            finalURL: finalURL,
            replacement: JournalFinalReplacement(
                segmentID: segmentID,
                source: .screencast,
                captureAt: self.clock.now(),
                now: self.clock.now(),
                eventsRoot: self.uploader.journalEvents.rootURL
            )
        )
        XCTAssertEqual(handoff, .keptBoth)
        XCTAssertEqual(try Data(contentsOf: partURL), window)
        XCTAssertEqual(try Data(contentsOf: finalURL), previous)
        XCTAssertNil(ScreencastBroadcastWriterOutcome.keptBoth.diagnosticReason)

        await self.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())
        let pending = try XCTUnwrap(self.store.findDirectory(segmentID: segmentID))
        let manifest = try self.store.readManifest(in: pending.url)
        XCTAssertEqual(manifest.resolution(for: .screencast).state, .finalizedArtifact)
        XCTAssertEqual(try Data(contentsOf: self.store.screenURL(in: pending.url)), previous)

        try self.store.writeTombstone(segmentID: segmentID, kind: "uploaded", reason: "delivered", now: self.clock.now())
        await self.uploader.resumeFromDisk()
        let kept = try XCTUnwrap(self.store.findDirectory(segmentID: segmentID))
        XCTAssertEqual(
            try Data(contentsOf: kept.url.appendingPathComponent(MobileSegmentScreencastPaths.screenPartFilename)),
            window
        )
        try self.unblockLosses()
        XCTAssertFalse(try self.lossRecorded(segmentID: segmentID))
        guard case .events(let rows) = self.uploader.journalEvents.readEvents() else {
            return XCTFail("journal events unreadable")
        }
        XCTAssertTrue(rows.contains {
            $0.segmentID == segmentID.uuidString && $0.kind == .diagnostic && $0.reason == JournalFinalReplacement.keepBothReason
        })

        await self.uploader.resumeFromDisk()
        XCTAssertNil(self.store.findDirectory(segmentID: segmentID))
        let loss = try self.loss(segmentID: segmentID)
        XCTAssertEqual(loss.source, .screencast)
        XCTAssertEqual(loss.reason, JournalKeptPart.reason)
    }

    private func openActive(segmentID: UUID, sources: Set<MobileSegmentSource>) throws -> URL {
        try self.store.createActive(manifest: MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: self.clock.now().addingTimeInterval(-300),
            openedWithSources: sources,
            activeSourceSetVersion: 1
        ))
    }

    private func blockLosses() throws {
        let losses = self.uploader.journalEvents.rootURL.appendingPathComponent("losses", isDirectory: false)
        if FileManager.default.fileExists(atPath: losses.path) {
            try FileManager.default.removeItem(at: losses)
        }
        try FileManager.default.createDirectory(at: losses.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: losses)
    }

    private func unblockLosses() throws {
        let losses = self.uploader.journalEvents.rootURL.appendingPathComponent("losses", isDirectory: false)
        if FileManager.default.fileExists(atPath: losses.path) {
            try FileManager.default.removeItem(at: losses)
        }
    }

    private func lossRecorded(segmentID: UUID) throws -> Bool {
        guard case .events(let rows) = self.uploader.journalEvents.readEvents() else {
            return false
        }
        return rows.contains { $0.segmentID == segmentID.uuidString && $0.kind == .loss && $0.reason == JournalKeptPart.reason }
    }

    private func loss(segmentID: UUID) throws -> JournalEventRecord {
        guard case .events(let rows) = self.uploader.journalEvents.readEvents() else {
            XCTFail("journal events unreadable")
            throw CocoaError(.fileReadUnknown)
        }
        return try XCTUnwrap(rows.first {
            $0.segmentID == segmentID.uuidString && $0.kind == .loss && $0.reason == JournalKeptPart.reason
        })
    }
}
