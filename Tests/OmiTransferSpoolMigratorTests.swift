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
            acknowledgeTokens: { _ in },
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
            acknowledgeTokens: { _ in },
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
            acknowledgeTokens: { _ in },
            defaults: defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.audioURL.path))
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        let envelope = try OmiPendingHandoffStore.read(from: envelopeURL)
        XCTAssertNil(envelope.metadata)
        XCTAssertTrue(envelope.frozenTokens.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: self.appGroupOmiRoot(appGroupRoot).path))
        XCTAssertFalse(defaults.bool(forKey: OmiTransferSpoolMigrator.flagKey))
        XCTAssertTrue(diagnosticLog.events.contains { $0.detail?.contains(source.audioURL.path) == true })
        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.count, 0)
    }

    func testMigratorPreservesPendingEnvelopeIdentityAndMetadata() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("app-group-envelope", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        let diagnosticLog = DiagnosticLog()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        let sessionID = UUID()
        let itemID = UUID()
        let processID = UUID()
        let sidecar = makeTransferTestSidecar(
            sessionID: sessionID,
            chunkIndex: 0,
            startedAt: Date(timeIntervalSince1970: 1_780_480_800)
        )
        let source = try self.seedChunk(
            rootURL: self.appGroupOmiRoot(appGroupRoot),
            sessionID: sessionID,
            directoryName: "in-progress",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: sidecar
        )
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(
                OmiPendingHandoffEnvelope(
                    itemID: itemID,
                    sidecar: sidecar,
                    metadata: OmiSegmentMetadata(connectionState: "reconnecting", processID: processID),
                    frozenTokens: [OmiSegmentMetadataToken(kind: .reconnect, processID: processID, sequence: 1, revision: 1)]
                )
            ),
            to: envelopeURL
        )

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: diagnosticLog,
            acknowledgeTokens: { _ in },
            defaults: defaults
        )

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        let snapshot = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(snapshot.manifest.itemID, itemID)
        XCTAssertEqual(OmiSegmentMetadata.from(meta: snapshot.manifest.meta)?.connectionState, "reconnecting")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
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
            acknowledgeTokens: { _ in },
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
            acknowledgeTokens: { _ in },
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

    func testCommittedEnvelopeRestartCleansWithoutSecondEnqueue() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("restart", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let source = try self.seedChunk(rootURL: omiRoot, sessionID: sessionID, directoryName: "pending", chunkID: "\(sessionID.uuidString.lowercased())-0", sidecar: sidecar, includeDerivedFiles: true)
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [token])), to: envelopeURL)
        let first = makeTransferCutoverHarness(rootURL: transferRoot)
        try await first.engine.start()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        _ = try await first.engine.enqueue(manifest: manifest, payloads: ["audio": Data(contentsOf: source.audioURL)])

        let second = makeTransferCutoverHarness(rootURL: transferRoot)
        try await second.engine.start()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        await OmiTransferSpoolMigrator.migrate(appGroupRootURL: appGroupRoot, legacyCachesRootURL: nil, transferEnqueuer: second.enqueuer, diagnosticLog: nil, acknowledgeTokens: { acknowledgements.append($0) }, defaults: defaults)
        let snapshots = await second.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.filter { $0.manifest.itemID == itemID }.count, 1)
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.uploadURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.failureURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
        XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)))
        XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)))
    }

    func testPostEnqueueAttentionOwnershipCleansWithoutCrashing() async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("post-enqueue-attention", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let source = try self.seedChunk(
            rootURL: omiRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: sidecar,
            includeDerivedFiles: true
        )
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(
                OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [token])
            ),
            to: envelopeURL
        )
        let harness = makeTransferCutoverHarness(
            rootURL: transferRoot,
            fileSystem: CommitToAttentionTransferFileSystem(rootURL: transferRoot)
        )
        try await harness.engine.initialize()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: self.defaultsSuiteName))
        var acknowledgements: [[OmiSegmentMetadataToken]] = []

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { acknowledgements.append($0) },
            defaults: defaults
        )

        let queuedItemURL = transferRoot
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        let attentionItemURL = transferRoot
            .appendingPathComponent(TransferSpool.attentionDirectoryName, isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedItemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: attentionItemURL.path))
        XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)))
        XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)))
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.sidecarURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.uploadURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.failureURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    func testCleanupRemovalFaultsNeverReenqueueCommittedEnvelope() async throws {
        for fault in CleanupRemovalFault.allCases {
            try await self.assertCleanupRemovalFaultNeverReenqueues(fault)
        }
    }

    func testRawStagingRecoveryComposesWithOmiOwnershipProof() async throws {
        for shape in RawStagingShape.allCases {
            try await self.assertRawStagingRecovery(shape)
        }
    }

    func testCommittedOwnerOutranksSameIDSalvageArtifact() async throws {
        for state in CommittedOwnerState.allCases {
            try await self.assertCommittedOwnerOutranksSalvage(state)
        }
    }

    func testRootGuardRetainsEnvelopeAndLegacyMarkerResidue() async throws {
        for residue in RootResidue.allCases {
            try await self.assertRootGuardRetains(residue)
        }
    }
}

