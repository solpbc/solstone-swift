// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class WatchTransferSpoolMigratorTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchTransferSpoolMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.defaultsSuiteName = "WatchTransferSpoolMigratorTests-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let defaultsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.defaultsSuiteName = nil
        super.tearDown()
    }

    func testAC6MigratesSessionScopedWatchRootUsingSidecarChunkIndexAndQuarantinesMissingSidecar() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group", isDirectory: true)
        let legacyRoot = self.tempDirectory
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent(WatchTransferSpoolMigrator.legacyCacheDirectoryName, isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        let diagnosticLog = DiagnosticLog()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let pendingChunkID = UUID().uuidString
        let failedChunkID = UUID().uuidString
        let noSidecarChunkID = UUID().uuidString

        let pending = try self.seedChunk(
            legacyRoot: legacyRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: pendingChunkID,
            sidecar: makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 42, startedAt: startedAt)
        )
        let failed = try self.seedChunk(
            legacyRoot: legacyRoot,
            sessionID: sessionID,
            directoryName: "failed",
            chunkID: failedChunkID,
            sidecar: makeTransferTestSidecar(
                sessionID: sessionID,
                chunkIndex: 77,
                startedAt: startedAt.addingTimeInterval(60),
                locationJSONL: Data(#"{"lat":1}"#.utf8)
            )
        )
        let quarantined = try self.seedChunk(
            legacyRoot: legacyRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: noSidecarChunkID,
            sidecar: nil
        )

        await WatchTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyRootURL: legacyRoot,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )

        XCTAssertTrue(defaults.bool(forKey: WatchTransferSpoolMigrator.flagKey))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshots.count, 2)
        let chunkIndexes = snapshots.compactMap { $0.manifest.observerIngest?.chunkIndex }.sorted()
        XCTAssertEqual(chunkIndexes, [42, 77])
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.state, .queued)
            XCTAssertEqual(snapshot.manifest.source, ObserverAudioTransferSource.watch)
            XCTAssertEqual(snapshot.manifest.observerIngest?.platform, "watchos")
            XCTAssertEqual(snapshot.manifest.observerIngest?.sessionID, sessionID)
        }
        let failedSnapshot = try XCTUnwrap(snapshots.first { $0.manifest.observerIngest?.chunkIndex == 77 })
        XCTAssertEqual(failedSnapshot.manifest.payloadParts.map(\.partID).sorted(), ["audio", "location"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantined.audioURL.path))
        XCTAssertTrue(transferTestPathExists(
            containing: quarantined.audioURL.lastPathComponent,
            under: WatchTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot)
        ))
        XCTAssertTrue(diagnosticLog.events.contains {
            $0.message == "needs attention" && ($0.detail?.contains("quarantine") ?? false)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))

        await WatchTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyRootURL: legacyRoot,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )
        let snapshotsAfterSecondRun = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.watch)
        XCTAssertEqual(snapshotsAfterSecondRun.count, 2)
    }

    func testAC6FailedQuarantineLeavesOriginalRootAndFlagUnset() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group-quarantine-failing", isDirectory: true)
        let legacyRoot = self.tempDirectory
            .appendingPathComponent("caches-quarantine-failing", isDirectory: true)
            .appendingPathComponent(WatchTransferSpoolMigrator.legacyCacheDirectoryName, isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        let diagnosticLog = DiagnosticLog()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        let sessionID = UUID()
        let source = try self.seedChunk(
            legacyRoot: legacyRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: UUID().uuidString,
            sidecar: nil
        )

        await WatchTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyRootURL: legacyRoot,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            defaults: defaults,
            fileManager: QuarantineMoveFailingFileManager()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyRoot.path))
        XCTAssertFalse(defaults.bool(forKey: WatchTransferSpoolMigrator.flagKey))
        XCTAssertTrue(diagnosticLog.events.contains {
            $0.detail?.contains(source.audioURL.path) == true &&
                $0.detail?.contains("quarantine failed") == true
        })
    }
}

private extension WatchTransferSpoolMigratorTests {
    struct SeededChunk {
        let audioURL: URL
        let sidecarURL: URL
    }

    func seedChunk(
        legacyRoot: URL,
        sessionID: UUID,
        directoryName: String,
        chunkID: String,
        sidecar: ChunkSidecar?
    ) throws -> SeededChunk {
        let directory = legacyRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        let audioURL = directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let sidecarURL = directory.appendingPathComponent("\(chunkID).json", isDirectory: false)
        try writeTransferTestAudio(at: audioURL, seconds: sidecar?.durationS ?? 0.2)
        if let sidecar {
            try writeTransferTestSidecar(sidecar, to: sidecarURL)
        }
        return SeededChunk(audioURL: audioURL, sidecarURL: sidecarURL)
    }
}
