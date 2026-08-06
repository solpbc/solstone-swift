// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiTransferSpoolMigratorTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiTransferSpoolMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.defaultsSuiteName = "OmiTransferSpoolMigratorTests-\(UUID().uuidString)"
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

    func testAC3MigratesAppGroupAndLegacyOmiRootsEndToEnd() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group", isDirectory: true)
        let legacyRoot = self.tempDirectory
            .appendingPathComponent("caches", isDirectory: true)
            .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        let diagnosticLog = DiagnosticLog()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)

        let inProgress = try self.seedChunk(
            rootURL: self.appGroupOmiRoot(appGroupRoot),
            sessionID: sessionID,
            directoryName: "in-progress",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: startedAt)
        )
        let sidecarless = try self.seedChunk(
            rootURL: self.appGroupOmiRoot(appGroupRoot),
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-1",
            sidecar: nil,
            startedAtForProbe: startedAt.addingTimeInterval(60)
        )
        let failed = try self.seedChunk(
            rootURL: self.appGroupOmiRoot(appGroupRoot),
            sessionID: sessionID,
            directoryName: "failed",
            chunkID: "\(sessionID.uuidString.lowercased())-2",
            sidecar: makeTransferTestSidecar(
                sessionID: sessionID,
                chunkIndex: 2,
                startedAt: startedAt.addingTimeInterval(120)
            ),
            includeDerivedFiles: true
        )
        let legacy = try self.seedChunk(
            rootURL: legacyRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-3",
            sidecar: makeTransferTestSidecar(
                sessionID: sessionID,
                chunkIndex: 3,
                startedAt: startedAt.addingTimeInterval(180)
            )
        )
        let quarantined = try self.seedUndecodableChunk(
            rootURL: self.appGroupOmiRoot(appGroupRoot),
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-4"
        )

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: legacyRoot,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )

        XCTAssertTrue(defaults.bool(forKey: OmiTransferSpoolMigrator.flagKey))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 4)
        let snapshotsByChunkIndex = Dictionary(uniqueKeysWithValues: snapshots.compactMap { snapshot in
            snapshot.manifest.observerIngest?.chunkIndex.map { ($0, snapshot) }
        })
        XCTAssertEqual(Set(snapshotsByChunkIndex.keys), [0, 1, 2, 3])
        for (chunkIndex, snapshot) in snapshotsByChunkIndex {
            XCTAssertEqual(snapshot.state, .queued, "chunk \(chunkIndex)")
            XCTAssertEqual(snapshot.manifest.source, ObserverAudioTransferSource.omi)
            XCTAssertEqual(snapshot.manifest.observerIngest?.sessionID, sessionID)
            XCTAssertEqual(snapshot.manifest.observerIngest?.sources, ["audio"])
        }
        let rebuiltMetadata = try XCTUnwrap(snapshotsByChunkIndex[1]?.manifest.observerIngest)
        XCTAssertEqual(rebuiltMetadata.startedAt.timeIntervalSince1970, sidecarless.startedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshotsByChunkIndex[1]?.manifest.observerIngest?.day, ObserverSegmentNaming.dayString(for: sidecarless.startedAt))
        XCTAssertEqual(snapshotsByChunkIndex[2]?.manifest.observerIngest?.chunkIndex, 2)

        for migrated in [inProgress, sidecarless, failed, legacy] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: migrated.audioURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: migrated.sidecarURL.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.uploadURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.failureURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantined.audioURL.path))
        XCTAssertTrue(transferTestPathExists(containing: quarantined.audioURL.lastPathComponent, under: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot)))
        XCTAssertTrue(diagnosticLog.events.contains {
            $0.message == "needs attention" && ($0.detail?.contains("quarantine") ?? false)
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.appGroupOmiRoot(appGroupRoot).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyRoot.path))

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: legacyRoot,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )
        let snapshotsAfterSecondRun = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshotsAfterSecondRun.count, 4)
    }

    func testAC3ThrownEnqueueLeavesOriginalRootAndFlagUnset() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group-failing", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let fileSystem = FailingManifestWriteFileSystem()
        fileSystem.failManifestWrites = true
        let harness = makeTransferCutoverHarness(rootURL: transferRoot, fileSystem: fileSystem)
        let diagnosticLog = DiagnosticLog()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let source = try self.seedChunk(
            rootURL: self.appGroupOmiRoot(appGroupRoot),
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: startedAt)
        )

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            defaults: defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.appGroupOmiRoot(appGroupRoot).path))
        XCTAssertFalse(defaults.bool(forKey: OmiTransferSpoolMigrator.flagKey))
        XCTAssertTrue(diagnosticLog.events.contains { $0.detail?.contains(source.audioURL.path) == true })
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 0)
    }

    func testAC3FailedQuarantineLeavesOriginalRootAndFlagUnset() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group-quarantine-failing", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        let diagnosticLog = DiagnosticLog()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        let sessionID = UUID()
        let source = try self.seedUndecodableChunk(
            rootURL: self.appGroupOmiRoot(appGroupRoot),
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-0"
        )

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            defaults: defaults,
            fileManager: QuarantineMoveFailingFileManager()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.appGroupOmiRoot(appGroupRoot).path))
        XCTAssertFalse(defaults.bool(forKey: OmiTransferSpoolMigrator.flagKey))
        XCTAssertTrue(diagnosticLog.events.contains {
            $0.detail?.contains(source.audioURL.path) == true &&
                $0.detail?.contains("quarantine failed") == true
        })
    }

    func testAC2ThrownInProgressRecoveryLeavesFileAtSourceOrInSalvageAndQuarantineIsNeverRemoved() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group-recovery", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let fileSystem = FailingManifestWriteFileSystem()
        fileSystem.failManifestWrites = true
        let harness = makeTransferCutoverHarness(rootURL: transferRoot, fileSystem: fileSystem)
        let diagnosticLog = DiagnosticLog()
        let sessionID = UUID()
        let chunkID = "\(sessionID.uuidString.lowercased())-0"
        let source = try self.seedChunk(
            rootURL: omiRoot,
            sessionID: sessionID,
            directoryName: "in-progress",
            chunkID: chunkID,
            sidecar: nil,
            startedAtForProbe: Date(timeIntervalSince1970: 1_780_480_800)
        )

        let result = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: omiRoot,
            transferEnqueuer: harness.enqueuer,
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: diagnosticLog
        )
        try? await harness.engine.start()

        XCTAssertEqual(result.unresolvedCount, 1)
        let existsAtSource = FileManager.default.fileExists(atPath: source.audioURL.path)
        let existsInSalvage = transferTestPathExists(containing: ".m4a", under: transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true))
        XCTAssertTrue(existsAtSource || existsInSalvage)
        XCTAssertTrue(diagnosticLog.events.contains { $0.detail?.contains(source.audioURL.path) == true })
        try self.assertNoSourceCodeRemovesTransferQuarantine()
    }

    func testInProgressRecoveryUsesPendingEnvelopeIdentityMetadataAndTokens() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group-envelope", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.start()
        let sessionID = UUID()
        let itemID = UUID()
        let processID = UUID()
        let sidecar = makeTransferTestSidecar(
            sessionID: sessionID,
            chunkIndex: 0,
            startedAt: Date(timeIntervalSince1970: 1_780_480_800)
        )
        let source = try self.seedChunk(
            rootURL: omiRoot,
            sessionID: sessionID,
            directoryName: "in-progress",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: sidecar
        )
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: processID, sequence: 4, revision: 2)
        let envelope = OmiPendingHandoffEnvelope(
            itemID: itemID,
            sidecar: sidecar,
            metadata: OmiSegmentMetadata(connectionState: "reconnecting", processID: processID),
            frozenTokens: [token]
        )
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: envelopeURL)
        var acknowledgements: [[OmiSegmentMetadataToken]] = []

        let result = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: omiRoot,
            transferEnqueuer: harness.enqueuer,
            acknowledgeTokens: { acknowledgements.append($0) },
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: nil
        )

        XCTAssertEqual(result.recoveredCount, 1)
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.manifest.itemID, itemID)
        XCTAssertEqual(OmiSegmentMetadata.from(meta: snapshot.manifest.meta)?.connectionState, "reconnecting")
    }
}

