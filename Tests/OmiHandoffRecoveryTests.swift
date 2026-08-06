// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

final class OmiHandoffRecoveryTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiHandoffRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    @MainActor func testSalvageOnlyRetainsEnvelopeAndAcknowledgesNothing() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("group", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.start()
        let sessionID = UUID()
        let chunkID = "\(sessionID.uuidString.lowercased())-0"
        let directory = appGroupRoot
            .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("in-progress", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let itemID = UUID()
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelope = OmiPendingHandoffEnvelope(
            itemID: itemID,
            sidecar: makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date()),
            metadata: nil,
            frozenTokens: [token]
        )
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: envelopeURL)
        let salvage = transferRoot
            .appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)
            .appendingPathComponent("test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: salvage, withIntermediateDirectories: true)
        var acknowledgements: [[OmiSegmentMetadataToken]] = []

        let result = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
            transferEnqueuer: harness.enqueuer,
            acknowledgeTokens: { acknowledgements.append($0) },
            registerDispatchHold: { _ in },
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: nil
        )

        XCTAssertEqual(result.unresolvedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
        XCTAssertTrue(acknowledgements.isEmpty)
    }

    @MainActor func testEnvelopeOnlyOwnedQueuedAcknowledgesThenRemoves() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("owned", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.start()
        let sessionID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let itemID = UUID()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = try self.writeEnvelope(appGroupRoot: appGroupRoot, sessionID: sessionID, itemID: itemID, sidecar: sidecar, token: token)
        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        let result = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
            transferEnqueuer: harness.enqueuer,
            acknowledgeTokens: { acknowledgements.append($0) },
            registerDispatchHold: { _ in },
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: nil
        )
        XCTAssertEqual(result.unresolvedCount, 0)
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    @MainActor func testEnvelopeOnlyOwnedAttentionAcknowledgesThenRemoves() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("attention", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.start()
        let sessionID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let itemID = UUID()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        let spool = TransferSpool(rootURL: transferRoot)
        let queued = try spool.commitStagedItem(itemID: spool.stage(manifest: manifest, payloads: ["audio": Data("audio".utf8)]).item.manifest.itemID)
        _ = try spool.moveQueuedItemToAttention(queued, reason: "held", detail: "held", now: Date())
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = try self.writeEnvelope(appGroupRoot: appGroupRoot, sessionID: sessionID, itemID: itemID, sidecar: sidecar, token: token)
        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        let result = await OmiInProgressRecovery.recoverInProgressFiles(sessionID: sessionID, rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true), transferEnqueuer: harness.enqueuer, acknowledgeTokens: { acknowledgements.append($0) }, registerDispatchHold: { _ in }, quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot), diagnosticLog: nil)
        XCTAssertEqual(result.unresolvedCount, 0)
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    @MainActor func testEnvelopeRemovalFailureAcknowledgesBeforeRetainingEnvelope() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("removal", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.start()
        let sessionID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let itemID = UUID()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = try self.writeEnvelope(appGroupRoot: appGroupRoot, sessionID: sessionID, itemID: itemID, sidecar: sidecar, token: token)
        let log = DiagnosticLog()
        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        var heldItemIDs: [UUID] = []
        let result = await OmiInProgressRecovery.recoverInProgressFiles(sessionID: sessionID, rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true), transferEnqueuer: harness.enqueuer, acknowledgeTokens: { acknowledgements.append($0) }, registerDispatchHold: { heldItemIDs.append($0); await harness.engine.hold(itemID: $0) }, quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot), diagnosticLog: log, fileManager: HandoffRemovalFailingFileManager())
        XCTAssertEqual(result.unresolvedCount, 1)
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertEqual(heldItemIDs, [itemID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
        XCTAssertTrue(log.events.contains { $0.detail?.hasSuffix("reason=envelope removal failed") == true })
        await harness.engine.drop(itemID: itemID)
        let heldSnapshot = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNotNil(heldSnapshot)
    }

    @MainActor func testEnvelopeBackedAudioRemovalFailureAwaitsHoldBeforeDispatch() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("audio-removal", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = try self.writeEnvelope(
            appGroupRoot: appGroupRoot,
            sessionID: sessionID,
            itemID: itemID,
            sidecar: sidecar,
            token: token
        )
        let audioURL = envelopeURL.deletingPathExtension().appendingPathExtension("m4a")
        try writeTransferTestAudio(at: audioURL)
        var didRegisterHold = false

        let result = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
            transferEnqueuer: harness.enqueuer,
            acknowledgeTokens: { _ in },
            registerDispatchHold: { id in
                didRegisterHold = true
                await harness.engine.hold(itemID: id)
            },
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: nil,
            fileManager: TargetedRemovalFailingFileManager(failingURL: envelopeURL)
        )

        XCTAssertEqual(result.recoveredCount, 1)
        XCTAssertEqual(result.unresolvedCount, 1)
        XCTAssertTrue(didRegisterHold)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
        let heldSnapshot = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNotNil(heldSnapshot)
        await harness.engine.drop(itemID: itemID)
        let retainedSnapshot = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNotNil(retainedSnapshot)
    }

    @MainActor func testEnvelopeOnlyRemovalFailureRegistersHoldWithSharedFaultInjector() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("envelope-removal", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(rootURL: transferRoot)
        try await harness.engine.initialize()
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar),
            payloads: ["audio": Data("audio".utf8)]
        )
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = try self.writeEnvelope(appGroupRoot: appGroupRoot, sessionID: sessionID, itemID: itemID, sidecar: sidecar, token: token)
        var heldItemIDs: [UUID] = []

        let result = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
            transferEnqueuer: harness.enqueuer,
            acknowledgeTokens: { _ in },
            registerDispatchHold: { id in
                heldItemIDs.append(id)
                await harness.engine.hold(itemID: id)
            },
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: nil,
            fileManager: TargetedRemovalFailingFileManager(failingURL: envelopeURL)
        )

        XCTAssertEqual(result.unresolvedCount, 1)
        XCTAssertEqual(heldItemIDs, [itemID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
        await harness.engine.drop(itemID: itemID)
        let retainedSnapshot = await harness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNotNil(retainedSnapshot)
    }

    @MainActor func testMigrationAndRecoveryHoldsEmitOneDiagnosticForSameItem() async throws {
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let appGroupRoot = self.rootURL.appendingPathComponent("cross-seam", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let harness = makeTransferCutoverHarness(
            rootURL: transferRoot,
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )
        try await harness.engine.initialize()
        let sessionID = UUID()
        let itemID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let pendingDirectory = appGroupRoot
            .appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
        let pendingAudioURL = pendingDirectory.appendingPathComponent("\(sessionID.uuidString.lowercased())-0.m4a")
        try writeTransferTestAudio(at: pendingAudioURL)
        try writeTransferTestSidecar(sidecar, to: pendingAudioURL.deletingPathExtension().appendingPathExtension("json"))
        let pendingEnvelopeURL = OmiPendingHandoffStore.url(for: pendingAudioURL)
        try OmiPendingHandoffStore.write(
            try OmiPendingHandoffStore.encode(
                OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [])
            ),
            to: pendingEnvelopeURL
        )
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar),
            payloads: ["audio": Data(contentsOf: pendingAudioURL)]
        )
        let defaultsName = "OmiHandoffRecoveryTests-cross-seam-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { UserDefaults.standard.removePersistentDomain(forName: defaultsName) }

        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { _ in },
            registerDispatchHold: { await harness.engine.hold(itemID: $0) },
            defaults: defaults,
            fileManager: TargetedRemovalFailingFileManager(failingURL: pendingAudioURL)
        )

        let recoveryEnvelopeURL = try self.writeEnvelope(
            appGroupRoot: appGroupRoot,
            sessionID: sessionID,
            itemID: itemID,
            sidecar: sidecar,
            token: OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        )
        _ = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: sessionID,
            rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
            transferEnqueuer: harness.enqueuer,
            acknowledgeTokens: { _ in },
            registerDispatchHold: { await harness.engine.hold(itemID: $0) },
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: nil,
            fileManager: TargetedRemovalFailingFileManager(failingURL: recoveryEnvelopeURL)
        )

        let heldEvents = events.withLock { values in
            values.filter { $0.outcome == .held && $0.itemID == itemID }
        }
        XCTAssertEqual(heldEvents.count, 1)
    }

    @MainActor func testEnvelopeOnlyLookupFailureRetainsAndDiagnoses() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("lookup", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let fileSystem = EvidenceFailingTransferFileSystem()
        let harness = makeTransferCutoverHarness(rootURL: transferRoot, fileSystem: fileSystem)
        try await harness.engine.start()
        let sessionID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = try self.writeEnvelope(appGroupRoot: appGroupRoot, sessionID: sessionID, itemID: UUID(), sidecar: sidecar, token: token)
        fileSystem.failDirectoryReads = true
        let log = DiagnosticLog()
        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        let result = await OmiInProgressRecovery.recoverInProgressFiles(sessionID: sessionID, rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true), transferEnqueuer: harness.enqueuer, acknowledgeTokens: { acknowledgements.append($0) }, registerDispatchHold: { _ in }, quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot), diagnosticLog: log)
        XCTAssertEqual(result.unresolvedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path))
        XCTAssertTrue(acknowledgements.isEmpty)
        XCTAssertTrue(log.events.contains { $0.detail?.hasSuffix("reason=item lookup failed") == true })
    }

    @MainActor func testEnvelopeOnlyDoesNotReadCommittedPayloadWithoutSourceProof() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("read", isDirectory: true)
        let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        let fileSystem = EvidenceFailingTransferFileSystem()
        let harness = makeTransferCutoverHarness(rootURL: transferRoot, fileSystem: fileSystem)
        try await harness.engine.start()
        let sessionID = UUID()
        let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        let itemID = UUID()
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
        _ = try await harness.engine.enqueue(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
        let envelopeURL = try self.writeEnvelope(appGroupRoot: appGroupRoot, sessionID: sessionID, itemID: itemID, sidecar: sidecar, token: token)
        fileSystem.failChunkReads = true
        var acknowledgements: [[OmiSegmentMetadataToken]] = []
        let result = await OmiInProgressRecovery.recoverInProgressFiles(sessionID: sessionID, rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true), transferEnqueuer: harness.enqueuer, acknowledgeTokens: { acknowledgements.append($0) }, registerDispatchHold: { _ in }, quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot), diagnosticLog: nil)
        XCTAssertEqual(result.unresolvedCount, 0)
        XCTAssertEqual(acknowledgements, [[token]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelopeURL.path))
    }

    @MainActor func testEnvelopeOnlyUnownedVerdictsRetainAndDiagnose() async throws {
        enum Case: String, CaseIterable {
            case notFound = "item not found"
            case staging = "item in staging"
            case salvage = "item in salvage"
            case conflict = "owner conflict"
            case undecodable = "manifest undecodable"
            case mismatch = "manifest mismatch"
            case payload = "payload mismatch"
        }
        for testCase in Case.allCases {
            let appGroupRoot = self.rootURL.appendingPathComponent(testCase.rawValue, isDirectory: true)
            let transferRoot = appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
            let harness = makeTransferCutoverHarness(rootURL: transferRoot)
            try await harness.engine.start()
            let sessionID = UUID()
            let sidecar = makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
            let itemID = UUID()
            let token = OmiSegmentMetadataToken(kind: .reconnect, processID: UUID(), sequence: 1, revision: 1)
            let envelopeURL = try self.writeEnvelope(appGroupRoot: appGroupRoot, sessionID: sessionID, itemID: itemID, sidecar: sidecar, token: token)
            let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(itemID: itemID, sidecar: sidecar, metadata: nil)
            if testCase == .staging { _ = try TransferSpool(rootURL: transferRoot).stage(manifest: manifest, payloads: ["audio": Data("audio".utf8)]) }
            if testCase == .salvage {
                let salvage = transferRoot.appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true).appendingPathComponent("test", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(itemID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: salvage, withIntermediateDirectories: true)
            }
            if [.conflict, .undecodable, .mismatch, .payload].contains(testCase) {
                let spool = TransferSpool(rootURL: transferRoot)
                let committed = try spool.commitStagedItem(itemID: spool.stage(manifest: manifest, payloads: ["audio": Data("audio".utf8)]).item.manifest.itemID)
                switch testCase {
                case .conflict:
                    try FileManager.default.copyItem(
                        at: committed.directoryURL,
                        to: spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
                    )
                case .undecodable:
                    try Data("malformed".utf8).write(to: committed.directoryURL.appendingPathComponent(TransferSpool.manifestFilename))
                case .mismatch:
                    var mismatch = committed.manifest
                    mismatch.endpoint.path = "/mismatch"
                    try spool.writeManifestAtomically(mismatch, in: committed.directoryURL)
                case .payload:
                    try FileManager.default.removeItem(at: committed.directoryURL.appendingPathComponent("audio.m4a"))
                case .notFound, .staging, .salvage:
                    break
                }
            }
            let log = DiagnosticLog()
            var acknowledgements: [[OmiSegmentMetadataToken]] = []
            let result = await OmiInProgressRecovery.recoverInProgressFiles(sessionID: sessionID, rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true), transferEnqueuer: harness.enqueuer, acknowledgeTokens: { acknowledgements.append($0) }, registerDispatchHold: { _ in }, quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot), diagnosticLog: log)
            XCTAssertEqual(result.unresolvedCount, 1, testCase.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelopeURL.path), testCase.rawValue)
            XCTAssertTrue(acknowledgements.isEmpty, testCase.rawValue)
            XCTAssertTrue(log.events.contains { $0.detail?.hasSuffix("reason=\(testCase.rawValue)") == true }, testCase.rawValue)
        }
    }

    @MainActor private func writeEnvelope(appGroupRoot: URL, sessionID: UUID, itemID: UUID, sidecar: ChunkSidecar, token: OmiSegmentMetadataToken) throws -> URL {
        let directory = appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("in-progress", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let audioURL = directory.appendingPathComponent("\(sessionID.uuidString.lowercased())-0.m4a")
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        let envelope = OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [token])
        try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: envelopeURL)
        return envelopeURL
    }
}

private final class HandoffRemovalFailingFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        if url.pathExtension == OmiPendingHandoffEnvelope.pathExtension { throw CocoaError(.fileWriteUnknown) }
        try super.removeItem(at: url)
    }
}

private final class EvidenceFailingTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let base = FoundationTransferFileSystem()
    var failDirectoryReads = false
    var failChunkReads = false
    func fileExists(atPath path: String) -> Bool { self.base.fileExists(atPath: path) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try self.base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { if self.failDirectoryReads { throw CocoaError(.fileReadUnknown) }; return try self.base.contentsOfDirectory(at: url) }
    func removeItem(at url: URL) throws { try self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try self.base.moveItem(at: sourceURL, to: destinationURL) }
    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws { try self.base.replaceItem(at: originalURL, withItemAt: newURL) }
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try self.base.write(data, to: url, options: options) }
    func data(contentsOf url: URL) throws -> Data { try self.base.data(contentsOf: url) }
    func byteCount(at url: URL) throws -> Int { try self.base.byteCount(at: url) }
    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws { if self.failChunkReads { throw CocoaError(.fileReadUnknown) }; try self.base.readChunks(at: url, chunkSize: chunkSize, consume) }
}
