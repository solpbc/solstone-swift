// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Crypto
import Foundation
import XCTest

nonisolated private struct AvailableOwnerConflictEndpointResolver: TransferEndpointResolver {
    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

@MainActor
final class TransferOwnerConflictPreflightTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferOwnerConflictPreflightTests-\(UUID().uuidString)", isDirectory: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    func testInitializeHoldsEveryRawDirectoryIdentityConflictWithoutMutation() async throws {
        for variant in ConflictVariant.allCases {
            let spool = TransferSpool(rootURL: self.rootURL.appendingPathComponent(variant.rawValue, isDirectory: true))
            let seeded = try self.seedConflict(variant: variant, spool: spool)
            let queuedBefore = try self.recursiveSHA256Map(at: seeded.queuedURL)
            let attentionBefore = try self.recursiveSHA256Map(at: seeded.attentionURL)

            let snapshot = try spool.initialize()

            XCTAssertEqual(snapshot.conflictedItemIDs, Set([seeded.itemID]), "variant=\(variant.rawValue)")
            XCTAssertFalse(snapshot.queued.contains { $0.manifest.itemID == seeded.itemID }, "variant=\(variant.rawValue)")
            XCTAssertFalse(snapshot.attention.contains { $0.manifest.itemID == seeded.itemID }, "variant=\(variant.rawValue)")
            let diagnostics = snapshot.recoveryDiagnostics.filter { $0.itemID == seeded.itemID }
            XCTAssertEqual(diagnostics.count, 1, "variant=\(variant.rawValue)")
            let diagnostic = try XCTUnwrap(diagnostics.first)
            XCTAssertEqual(diagnostic.previousState, .held, "variant=\(variant.rawValue)")
            XCTAssertEqual(diagnostic.nextState, .held, "variant=\(variant.rawValue)")
            XCTAssertEqual(diagnostic.outcome, .needsAttention, "variant=\(variant.rawValue)")
            XCTAssertEqual(diagnostic.detail, "reason=owner conflict", "variant=\(variant.rawValue)")
            XCTAssertFalse(diagnostic.detail.contains("audio"), "variant=\(variant.rawValue)")
            XCTAssertFalse(diagnostic.detail.contains("manifest"), "variant=\(variant.rawValue)")
            XCTAssertEqual(try self.recursiveSHA256Map(at: seeded.queuedURL), queuedBefore, "variant=\(variant.rawValue)")
            XCTAssertEqual(try self.recursiveSHA256Map(at: seeded.attentionURL), attentionBefore, "variant=\(variant.rawValue)")

            TransferURLProtocol.handler = { request, _ in
                (transferTestResponse(for: request, statusCode: 204), Data())
            }
            let harness = makeTransferCutoverHarness(
                rootURL: spool.rootURL,
                sessionConfiguration: makeTransferTestURLSessionConfiguration(),
                endpointResolver: AvailableOwnerConflictEndpointResolver()
            )
            try await harness.engine.initialize()
            await harness.engine.enableDispatch()
            XCTAssertEqual(TransferURLProtocol.requests.count, 0, "variant=\(variant.rawValue)")
            TransferURLProtocol.reset()
        }
    }

    func testEngineFailsClosedForConflictWhileUnrelatedItemsDropRetryAndDeliver() async throws {
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let spool = TransferSpool(rootURL: self.rootURL.appendingPathComponent("engine", isDirectory: true))
        let conflict = try self.seedConflict(variant: .identicalComplete, spool: spool)
        let queuedBefore = try self.recursiveSHA256Map(at: conflict.queuedURL)
        let attentionBefore = try self.recursiveSHA256Map(at: conflict.attentionURL)
        let droppedID = UUID()
        let deliverID = UUID()
        let retryID = UUID()
        _ = try self.commitWatchItem(itemID: droppedID, spool: spool, payload: Data("drop".utf8))
        _ = try self.commitWatchItem(itemID: deliverID, spool: spool, payload: Data("deliver".utf8))
        let retryQueued = try self.commitWatchItem(itemID: retryID, spool: spool, payload: Data("retry".utf8))
        _ = try spool.moveQueuedItemToAttention(retryQueued, reason: "held", detail: "held", now: Date())

        let harness = makeTransferCutoverHarness(
            rootURL: spool.rootURL,
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: AvailableOwnerConflictEndpointResolver()
        )
        try await harness.engine.initialize()
        await harness.engine.drop(itemID: conflict.itemID)
        try await harness.engine.retryAttention(itemID: conflict.itemID)
        try await harness.engine.retryAttention(source: ObserverAudioTransferSource.watch)
        await harness.engine.drop(itemID: droppedID)

        XCTAssertEqual(try self.recursiveSHA256Map(at: conflict.queuedURL), queuedBefore)
        XCTAssertEqual(try self.recursiveSHA256Map(at: conflict.attentionURL), attentionBefore)
        let conflictedSnapshot = await harness.engine.itemSnapshot(itemID: conflict.itemID)
        let droppedSnapshot = await harness.engine.itemSnapshot(itemID: droppedID)
        XCTAssertNil(conflictedSnapshot)
        XCTAssertNil(droppedSnapshot)

        await harness.engine.enableDispatch()
        try await transferTestWaitFor("unrelated owners dispatch") {
            TransferURLProtocol.requests.count == 2
        }
        let deliveredIDs = Set(TransferURLProtocol.requests.compactMap(transferTestBoundaryItemID(from:)))
        XCTAssertEqual(deliveredIDs, Set([deliverID, retryID]))
        XCTAssertFalse(deliveredIDs.contains(conflict.itemID))
        XCTAssertEqual(try self.recursiveSHA256Map(at: conflict.queuedURL), queuedBefore)
        XCTAssertEqual(try self.recursiveSHA256Map(at: conflict.attentionURL), attentionBefore)
    }

}

