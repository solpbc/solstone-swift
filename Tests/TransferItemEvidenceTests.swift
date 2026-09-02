// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class TransferItemEvidenceTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferItemEvidenceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    @MainActor func testMakeOmiManifestStampsV3DevicesIngestPath() {
        let manifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        )
        XCTAssertEqual(manifest.endpoint.path, "/app/devices/ingest")
        XCTAssertEqual(manifest.observerIngest?.ingestProtocolVersion, 3)
    }

    @MainActor func testExactQueuedManifestIsOwned() throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        let manifest = self.manifest()
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: manifest,
            payloads: ["audio": Data("audio".utf8)]
        ).item.manifest.itemID)

        XCTAssertEqual(
            try spool.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:]),
            .ownedInQueued
        )
    }

    @MainActor func testMutableManifestFieldsDoNotBlockOwnership() throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        let manifest = self.manifest()
        let committed = try spool.commitStagedItem(itemID: spool.stage(
            manifest: manifest,
            payloads: ["audio": Data("audio".utf8)]
        ).item.manifest.itemID)
        let attention = try spool.moveQueuedItemToAttention(
            committed,
            reason: "held",
            detail: "held",
            now: Date()
        )

        XCTAssertEqual(
            try spool.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:]),
            .ownedInAttention
        )
        XCTAssertEqual(attention.manifest.diskState, .attention)
    }

    @MainActor func testStagingAndSalvageAreNeverOwned() throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        let manifest = self.manifest()
        _ = try spool.stage(manifest: manifest, payloads: ["audio": Data("audio".utf8)])
        XCTAssertEqual(
            try spool.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:]),
            .stagingOnly
        )

        try FileManager.default.removeItem(at: spool.stagingDirectoryURL)
        let salvage = spool.salvageDirectoryURL
            .appendingPathComponent("test", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: salvage, withIntermediateDirectories: true)
        XCTAssertEqual(
            try spool.verifyOwnership(expectedManifest: manifest, expectedPayloadSourceURLs: [:]),
            .salvageOnly
        )
    }

    @MainActor func testImmutableManifestFieldsConflict() throws {
        let mutations: [(String, (inout TransferManifest) -> Void)] = [
            ("platform", { $0.observerIngest?.platform = "other" }),
            ("endpoint", { $0.endpoint.path = "/other" }),
            ("segment", { $0.observerIngest?.segment = "other" }),
            ("day", { $0.observerIngest?.day = "other" }),
            ("startedAt", { if let startedAt = $0.observerIngest?.startedAt { $0.observerIngest?.startedAt = startedAt.addingTimeInterval(1) } }),
            ("durationS", { $0.observerIngest?.durationS += 1 }),
            ("sources", { $0.observerIngest?.sources = ["other"] }),
            ("chunkIndex", { $0.observerIngest?.chunkIndex = 99 }),
            ("sessionID", { $0.observerIngest?.sessionID = UUID() }),
            ("modeRawValue", { $0.observerIngest?.modeRawValue = "other" }),
            ("ingestProtocolVersion", { $0.observerIngest?.ingestProtocolVersion = 2 }),
            ("payload", { $0.payloadParts[0].contentType = "application/octet-stream" }),
            ("omi metadata", { $0.meta = .object(["omi": .object(["connectionState": .string("other")])]) }),
        ]
        for (name, mutate) in mutations {
            let root = self.rootURL.appendingPathComponent(name, isDirectory: true)
            let spool = TransferSpool(rootURL: root)
            var expected = self.manifest()
            expected.meta = .object(["omi": .object(["connectionState": .string("original")])])
            let committed = try spool.commitStagedItem(itemID: spool.stage(
                manifest: expected,
                payloads: ["audio": Data("audio".utf8)]
            ).item.manifest.itemID)
            var stored = committed.manifest
            mutate(&stored)
            try spool.writeManifestAtomically(stored, in: committed.directoryURL)
            XCTAssertEqual(try spool.verifyOwnership(expectedManifest: expected, expectedPayloadSourceURLs: [:]), .conflict(.manifestMismatch), name)
        }
    }

    @MainActor func testEachMutableFieldStillProvesOwnership() throws {
        let mutations: [(String, (inout TransferManifest) -> Void)] = [
            ("disk state", { $0.diskState = .attention }),
            ("next attempt", { $0.nextAttemptAt = Date() }),
            ("attention", { $0.attention = TransferAttentionInfo(reason: "held", shortDetail: "held", movedAt: Date()) }),
            ("app version", { $0.appVersion = "99" }),
        ]
        for (name, mutate) in mutations {
            let spool = TransferSpool(rootURL: self.rootURL.appendingPathComponent(name, isDirectory: true))
            let expected = self.manifest()
            let committed = try spool.commitStagedItem(itemID: spool.stage(manifest: expected, payloads: ["audio": Data("audio".utf8)]).item.manifest.itemID)
            var stored = committed.manifest
            mutate(&stored)
            try spool.writeManifestAtomically(stored, in: committed.directoryURL)
            XCTAssertEqual(try spool.verifyOwnership(expectedManifest: expected, expectedPayloadSourceURLs: [:]), .ownedInQueued, name)
        }
    }

    @MainActor func testQueuedAndAttentionTwinsAlwaysConflictBeforeProof() throws {
        for mismatchedAttention in [false, true] {
            let spool = TransferSpool(rootURL: self.rootURL.appendingPathComponent("twins-\(mismatchedAttention)", isDirectory: true))
            let expected = self.manifest()
            let queued = try spool.commitStagedItem(itemID: spool.stage(manifest: expected, payloads: ["audio": Data("audio".utf8)]).item.manifest.itemID)
            let attentionURL = spool.attentionDirectoryURL.appendingPathComponent(expected.itemID.uuidString, isDirectory: true)
            try FileManager.default.copyItem(at: queued.directoryURL, to: attentionURL)
            if mismatchedAttention {
                var mismatch = queued.manifest
                mismatch.endpoint.path = "/mismatch"
                try spool.writeManifestAtomically(mismatch, in: attentionURL)
            }
            XCTAssertEqual(try spool.verifyOwnership(expectedManifest: expected, expectedPayloadSourceURLs: [:]), .conflict(.ownerConflict))
        }
    }

    @MainActor func testEverySalvageShapeIsNeverOwned() throws {
        enum Shape: CaseIterable { case empty, malformed, wrongID, wrongSource, canonical, metadata, missingPayload, differentPayload, valid }
        for shape in Shape.allCases {
            let spool = TransferSpool(rootURL: self.rootURL.appendingPathComponent("salvage-\(shape)", isDirectory: true))
            var expected = self.manifest()
            expected.meta = .object(["omi": .object(["connectionState": .string("original")])])
            let salvage = spool.salvageDirectoryURL.appendingPathComponent("test", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(expected.itemID.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: salvage, withIntermediateDirectories: true)
            switch shape {
            case .empty: break
            case .malformed: try Data("bad".utf8).write(to: salvage.appendingPathComponent(TransferSpool.manifestFilename))
            default:
                var candidate = expected
                if shape == .wrongID { candidate.itemID = UUID() }
                if shape == .wrongSource { candidate.source = "other" }
                if shape == .canonical { candidate.endpoint.path = "/other" }
                if shape == .metadata { candidate.meta = .object(["omi": .object(["connectionState": .string("other")])]) }
                try spool.writeManifestAtomically(candidate, in: salvage)
                if shape != .missingPayload {
                    let payload = shape == .differentPayload ? Data("other".utf8) : Data("audio".utf8)
                    try payload.write(to: salvage.appendingPathComponent("audio.m4a"))
                }
            }
            XCTAssertEqual(try spool.verifyOwnership(expectedManifest: expected, expectedPayloadSourceURLs: [:]), .salvageOnly, "\(shape)")
        }
    }

    @MainActor func testDigestMismatchAndReadFailuresAreUnproven() throws {
        let expected = self.manifest()
        try FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        let source = self.rootURL.appendingPathComponent("source.m4a")
        try Data("aaaaa".utf8).write(to: source)
        let spool = TransferSpool(rootURL: self.rootURL.appendingPathComponent("digest", isDirectory: true))
        let committed = try spool.commitStagedItem(itemID: spool.stage(manifest: expected, payloads: ["audio": Data("bbbbb".utf8)]).item.manifest.itemID)
        XCTAssertEqual(try spool.verifyOwnership(expectedManifest: expected, expectedPayloadSourceURLs: ["audio": source]), .conflict(.payloadMismatch))
        for failingPath in [source.path, committed.directoryURL.appendingPathComponent("audio.m4a").path] {
            let shared = TransferSpool(rootURL: spool.rootURL, fileSystem: ChunkReadFailingFileSystem(failingPath: failingPath))
            XCTAssertEqual(try shared.verifyOwnership(expectedManifest: expected, expectedPayloadSourceURLs: ["audio": source]), .conflict(.payloadUnreadable))
        }
    }

    @MainActor func testOwnershipNormalizesPersistedMetaKeyOrderAndNumber() throws {
        let spool = TransferSpool(rootURL: self.rootURL)
        var expected = self.manifest()
        expected.meta = .object([
            "omi": .object(["sequence": .int(1), "connectionState": .string("ready")]),
            "z": .string("last"),
        ])
        let committed = try spool.commitStagedItem(itemID: spool.stage(manifest: expected, payloads: ["audio": Data("audio".utf8)]).item.manifest.itemID)
        var persisted = committed.manifest
        persisted.meta = .object([
            "z": .string("last"),
            "omi": .object(["connectionState": .string("ready"), "sequence": .double(1.0)]),
        ])
        try spool.writeManifestAtomically(persisted, in: committed.directoryURL)
        XCTAssertEqual(try spool.verifyOwnership(expectedManifest: expected, expectedPayloadSourceURLs: [:]), .ownedInQueued)
    }

    @MainActor func testZeroPayloadAttentionSurvivesRestartAndQueuedCopyIsRejected() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let spool = TransferSpool(rootURL: self.rootURL)
        var attentionManifest = self.manifest()
        attentionManifest.payloadParts = []
        let attentionStaged = try spool.stage(manifest: attentionManifest, payloadFileURLs: [:])
        let attentionCommitted = try spool.commitStagedItem(itemID: attentionStaged.item.manifest.itemID)
        _ = try spool.moveQueuedItemToAttention(attentionCommitted, reason: "boundary", detail: "reason=boundary", now: Date())

        var queuedManifest = self.manifest()
        queuedManifest.payloadParts = []
        let queuedStaged = try spool.stage(manifest: queuedManifest, payloadFileURLs: [:])
        _ = try spool.commitStagedItem(itemID: queuedStaged.item.manifest.itemID)

        let snapshot = try spool.initialize()
        XCTAssertEqual(snapshot.attention.map(\.manifest.itemID), [attentionManifest.itemID])
        XCTAssertFalse(snapshot.queued.contains { $0.manifest.itemID == queuedManifest.itemID })

        let unrelatedID = UUID()
        let live = makeTransferCutoverHarness(
            rootURL: self.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferItemEvidenceAvailableResolver()
        )
        try await live.engine.initialize()
        _ = try await live.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: unrelatedID,
                sidecar: makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 92, startedAt: Date())
            ),
            payloads: ["audio": Data("unrelated".utf8)]
        )
        await live.engine.enableDispatch()
        try await transferTestWaitFor("queued control dispatch") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:)), [unrelatedID])
        let restartedSnapshot = await live.engine.itemSnapshots()
        XCTAssertTrue(restartedSnapshot.contains { $0.itemID == attentionManifest.itemID && $0.manifest.diskState == .attention })
        XCTAssertFalse(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:)).contains(attentionManifest.itemID))
    }

    @MainActor private func manifest() -> TransferManifest {
        let sessionID = UUID()
        return ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: UUID(),
            sidecar: makeTransferTestSidecar(sessionID: sessionID, chunkIndex: 0, startedAt: Date())
        )
    }
}

nonisolated private struct TransferItemEvidenceAvailableResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

private final class ChunkReadFailingFileSystem: TransferFileSystem, @unchecked Sendable {
    private let base = FoundationTransferFileSystem()
    private let failingPath: String
    init(failingPath: String) { self.failingPath = failingPath }
    func fileExists(atPath path: String) -> Bool { self.base.fileExists(atPath: path) }
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws { try self.base.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try self.base.contentsOfDirectory(at: url) }
    func removeItem(at url: URL) throws { try self.base.removeItem(at: url) }
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws { try self.base.moveItem(at: sourceURL, to: destinationURL) }
    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws { try self.base.replaceItem(at: originalURL, withItemAt: newURL) }
    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws { try self.base.write(data, to: url, options: options) }
    func data(contentsOf url: URL) throws -> Data { try self.base.data(contentsOf: url) }
    func byteCount(at url: URL) throws -> Int { try self.base.byteCount(at: url) }
    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        guard url.path != self.failingPath else { throw CocoaError(.fileReadUnknown) }
        try self.base.readChunks(at: url, chunkSize: chunkSize, consume)
    }

    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try self.base.writeStream(to: url, body)
    }
}
