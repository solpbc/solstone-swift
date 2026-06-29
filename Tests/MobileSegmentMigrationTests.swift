// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Crypto
import Foundation
import XCTest

@MainActor
final class MobileSegmentMigrationTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        super.tearDown()
    }

    func testLegacyMobileItemsBecomeSingleSourceBundlesAndOldItemsAreRemovedAfterDurableWrite() async throws {
        let harness = self.makeHarness()
        let observerRoot = self.tempDirectory.appendingPathComponent("Observer", isDirectory: true)
        let locationRoot = self.tempDirectory.appendingPathComponent("Location", isDirectory: true)
        let untouchedOmi = self.tempDirectory.appendingPathComponent("OmiObserver", isDirectory: true).appendingPathComponent("sentinel", isDirectory: false)
        let untouchedWatch = self.tempDirectory.appendingPathComponent("WatchObserver", isDirectory: true).appendingPathComponent("sentinel", isDirectory: false)
        let untouchedImport = self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true).appendingPathComponent("sentinel", isDirectory: false)
        try FileManager.default.createDirectory(at: untouchedOmi.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untouchedWatch.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: untouchedImport.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("omi".utf8).write(to: untouchedOmi)
        try Data("watch".utf8).write(to: untouchedWatch)
        try Data("import".utf8).write(to: untouchedImport)

        let sessionID = UUID()
        let pendingAudio = try self.writeLegacyAudio(root: observerRoot, sessionID: sessionID, state: "pending", chunkID: "pending-audio")
        let failedAudio = try self.writeLegacyAudio(root: observerRoot, sessionID: sessionID, state: "failed", chunkID: "failed-audio")
        let inProgressAudio = try self.writeLegacyAudio(root: observerRoot, sessionID: sessionID, state: "in-progress", chunkID: "in-progress-audio")
        let pendingLocation = try self.writeLegacyLocation(root: locationRoot, state: "pending", fileID: "20260628-090000_60")
        let failedLocation = try self.writeLegacyLocation(root: locationRoot, state: "failed", fileID: "20260628-090100_60")
        let badLocation = locationRoot
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("bad.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: badLocation, withIntermediateDirectories: true)

        await harness.uploader.migrateLegacyMobileItems(observerCacheRootURL: observerRoot, locationCacheRootURL: locationRoot)

        for oldURL in [pendingAudio, failedAudio, inProgressAudio, pendingLocation, failedLocation] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: badLocation.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedOmi.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedWatch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedImport.path))

        let pending = try harness.store.list(.pending)
        let failed = try harness.store.list(.failed)
        XCTAssertEqual(pending.count, 3)
        XCTAssertEqual(failed.count, 2)
        let manifests = try (pending + failed).map { try harness.store.readManifest(in: $0) }
        XCTAssertEqual(manifests.filter { $0.audio.state == .finalizedArtifact && $0.location.state == .notDeclared }.count, 3)
        XCTAssertEqual(manifests.filter { $0.location.state == .finalizedArtifact && $0.audio.state == .notDeclared }.count, 2)
    }

    func testUnexpectedMigrationCollisionPreservesOldItemAndExistingBundle() async throws {
        let harness = self.makeHarness()
        let observerRoot = self.tempDirectory.appendingPathComponent("ObserverCollision", isDirectory: true)
        let sessionID = UUID()
        let chunkID = "collision-audio"
        let oldAudio = try self.writeLegacyAudio(root: observerRoot, sessionID: sessionID, state: "pending", chunkID: chunkID)
        let collidingID = Self.legacySegmentID(kind: "audio", key: "\(sessionID.uuidString):\(chunkID)")
        var manifest = MobileSegmentManifest(
            segmentID: collidingID,
            startedAt: self.clock.now(),
            openedWithSources: [.location],
            activeSourceSetVersion: 0
        )
        let activeDirectory = try harness.store.createActive(manifest: manifest)
        let locationURL = harness.store.locationURL(in: activeDirectory)
        try Data(#"{"schema":"solstone.location.segment/1","fix_count":1}"#.utf8).write(to: locationURL, options: .atomic)
        try harness.store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "location.jsonl",
                bytes: harness.store.fileSize(at: locationURL),
                startedAt: self.clock.now(),
                endedAt: self.clock.now().addingTimeInterval(60),
                durationS: 60,
                fixCount: 1
            ),
            source: .location,
            manifest: &manifest,
            in: activeDirectory,
            now: self.clock.now()
        )
        _ = try harness.store.move(segmentID: collidingID, from: .active, to: .pending)

        await harness.uploader.migrateLegacyMobileItems(observerCacheRootURL: observerRoot, locationCacheRootURL: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: oldAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: collidingID).path))
        let preserved = try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.pending, segmentID: collidingID))
        XCTAssertEqual(preserved.location.state, .finalizedArtifact)
        XCTAssertEqual(preserved.audio.state, .notDeclared)
    }
}

private extension MobileSegmentMigrationTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
    }

    func makeHarness() -> Harness {
        let transport = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("transport", isDirectory: true),
            isJournalConfigured: { false },
            localPortProvider: { nil },
            startPathMonitor: false
        )
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        return Harness(
            uploader: MobileSegmentUploader(transport: transport, store: store, clock: self.clock),
            store: store
        )
    }

    func writeLegacyAudio(root: URL, sessionID: UUID, state: String, chunkID: String) throws -> URL {
        let directory = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(state, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        try Data("audio-\(chunkID)".utf8).write(to: audioURL, options: .atomic)
        let sidecar = ChunkSidecar(
            segment: "090000_60",
            day: "20260628",
            chunkIndex: 0,
            startedAt: self.clock.now(),
            durationS: 60,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(sidecar).write(to: directory.appendingPathComponent("\(chunkID).json", isDirectory: false), options: .atomic)
        return audioURL
    }

    func writeLegacyLocation(root: URL, state: String, fileID: String) throws -> URL {
        let directory = root.appendingPathComponent(state, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(fileID).jsonl", isDirectory: false)
        try Data(#"{"schema":"solstone.location.segment/1","fix_count":1}"#.utf8).write(to: url, options: .atomic)
        return url
    }

    static func legacySegmentID(kind: String, key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("mobile-segment:\(kind):\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5],
            bytes[6], bytes[7],
            bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
