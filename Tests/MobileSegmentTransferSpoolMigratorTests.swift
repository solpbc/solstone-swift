// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class MobileSegmentTransferSpoolMigratorTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        TransferURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentTransferSpoolMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.defaultsSuiteName = "MobileSegmentTransferSpoolMigratorTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.defaultsSuiteName = nil
        super.tearDown()
    }

    @MainActor
    func testAC5PendingSegmentQueuesAfterMigrateAndResume() async throws {
        let harness = try self.makeHarness(name: "pending")
        let segmentID = UUID()
        try self.seedSegment(store: harness.store, segmentID: segmentID, lifecycle: .pending, upload: .pending)

        await self.migrateThenResume(harness)

        try await self.assertQueuedMobileSegments([segmentID], engine: harness.transfer.engine)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path
        ))
        XCTAssertTrue(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
    }

    @MainActor
    func testAC5StuckUploadingPendingSegmentQueuesAfterMigrateAndResume() async throws {
        let harness = try self.makeHarness(name: "uploading")
        let segmentID = UUID()
        try self.seedSegment(store: harness.store, segmentID: segmentID, lifecycle: .pending, upload: .uploading)

        await self.migrateThenResume(harness)

        try await self.assertQueuedMobileSegments([segmentID], engine: harness.transfer.engine)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path
        ))
    }

    @MainActor
    func testAC5TransportClassFailedStagesReclassifyAndQueue() async throws {
        let harness = try self.makeHarness(name: "transport-failed")
        let stages = ["http-failure", "transport-failure", "legacy-migration"]
        var segmentIDs: [UUID] = []
        for stage in stages {
            let segmentID = UUID()
            segmentIDs.append(segmentID)
            try self.seedSegment(
                store: harness.store,
                segmentID: segmentID,
                lifecycle: .failed,
                upload: .failed,
                failureStage: stage
            )
        }

        await self.migrateThenResume(harness)

        try await self.assertQueuedMobileSegments(segmentIDs, engine: harness.transfer.engine)
        for segmentID in segmentIDs {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path
            ))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path
            ))
        }
    }

    @MainActor
    func testAC5FinalizeClassFailedStagesStayFailedAndDoNotQueue() async throws {
        let harness = try self.makeHarness(name: "finalize-failed")
        let stages = ["source-finalize", "segment-finalize", "schedule-gate", "reconcile"]
        var segmentIDs: [UUID] = []
        for stage in stages {
            let segmentID = UUID()
            segmentIDs.append(segmentID)
            try self.seedSegment(
                store: harness.store,
                segmentID: segmentID,
                lifecycle: .failed,
                upload: .failed,
                failureStage: stage
            )
        }

        await self.migrateThenResume(harness)

        let snapshots = await harness.transfer.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertEqual(snapshots.count, 0)
        for (index, segmentID) in segmentIDs.enumerated() {
            let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
            XCTAssertTrue(FileManager.default.fileExists(atPath: failedDirectory.path), stages[index])
            XCTAssertEqual(harness.store.loadFailure(in: failedDirectory)?.stage, stages[index])
        }
    }

    @MainActor
    func testAC5UnreadableFailedManifestIsQuarantinedAndCleanFlagSets() async throws {
        let harness = try self.makeHarness(name: "unreadable")
        let segmentID = UUID()
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        try Data("{bad json".utf8).write(to: harness.store.manifestURL(in: failedDirectory), options: .atomic)

        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: nil,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults
        )

        XCTAssertTrue(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertTrue(transferTestPathExists(
            containing: segmentID.uuidString,
            under: MobileSegmentTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: harness.appGroupRoot)
        ))
        try self.assertNoSourceCodeRemovesTransferQuarantine()
    }

    @MainActor
    func testAC5ResumeEnqueueFailureAfterMigrationLeavesPendingSegmentFullyIntact() async throws {
        let fileSystem = FailingManifestWriteFileSystem()
        fileSystem.failManifestWrites = true
        let harness = try self.makeHarness(name: "enqueue-fails", fileSystem: fileSystem)
        let segmentID = UUID()
        let pendingDirectory = try self.seedSegment(
            store: harness.store,
            segmentID: segmentID,
            lifecycle: .pending,
            upload: .pending,
            sources: [.audio, .location, .screencast]
        )

        await self.migrateThenResume(harness)

        XCTAssertTrue(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: pendingDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenURL(in: pendingDirectory).path))
        let snapshots = await harness.transfer.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        XCTAssertTrue(snapshots.isEmpty)
    }

    @MainActor
    func testAC5FailedQuarantineMoveLeavesSourceAndFlagUnset() async throws {
        let harness = try self.makeHarness(name: "quarantine-fails")
        let segmentID = UUID()
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        try Data("{bad json".utf8).write(to: harness.store.manifestURL(in: failedDirectory), options: .atomic)

        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: nil,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults,
            fileManager: QuarantineMoveFailingFileManager()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertFalse(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
        XCTAssertTrue(harness.diagnosticLog.events.contains {
            $0.detail?.contains(failedDirectory.path) == true &&
                $0.detail?.contains("quarantine failed") == true
        })
    }

    @MainActor
    func testAC5CleanPassSetsFlagRemovesObserverRootAndSecondRunIsNoOp() async throws {
        let harness = try self.makeHarness(name: "clean")
        let backgroundBodies = harness.observerRoot
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
        try FileManager.default.createDirectory(at: backgroundBodies, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: backgroundBodies.appendingPathComponent("old.upload"), options: .atomic)

        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: harness.observerRoot,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults
        )

        XCTAssertTrue(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundBodies.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.observerRoot.path))

        let sentinel = harness.observerRoot.appendingPathComponent("sentinel", isDirectory: false)
        try FileManager.default.createDirectory(at: harness.observerRoot, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: sentinel, options: .atomic)

        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: harness.observerRoot,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    @MainActor
    func testAC5ObserverResidueQuarantinesNonEmptyChunksAndDiscardsZeroByteChunks() async throws {
        let harness = try self.makeHarness(name: "residue")
        let sessionID = UUID()
        let pending = harness.observerRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        let nonEmptyChunk = pending.appendingPathComponent("\(sessionID.uuidString.lowercased())-0.m4a")
        let zeroChunk = pending.appendingPathComponent("\(sessionID.uuidString.lowercased())-1.m4a")
        try writeTransferTestAudio(at: nonEmptyChunk, seconds: 0.2)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try Data().write(to: zeroChunk, options: .atomic)

        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: harness.observerRoot,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults
        )

        let quarantineRoot = MobileSegmentTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: harness.appGroupRoot)
        XCTAssertTrue(transferTestPathExists(containing: nonEmptyChunk.lastPathComponent, under: quarantineRoot))
        XCTAssertFalse(transferTestPathExists(containing: zeroChunk.lastPathComponent, under: quarantineRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.observerRoot.path))
        XCTAssertTrue(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
    }

    @MainActor
    func testAC9QueuedMobileTransferSurvivesFreshEngineBeforeDelivery() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let harness = try self.makeHarness(name: "crash-resume")
        let segmentID = UUID()
        try self.seedSegment(store: harness.store, segmentID: segmentID, lifecycle: .pending, upload: .pending)

        await harness.uploader.resumeFromDisk()
        try await self.assertQueuedMobileSegments([segmentID], engine: harness.transfer.engine)

        let resumed = makeTransferCutoverHarness(
            rootURL: harness.transferRoot,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        )
        try await resumed.engine.start()

        try await transferTestWaitFor("fresh engine delivered queued mobile item", timeout: .seconds(4)) {
            await resumed.engine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount == 1
        }
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)
    }

    @MainActor
    func testAC9FailedMidMigrationCanRerunWithoutDuplicateOrLoss() async throws {
        let harness = try self.makeHarness(name: "mid-migration")
        let transportFailedID = UUID()
        let unreadableID = UUID()
        try self.seedSegment(
            store: harness.store,
            segmentID: transportFailedID,
            lifecycle: .failed,
            upload: .failed,
            failureStage: "http-failure"
        )
        let unreadableDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: unreadableID)
        try FileManager.default.createDirectory(at: unreadableDirectory, withIntermediateDirectories: true)
        try Data("{bad json".utf8).write(to: harness.store.manifestURL(in: unreadableDirectory), options: .atomic)

        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: nil,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults,
            fileManager: QuarantineMoveFailingFileManager()
        )
        XCTAssertFalse(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
        await harness.uploader.resumeFromDisk()

        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: nil,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults
        )
        await harness.uploader.resumeFromDisk()

        try await self.assertQueuedMobileSegments([transportFailedID], engine: harness.transfer.engine)
        XCTAssertTrue(transferTestPathExists(
            containing: unreadableID.uuidString,
            under: MobileSegmentTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: harness.appGroupRoot)
        ))
        XCTAssertTrue(harness.defaults.bool(forKey: MobileSegmentTransferSpoolMigrator.flagKey))
    }
}