private extension OmiTransferSpoolMigratorTests {
    enum CleanupRemovalFault: String, CaseIterable {
        case audio
        case sidecar
        case upload
        case failure
        case envelope
    }

    enum RawStagingShape: String, CaseIterable {
        case completeExact = "complete-exact"
        case manifestOnly = "manifest-only"
        case payloadOnly = "payload-only"
        case missingAudio = "missing-audio"
        case mismatchedComplete = "mismatched-complete"

        var isPromotedByTransfer: Bool {
            switch self {
            case .completeExact, .mismatchedComplete: true
            case .manifestOnly, .payloadOnly, .missingAudio: false
            }
        }
    }

    enum CommittedOwnerState: String, CaseIterable {
        case queued
        case attention
    }

    enum RootResidue: String, CaseIterable {
        case envelope
        case upload
    }

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

    func assertCleanupRemovalFaultNeverReenqueues(_ fault: CleanupRemovalFault) async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("cleanup-fault-\(fault.rawValue)", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let source = try self.seedChunk(
            rootURL: omiRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: sidecar,
            includeDerivedFiles: true
        )
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(
                OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [token])
            ),
            to: envelopeURL
        )
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.start()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data(contentsOf: source.audioURL)])

        let targetURL: URL
        switch fault {
        case .audio: targetURL = source.audioURL
        case .sidecar: targetURL = source.sidecarURL
        case .upload: targetURL = source.uploadURL
        case .failure: targetURL = source.failureURL
        case .envelope: targetURL = envelopeURL
        }
        let failingFileManager = TargetedRemovalFailingFileManager(failingURL: targetURL)
        let defaultsSuiteName = try XCTUnwrap(self.defaultsSuiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(defaultsSuiteName)-\(fault.rawValue)"))

        for attempt in 0..<3 {
            await OmiTransferSpoolMigrator.migrate(
                appGroupRootURL: appGroupRoot,
                legacyCachesRootURL: nil,
                transferEnqueuer: harness.enqueuer,
                diagnosticLog: nil,
                acknowledgeTokens: { _ in },
                defaults: defaults,
                fileManager: failingFileManager
            )

            let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
            XCTAssertEqual(snapshots.filter { $0.manifest.itemID == itemID }.count, 1, "fault=\(fault.rawValue) attempt=\(attempt)")
            XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)), "fault=\(fault.rawValue) attempt=\(attempt)")
            XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)), "fault=\(fault.rawValue) attempt=\(attempt)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path), "fault=\(fault.rawValue) attempt=\(attempt)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path), "fault=\(fault.rawValue) attempt=\(attempt)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: omiRoot.path), "fault=\(fault.rawValue) attempt=\(attempt)")
            XCTAssertFalse(defaults.bool(forKey: OmiTransferSpoolMigrator.flagKey), "fault=\(fault.rawValue) attempt=\(attempt)")
        }

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { _ in },
            defaults: defaults
        )

        let snapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.omi)
        XCTAssertEqual(snapshots.filter { $0.manifest.itemID == itemID }.count, 1, "fault=\(fault.rawValue)")
        XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)), "fault=\(fault.rawValue)")
        XCTAssertFalse(transferTestPathExists(containing: itemID.uuidString, under: transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)), "fault=\(fault.rawValue)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.audioURL.path), "fault=\(fault.rawValue)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.sidecarURL.path), "fault=\(fault.rawValue)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.uploadURL.path), "fault=\(fault.rawValue)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.failureURL.path), "fault=\(fault.rawValue)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path), "fault=\(fault.rawValue)")
    }

    func assertRawStagingRecovery(_ shape: RawStagingShape) async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("raw-staging-\(shape.rawValue)", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let source = try self.seedChunk(
            rootURL: omiRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: sidecar
        )
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(
                OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [token])
            ),
            to: envelopeURL
        )

        let audioData = try Data(contentsOf: source.audioURL)
        let spool = TransferSpool(rootURL: transferRoot)
        let canonical = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        var stagedManifest = self.manifestWithByteCount(canonical, audioByteCount: audioData.count)
        if shape == .mismatchedComplete {
            // Transfer recovers generic complete staging; Omi rejects this canonical mismatch later.
            stagedManifest.observerIngest?.platform = "other"
        }
        let stagingURL = spool.stagingDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        switch shape {
        case .completeExact, .mismatchedComplete:
            try self.writeRawTransferItem(manifest: stagedManifest, audioData: audioData, in: stagingURL, spool: spool)
        case .manifestOnly, .missingAudio:
            try self.writeRawTransferItem(manifest: stagedManifest, audioData: nil, in: stagingURL, spool: spool)
        case .payloadOnly:
            try self.writeRawTransferItem(manifest: nil, audioData: audioData, in: stagingURL, spool: spool)
        }

        let recovery = try spool.initialize()
        XCTAssertEqual(recovery.queued.contains { $0.manifest.itemID == itemID }, shape.isPromotedByTransfer, "shape=\(shape.rawValue)")
        XCTAssertEqual(
            self.transferItemDirectoryCount(named: itemID, under: spool.stagingDirectoryURL),
            0,
            "shape=\(shape.rawValue)"
        )
        XCTAssertEqual(
            self.transferItemDirectoryCount(named: itemID, under: spool.salvageDirectoryURL),
            shape.isPromotedByTransfer ? 0 : 1,
            "shape=\(shape.rawValue)"
        )

        let stagingCountBeforeMigration = self.transferItemDirectoryCount(named: itemID, under: spool.stagingDirectoryURL)
        let salvageCountBeforeMigration = self.transferItemDirectoryCount(named: itemID, under: spool.salvageDirectoryURL)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let defaultsSuiteName = try XCTUnwrap(self.defaultsSuiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(defaultsSuiteName)-raw-\(shape.rawValue)"))
        var acknowledgements: [[OmiSegmentMetadataToken]] = []

        if shape == .mismatchedComplete {
            let verdict = try await harness.enqueuer.verifyOmiOwnership(
                itemID: itemID,
                sidecar: sidecar,
                metadata: nil,
                expectedPayloadSourceURLs: ["audio": source.audioURL]
            )
            XCTAssertEqual(verdict, .conflict(.manifestMismatch))
        }

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { acknowledgements.append($0) },
            defaults: defaults
        )

        let stagingCountAfterMigration = self.transferItemDirectoryCount(named: itemID, under: spool.stagingDirectoryURL)
        let salvageCountAfterMigration = self.transferItemDirectoryCount(named: itemID, under: spool.salvageDirectoryURL)
        XCTAssertEqual(stagingCountAfterMigration, stagingCountBeforeMigration, "shape=\(shape.rawValue)")
        XCTAssertEqual(salvageCountAfterMigration, salvageCountBeforeMigration, "shape=\(shape.rawValue)")

        if shape == .completeExact {
            XCTAssertEqual(acknowledgements, [[token]])
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.audioURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
        } else {
            XCTAssertTrue(acknowledgements.isEmpty, "shape=\(shape.rawValue)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.audioURL.path), "shape=\(shape.rawValue)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path), "shape=\(shape.rawValue)")
            XCTAssertFalse(defaults.bool(forKey: OmiTransferSpoolMigrator.flagKey), "shape=\(shape.rawValue)")
        }
    }

    func assertCommittedOwnerOutranksSalvage(_ state: CommittedOwnerState) async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }

        let appGroupRoot = self.tempDirectory.appendingPathComponent("owner-salvage-\(state.rawValue)", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let source = try self.seedChunk(
            rootURL: omiRoot,
            sessionID: sessionID,
            directoryName: "pending",
            chunkID: "\(sessionID.uuidString.lowercased())-0",
            sidecar: sidecar,
            includeDerivedFiles: true
        )
        let diagnostics = OmiDiagnostics(fileURL: appGroupRoot.appendingPathComponent("omi-diagnostics.json", isDirectory: false))
        let identity = diagnostics.allocateEventIdentity()
        _ = diagnostics.recordDisconnected(event: OmiSourceEvent(
            timestamp: Date(),
            reason: "test",
            appStateAtDrop: "foreground",
            timeToReconnect: nil,
            identity: identity
        ))
        let token = try XCTUnwrap(diagnostics.frozenSegmentDeltas().tokens.first)
        let envelopeURL = OmiPendingHandoffStore.url(for: source.audioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(
                OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [token])
            ),
            to: envelopeURL
        )

        let audioData = try Data(contentsOf: source.audioURL)
        let spool = TransferSpool(rootURL: transferRoot)
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        let queued = try spool.commitStagedItem(itemID: spool.stage(manifest: manifest, payloads: ["audio": audioData]).item.manifest.itemID)
        if state == .attention {
            _ = try spool.moveQueuedItemToAttention(queued, reason: "held", detail: "held", now: Date())
        }
        let salvageURL = spool.salvageDirectoryURL
            .appendingPathComponent("test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        try self.writeRawTransferItem(manifest: queued.manifest, audioData: audioData, in: salvageURL, spool: spool)

        let harness = makeTransferCutoverHarness(
            rootURL: transferRoot,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableOmiTransferEndpointResolver()
        )
        try await harness.engine.initialize()
        let removalFileManager = RemovalOrderRecordingFileManager()
        let defaultsSuiteName = try XCTUnwrap(self.defaultsSuiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(defaultsSuiteName)-owner-salvage-\(state.rawValue)"))

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { diagnostics.acknowledgeSegmentMetadata(tokens: $0) },
            defaults: defaults,
            fileManager: removalFileManager
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
        XCTAssertEqual(try spool.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:]), state == .queued ? .ownedInQueued : .ownedInAttention)
        XCTAssertTrue(FileManager.default.fileExists(atPath: salvageURL.path))
        XCTAssertTrue(diagnostics.frozenSegmentDeltas().tokens.isEmpty)
        diagnostics.acknowledgeSegmentMetadata(tokens: [token])
        XCTAssertTrue(diagnostics.frozenSegmentDeltas().tokens.isEmpty)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        let envelopeRemovalIndex = try XCTUnwrap(removalFileManager.removedURLs.firstIndex(of: envelopeURL.standardizedFileURL))
        for cleanupURL in [source.audioURL, source.sidecarURL, source.uploadURL, source.failureURL] {
            XCTAssertLessThan(
                try XCTUnwrap(removalFileManager.removedURLs.firstIndex(of: cleanupURL.standardizedFileURL)),
                envelopeRemovalIndex,
                "state=\(state.rawValue)"
            )
        }

        await harness.engine.enableDispatch()
        if state == .queued {
            try await transferTestWaitFor("queued owner dispatch") {
                TransferURLProtocol.requests.count == 1
            }
            XCTAssertEqual(TransferURLProtocol.requests.filter { transferTestBoundaryItemID(from: $0) == itemID }.count, 1)
        } else {
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: salvageURL.path))
    }

    func assertRootGuardRetains(_ residue: RootResidue) async throws {
        let appGroupRoot = self.tempDirectory.appendingPathComponent("root-residue-\(residue.rawValue)", isDirectory: true)
        let omiRoot = self.appGroupOmiRoot(appGroupRoot)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let sessionID = UUID()
        let chunkID = "\(sessionID.uuidString.lowercased())-0"
        let directory = omiRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let residueURL: URL
        switch residue {
        case .envelope:
            let audioURL = directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
            let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
            residueURL = OmiPendingHandoffStore.url(for: audioURL)
            try OmiPendingHandoffStore.write(
                try OmiPendingHandoffStore.encode(
                    OmiPendingHandoffEnvelope(itemID: UUID(), sidecar: sidecar, metadata: nil, frozenTokens: [])
                ),
                to: residueURL
            )
        case .upload:
            residueURL = directory.appendingPathComponent("\(chunkID).upload", isDirectory: false)
            try Data("residue".utf8).write(to: residueURL, options: .atomic)
        }

        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let defaultsSuiteName = try XCTUnwrap(self.defaultsSuiteName)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "\(defaultsSuiteName)-residue-\(residue.rawValue)"))
        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { _ in },
            defaults: defaults
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: omiRoot.path), "residue=\(residue.rawValue)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: residueURL.path), "residue=\(residue.rawValue)")
        XCTAssertFalse(defaults.bool(forKey: OmiTransferSpoolMigrator.flagKey), "residue=\(residue.rawValue)")
    }

    func manifestWithByteCount(_ manifest: TransferManifest, audioByteCount: Int) -> TransferManifest {
        var manifest = manifest
        manifest.payloadParts[0].byteCount = audioByteCount
        return manifest
    }

    func writeRawTransferItem(
        manifest: TransferManifest?,
        audioData: Data?,
        in directoryURL: URL,
        spool: TransferSpool
    ) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if let manifest {
            try spool.writeManifestAtomically(manifest, in: directoryURL)
            if let audioData, let audioPart = manifest.payloadParts.first(where: { $0.partID == "audio" }) {
                let audioURL = directoryURL.appendingPathComponent(audioPart.relativePath, isDirectory: false)
                try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try audioData.write(to: audioURL, options: .atomic)
            }
        } else if let audioData {
            try audioData.write(to: directoryURL.appendingPathComponent("audio.m4a", isDirectory: false), options: .atomic)
        }
    }

    func transferItemDirectoryCount(named itemID: UUID, under rootURL: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }
        return enumerator.compactMap { $0 as? URL }.filter {
            $0.lastPathComponent == itemID.uuidString
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.count
    }

}

