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

        for oldURL in [pendingLocation, failedLocation] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        }
        for oldURL in [pendingAudio, failedAudio, inProgressAudio] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: badLocation.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedOmi.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedWatch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: untouchedImport.path))

        let pending = try harness.store.list(.pending)
        let failed = try harness.store.list(.failed)
        XCTAssertEqual(pending.count, 0)
        XCTAssertEqual(failed.count, 0)
        let snapshots = await harness.transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertTrue(snapshots.allSatisfy { $0.state == .queued })
        XCTAssertTrue(snapshots.allSatisfy { $0.manifest.observerIngest?.sources == ["location"] })
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: collidingID).path))
        let snapshots = await harness.transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let preserved = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.segmentID == collidingID })
        XCTAssertEqual(preserved.state, .queued)
        XCTAssertEqual(preserved.manifest.observerIngest?.sources, ["location"])
    }

    func testLegacyMobileMigrationTripsMaintenanceCheckpointsForLargeBacklog() async throws {
        let cooperator = MaintenanceCooperator(chunkSize: 2)
        let harness = self.makeHarness(cooperator: cooperator)
        let observerRoot = self.tempDirectory.appendingPathComponent("ObserverCheckpoint", isDirectory: true)
        let locationRoot = self.tempDirectory.appendingPathComponent("LocationCheckpoint", isDirectory: true)
        let sessionID = UUID()
        for index in 0..<5 {
            _ = try self.writeLegacyAudio(root: observerRoot, sessionID: sessionID, state: "pending", chunkID: "audio-\(index)")
            _ = try self.writeLegacyLocation(root: locationRoot, state: "pending", fileID: "20260628-09000\(index)_60")
        }

        await harness.uploader.migrateLegacyMobileItems(observerCacheRootURL: observerRoot, locationCacheRootURL: locationRoot)

        XCTAssertGreaterThan(cooperator.checkpointCount, 0)
    }

    func testCancelledLegacyMobileMigrationLeavesRemainingLegacyItemRetryable() async throws {
        let cooperator = MaintenanceCooperator(chunkSize: 1)
        let harness = self.makeHarness(cooperator: cooperator)
        let observerRoot = self.tempDirectory.appendingPathComponent("ObserverCancel", isDirectory: true)
        let locationRoot = self.tempDirectory.appendingPathComponent("LocationCancel", isDirectory: true)
        let sessionID = UUID()
        let remainingAudio = try self.writeLegacyAudio(root: observerRoot, sessionID: sessionID, state: "pending", chunkID: "remaining-audio")
        _ = try self.writeLegacyAudio(root: observerRoot, sessionID: sessionID, state: "pending", chunkID: "other-audio")
        _ = try self.writeLegacyLocation(root: locationRoot, state: "pending", fileID: "20260628-090000_60")

        let migration = Task { @MainActor in
            await harness.uploader.migrateLegacyMobileItems(observerCacheRootURL: observerRoot, locationCacheRootURL: locationRoot)
        }
        while cooperator.checkpointCount == 0 {
            await Task.yield()
        }
        migration.cancel()
        await migration.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: remainingAudio.path))
    }

    func testAppGroupRootMigrationCopiesBundlesAndTombstonesWithDistinctFlag() throws {
        let legacyRoot = self.tempDirectory.appendingPathComponent("LegacyMobileSegment", isDirectory: true)
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroup", isDirectory: true)
            .appendingPathComponent("MobileSegment", isDirectory: true)
        let defaults = try self.makeDefaults()
        defaults.set(true, forKey: "didMigrateLegacyMobileSegmentsV1")
        let activeID = UUID()
        let pendingID = UUID()
        let failedID = UUID()
        let uploadedID = UUID()
        let legacyStore = MobileSegmentStore(rootURL: legacyRoot)
        try self.writeBundle(store: legacyStore, segmentID: activeID, lifecycle: .active, source: .audio)
        try self.writeBundle(store: legacyStore, segmentID: pendingID, lifecycle: .pending, source: .location)
        try self.writeBundle(store: legacyStore, segmentID: failedID, lifecycle: .failed, source: .screencast)
        try legacyStore.writeTombstone(segmentID: uploadedID, kind: "uploaded", reason: "delivered", now: self.clock.now())
        let store = MobileSegmentStore(rootURL: appGroupRoot)

        let diagnostics = store.migrateRoot(fromLegacyCachesRoot: legacyRoot, defaults: defaults)

        XCTAssertEqual(diagnostics, [])
        XCTAssertTrue(defaults.bool(forKey: MobileSegmentStore.appGroupRootMigrationFlag))
        XCTAssertTrue(defaults.bool(forKey: "didMigrateLegacyMobileSegmentsV1"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentDirectoryURL(.active, segmentID: activeID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentDirectoryURL(.pending, segmentID: pendingID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentDirectoryURL(.failed, segmentID: failedID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.screenURL(in: store.segmentDirectoryURL(.failed, segmentID: failedID)).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.tombstoneDirectory(kind: "uploaded")
                .appendingPathComponent("\(uploadedID.uuidString).json", isDirectory: false)
                .path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyStore.segmentDirectoryURL(.active, segmentID: activeID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyStore.segmentDirectoryURL(.pending, segmentID: pendingID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyStore.segmentDirectoryURL(.failed, segmentID: failedID).path))
    }

    func testAppGroupRootMigrationCollisionLeavesBothCopiesAndReportsDiagnostic() throws {
        let legacyRoot = self.tempDirectory.appendingPathComponent("LegacyCollision", isDirectory: true)
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroupCollision", isDirectory: true)
            .appendingPathComponent("MobileSegment", isDirectory: true)
        let defaults = try self.makeDefaults()
        let segmentID = UUID()
        let legacyStore = MobileSegmentStore(rootURL: legacyRoot)
        let appGroupStore = MobileSegmentStore(rootURL: appGroupRoot)
        try self.writeBundle(store: legacyStore, segmentID: segmentID, lifecycle: .pending, source: .audio, payload: "legacy")
        try self.writeBundle(store: appGroupStore, segmentID: segmentID, lifecycle: .pending, source: .audio, payload: "app-group")

        let diagnostics = appGroupStore.migrateRoot(fromLegacyCachesRoot: legacyRoot, defaults: defaults)

        XCTAssertEqual(diagnostics, ["mobile segment root migration collision lifecycle=pending segment=\(segmentID.uuidString)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyStore.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appGroupStore.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertEqual(
            try String(contentsOf: legacyStore.audioURL(in: legacyStore.segmentDirectoryURL(.pending, segmentID: segmentID)), encoding: .utf8),
            "legacy"
        )
        XCTAssertEqual(
            try String(contentsOf: appGroupStore.audioURL(in: appGroupStore.segmentDirectoryURL(.pending, segmentID: segmentID)), encoding: .utf8),
            "app-group"
        )
    }

    func testDisabledMobileSegmentUploaderDoesNotTouchStoreWhenStorageUnavailable() async throws {
        let root = self.tempDirectory.appendingPathComponent("DisabledMobileSegment", isDirectory: true)
        let store = MobileSegmentStore(rootURL: root)
        let uploader = MobileSegmentUploader(
            store: store,
            clock: self.clock,
            storageDisabledReason: "mobile segment storage unavailable source=app-group"
        )

        XCTAssertThrowsError(try uploader.openSegment(sources: [.screencast], startedAt: self.clock.now(), sourceSetVersion: 1))
        await uploader.resumeFromDisk()
        await uploader.resolveFinalizeFailurePile()
        await uploader.redactScreencastFacet(segmentID: UUID())

        XCTAssertEqual(uploader.lastError, "mobile segment storage unavailable source=app-group")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(uploader.pendingCount, 0)
        XCTAssertEqual(uploader.failedCount, 0)
    }
}

private extension MobileSegmentMigrationTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
        let transferEngine: TransferEngine
    }

    func makeHarness(cooperator: MaintenanceCooperator = MaintenanceCooperator()) -> Harness {
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("transfer", isDirectory: true)
        )
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        return Harness(
            uploader: MobileSegmentUploader(
                transferEngine: transferHarness.engine,
                store: store,
                clock: self.clock,
                cooperator: cooperator
            ),
            store: store,
            transferEngine: transferHarness.engine
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

    func writeBundle(
        store: MobileSegmentStore,
        segmentID: UUID,
        lifecycle: MobileSegmentLifecycle,
        source: MobileSegmentSource,
        payload: String = "payload"
    ) throws {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [source],
            activeSourceSetVersion: 0
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try store.createActive(manifest: manifest)
        let artifactURL = store.artifactURL(in: directory, source: source)
        try Data(payload.utf8).write(to: artifactURL, options: .atomic)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: artifactURL.lastPathComponent,
            bytes: store.fileSize(at: artifactURL),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            mode: source == .audio ? .meeting : nil,
            fixCount: source == .location ? 1 : nil
        )
        try store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: endedAt)
        if lifecycle != .active {
            _ = try store.move(segmentID: segmentID, from: .active, to: lifecycle)
        }
    }

    func makeDefaults() throws -> UserDefaults {
        let suiteName = "MobileSegmentMigrationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
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