private extension TransferOwnerConflictPreflightTests {
    enum ConflictVariant: String, CaseIterable {
        case identicalComplete
        case mismatchedEvidence
        case queuedMissingRequiredPayload
        case missingManifest
        case malformedManifest
        case manifestItemIDMismatch
        case wrongDiskState
    }

    struct SeededConflict {
        let itemID: UUID
        let queuedURL: URL
        let attentionURL: URL
    }

    func seedConflict(variant: ConflictVariant, spool: TransferSpool) throws -> SeededConflict {
        let itemID = UUID()
        let queued = try self.commitWatchItem(itemID: itemID, spool: spool, payload: Data("queued-audio".utf8))
        let attentionURL = spool.attentionDirectoryURL.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try FileManager.default.copyItem(at: queued.directoryURL, to: attentionURL)
        let manifestURL = attentionURL.appendingPathComponent(TransferSpool.manifestFilename, isDirectory: false)

        switch variant {
        case .identicalComplete:
            break
        case .mismatchedEvidence:
            try Data("attention-audio".utf8).write(
                to: attentionURL.appendingPathComponent("audio.m4a", isDirectory: false),
                options: .atomic
            )
        case .queuedMissingRequiredPayload:
            try FileManager.default.removeItem(at: queued.directoryURL.appendingPathComponent("audio.m4a", isDirectory: false))
        case .missingManifest:
            try FileManager.default.removeItem(at: manifestURL)
        case .malformedManifest:
            try Data("not json".utf8).write(to: manifestURL, options: .atomic)
        case .manifestItemIDMismatch:
            var mismatched = try self.readManifest(at: manifestURL)
            mismatched.itemID = UUID()
            try spool.writeManifestAtomically(mismatched, in: attentionURL)
        case .wrongDiskState:
            let queuedManifestURL = queued.directoryURL.appendingPathComponent(TransferSpool.manifestFilename, isDirectory: false)
            let wrongState = try self.readManifest(at: queuedManifestURL).replacingDiskState(.attention)
            try spool.writeManifestAtomically(wrongState, in: queued.directoryURL)
        }

        return SeededConflict(itemID: itemID, queuedURL: queued.directoryURL, attentionURL: attentionURL)
    }

    func commitWatchItem(
        itemID: UUID,
        spool: TransferSpool,
        sidecar: ChunkSidecar? = nil,
        payload: Data
    ) throws -> TransferStoredItem {
        let resolvedSidecar = sidecar ?? makeTransferTestSidecar(sessionID: UUID(), chunkIndex: 0, startedAt: Date())
        let manifest = makeTransferTestWatchManifest(itemID: itemID, sidecar: resolvedSidecar)
        return try spool.commitStagedItem(itemID: spool.stage(manifest: manifest, payloads: ["audio": payload]).item.manifest.itemID)
    }

    func recursiveSHA256Map(at rootURL: URL) throws -> [String: String] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
            result[relativePath] = SHA256.hash(data: try Data(contentsOf: url))
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return result
    }

    func readManifest(at url: URL) throws -> TransferManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TransferManifest.self, from: Data(contentsOf: url))
    }
}