private final class CommitToAttentionTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let rootURL: URL
    private let base = FoundationTransferFileSystem()
    private let fileManager = FileManager.default
    private var didMoveCommittedItem = false

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func fileExists(atPath path: String) -> Bool {
        self.base.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.base.contentsOfDirectory(at: url)
    }

    func removeItem(at url: URL) throws {
        try self.base.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.base.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        try self.base.replaceItem(at: originalURL, withItemAt: newURL)
        guard !self.didMoveCommittedItem else { return }
        let itemDirectory = originalURL.deletingLastPathComponent()
        let queuedDirectory = self.rootURL.appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
        guard itemDirectory.deletingLastPathComponent() == queuedDirectory else { return }

        let attentionDirectory = self.rootURL.appendingPathComponent(TransferSpool.attentionDirectoryName, isDirectory: true)
        try self.fileManager.createDirectory(at: attentionDirectory, withIntermediateDirectories: true)
        try self.fileManager.moveItem(
            at: itemDirectory,
            to: attentionDirectory.appendingPathComponent(itemDirectory.lastPathComponent, isDirectory: true)
        )
        self.didMoveCommittedItem = true
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try self.base.write(data, to: url, options: options)
    }

    func data(contentsOf url: URL) throws -> Data {
        try self.base.data(contentsOf: url)
    }

    func byteCount(at url: URL) throws -> Int {
        try self.base.byteCount(at: url)
    }

    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        try self.base.readChunks(at: url, chunkSize: chunkSize, consume)
    }
}

private final class TargetedRemovalFailingFileManager: FileManager {
    private let failingURL: URL

    init(failingURL: URL) {
        self.failingURL = failingURL.standardizedFileURL
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if url.standardizedFileURL == self.failingURL {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.removeItem(at: url)
    }
}

nonisolated private struct AvailableOmiTransferEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

private final class RemovalOrderRecordingFileManager: FileManager {
    private(set) var removedURLs: [URL] = []

    override func removeItem(at url: URL) throws {
        self.removedURLs.append(url.standardizedFileURL)
        try super.removeItem(at: url)
    }
}