private extension OmiTransferSpoolMigratorTests {
    struct SeededChunk {
        let audioURL: URL
        let sidecarURL: URL
        let uploadURL: URL
        let failureURL: URL
        let startedAt: Date
    }

    func appGroupOmiRoot(_ appGroupRoot: URL) -> URL {
        appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
    }

    func seedChunk(
        rootURL: URL,
        sessionID: UUID,
        directoryName: String,
        chunkID: String,
        sidecar: ChunkSidecar?,
        startedAtForProbe: Date? = nil,
        includeDerivedFiles: Bool = false
    ) throws -> SeededChunk {
        let directory = rootURL
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        let audioURL = directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let sidecarURL = directory.appendingPathComponent("\(chunkID).json", isDirectory: false)
        let uploadURL = directory.appendingPathComponent("\(chunkID).upload", isDirectory: false)
        let failureURL = directory.appendingPathComponent("\(chunkID).failure", isDirectory: false)
        let startedAt = sidecar?.startedAt ?? startedAtForProbe ?? Date(timeIntervalSince1970: 1_780_480_800)
        try writeTransferTestAudio(at: audioURL, seconds: sidecar?.durationS ?? 0.2)
        try FileManager.default.setAttributes(
            [.creationDate: startedAt, .modificationDate: startedAt.addingTimeInterval(sidecar?.durationS ?? 0.2)],
            ofItemAtPath: audioURL.path
        )
        if let sidecar {
            try writeTransferTestSidecar(sidecar, to: sidecarURL)
        }
        if includeDerivedFiles {
            try Data("body".utf8).write(to: uploadURL, options: .atomic)
            try Data("failure".utf8).write(to: failureURL, options: .atomic)
        }
        return SeededChunk(
            audioURL: audioURL,
            sidecarURL: sidecarURL,
            uploadURL: uploadURL,
            failureURL: failureURL,
            startedAt: startedAt
        )
    }

    func seedUndecodableChunk(
        rootURL: URL,
        sessionID: UUID,
        directoryName: String,
        chunkID: String
    ) throws -> SeededChunk {
        let directory = rootURL
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let sidecarURL = directory.appendingPathComponent("\(chunkID).json", isDirectory: false)
        try Data([0x00, 0x01, 0x02]).write(to: audioURL, options: .atomic)
        try Data("{bad json".utf8).write(to: sidecarURL, options: .atomic)
        return SeededChunk(
            audioURL: audioURL,
            sidecarURL: sidecarURL,
            uploadURL: directory.appendingPathComponent("\(chunkID).upload", isDirectory: false),
            failureURL: directory.appendingPathComponent("\(chunkID).failure", isDirectory: false),
            startedAt: Date(timeIntervalSince1970: 1_780_480_800)
        )
    }

}