@MainActor
private extension MobileSegmentTransferSpoolMigratorTests {
    struct Harness {
        let appGroupRoot: URL
        let observerRoot: URL
        let transferRoot: URL
        let transfer: (
            engine: TransferEngine,
            mirror: TransferStatusMirror,
            enqueuer: ObserverAudioTransferEnqueuer,
            omi: OmiUploaderHolder,
            watch: WatchUploaderHolder
        )
        let store: MobileSegmentStore
        let uploader: MobileSegmentUploader
        let diagnosticLog: DiagnosticLog
        let defaults: UserDefaults
    }

    func makeHarness(
        name: String,
        fileSystem: (any TransferFileSystem)? = nil
    ) throws -> Harness {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group-\(name)", isDirectory: true)
        let observerRoot = self.tempDirectory
            .appendingPathComponent("caches-\(name)", isDirectory: true)
            .appendingPathComponent("Observer", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let transfer = makeTransferCutoverHarness(
            rootURL: transferRoot,
            fileSystem: fileSystem,
            sessionConfiguration: makeTransferTestURLSessionConfiguration()
        )
        let store = MobileSegmentStore(rootURL: appGroupRoot.appendingPathComponent(MobileSegmentStore.directoryName, isDirectory: true))
        let uploader = MobileSegmentUploader(
            transferEngine: transfer.engine,
            store: store,
            clock: MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        return Harness(
            appGroupRoot: appGroupRoot,
            observerRoot: observerRoot,
            transferRoot: transferRoot,
            transfer: transfer,
            store: store,
            uploader: uploader,
            diagnosticLog: DiagnosticLog(),
            defaults: defaults
        )
    }

    func migrateThenResume(_ harness: Harness) async {
        await MobileSegmentTransferSpoolMigrator.migrate(
            appGroupRootURL: harness.appGroupRoot,
            observerCacheRootURL: nil,
            store: harness.store,
            diagnosticLog: harness.diagnosticLog,
            defaults: harness.defaults
        )
        await harness.uploader.resumeFromDisk()
    }

    @discardableResult
    func seedSegment(
        store: MobileSegmentStore,
        segmentID: UUID,
        lifecycle: MobileSegmentLifecycle,
        upload: MobileSegmentUploadState,
        sources: Set<MobileSegmentSource> = [.audio],
        failureStage: String? = nil
    ) throws -> URL {
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: sources,
            activeSourceSetVersion: 1
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = upload
        let activeDirectory = try store.createActive(manifest: manifest)
        for source in sources.sorted(by: { $0.rawValue < $1.rawValue }) {
            let artifactURL = store.artifactURL(in: activeDirectory, source: source)
            try Data("\(source.rawValue)-bytes".utf8).write(to: artifactURL, options: .atomic)
            try store.writeOutcome(
                MobileSegmentSourceResolution(
                    state: .finalizedArtifact,
                    artifactFilename: artifactURL.lastPathComponent,
                    bytes: store.fileSize(at: artifactURL),
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationS: 60,
                    mode: source == .audio ? .meeting : nil,
                    fixCount: source == .location ? 1 : nil
                ),
                source: source,
                manifest: &manifest,
                in: activeDirectory,
                now: endedAt
            )
        }
        manifest.upload = upload
        try store.writeManifest(manifest, in: activeDirectory)
        let directory = try store.move(segmentID: segmentID, from: .active, to: lifecycle)
        if let failureStage {
            try store.writeFailure(
                MobileSegmentFailureSidecar(
                    reason: failureStage,
                    httpStatus: nil,
                    transportError: nil,
                    attemptCount: 1,
                    stage: failureStage,
                    lastAttemptAt: endedAt
                ),
                in: directory
            )
        }
        return directory
    }

    func assertQueuedMobileSegments(
        _ expected: [UUID],
        engine: TransferEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let snapshots = await engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let segmentIDs = Set(snapshots.compactMap { $0.manifest.observerIngest?.segmentID })
        XCTAssertEqual(segmentIDs, Set(expected), file: file, line: line)
        XCTAssertEqual(snapshots.count, expected.count, file: file, line: line)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.state, .queued, file: file, line: line)
            XCTAssertEqual(snapshot.manifest.source, ObserverAudioTransferSource.mobileSegment, file: file, line: line)
        }
    }
}
