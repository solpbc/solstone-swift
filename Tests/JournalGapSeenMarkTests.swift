// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

/// A seen mark leaves only when its event file is confirmed absent, and only on a pass.
@MainActor
final class JournalGapSeenMarkTests: XCTestCase {
    private var tempDirectory: URL!
    private var events: JournalEventStore!
    private let now = Date(timeIntervalSince1970: 1_793_199_600)

    override func setUp() async throws {
        try await super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalGapSeenMark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        let mobile = self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        self.events = JournalEventStore(rootURL: JournalEventStore.directory(besideMobileSegmentRoot: mobile))
        try self.events.openGate(now: self.now)
    }

    override func tearDown() async throws {
        if let events = self.events {
            let losses = events.rootURL.appendingPathComponent("losses", isDirectory: true)
            if let names = try? FileManager.default.contentsOfDirectory(at: losses, includingPropertiesForKeys: nil) {
                for url in names {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
                }
            }
        }
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.events = nil
        self.tempDirectory = nil
        try await super.tearDown()
    }

    func testUnreadableEventFileKeepsItsSeenMark() throws {
        let id = try self.markLoss()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: self.lossFile(id).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.lossFile(id).path))
        XCTAssertThrowsError(try Data(contentsOf: self.lossFile(id)))
        self.events.prune(now: self.now)
        self.events.pruneForPass(now: self.now)
        XCTAssertTrue(self.events.isSeen(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.lossFile(id).path))
    }

    func testMissingLossesDirectoryKeepsSeenMarks() throws {
        let id = try self.markLoss()
        try FileManager.default.removeItem(at: self.events.rootURL.appendingPathComponent("losses", isDirectory: true))
        self.events.pruneForPass(now: self.now)
        XCTAssertTrue(self.events.isSeen(id: id))
    }

    func testUnreadableLossesDirectoryKeepsSeenMarks() throws {
        let id = try self.markLoss()
        let losses = self.events.rootURL.appendingPathComponent("losses", isDirectory: true)
        try FileManager.default.removeItem(at: losses)
        try Data("blocked".utf8).write(to: losses)
        self.events.pruneForPass(now: self.now)
        XCTAssertTrue(self.events.isSeen(id: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: losses.path))
    }

    func testGoneEventKeepsItsSeenMarkUntilThePass() throws {
        let id = try self.markLoss()
        try FileManager.default.removeItem(at: self.lossFile(id))
        self.events.prune(now: self.now)
        XCTAssertTrue(self.events.isSeen(id: id))
        self.events.pruneForPass(now: self.now)
        XCTAssertFalse(self.events.isSeen(id: id))
    }

    private func markLoss() throws -> String {
        let segmentID = UUID()
        try self.events.recordLoss(
            segmentID: segmentID,
            source: .audio,
            reason: "audio_capture_unfinished",
            captureAt: self.now,
            now: self.now
        )
        let id = JournalEventStore.lossID(segmentID: segmentID, source: .audio)
        try self.events.markSeen(id: id)
        return id
    }

    private func lossFile(_ id: String) -> URL {
        self.events.rootURL
            .appendingPathComponent("losses", isDirectory: true)
            .appendingPathComponent("\(id).json")
    }
}
