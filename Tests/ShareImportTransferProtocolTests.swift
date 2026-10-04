// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ShareImportTransferProtocolTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareImportTransferProtocolTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        super.tearDown()
    }

    @MainActor
    func testSaveThenStartDispatchesSaveThenStartAndPassesSuccessKindToDeliveredHook() async throws {
        let itemID = Self.uuid(31)
        let delivered = OSAllocatedUnfairLock<[TransferSuccessKind]>(initialState: [])
        let bodiesByPath = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])
        TransferURLProtocol.handler = { request, body in
            if let path = request.url?.path {
                bodiesByPath.withLock { $0[path] = body }
            }
            switch request.url?.path {
            case "/imports/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"recommended_action":"start","path":"/imports/item","timestamp":"2026-07-09T00:00:00Z"}"#.utf8)
                )
            case "/imports/start":
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"status":"ok","task_id":"task-1"}"#.utf8)
                )
            default:
                XCTFail("Unexpected path \(request.url?.path ?? "nil")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let engine = self.makeEngine(bodyBuilder: { item, spool in
            if item.manifest.saveThenStart?.phase == .savePending {
                return try ShareImportSaveBody.build(item: item, spool: spool)
            }
            return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
        })
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { _, successKind in
            delivered.withLock { $0.append(successKind) }
        }
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareManifest(itemID: itemID, kind: .text),
            payloads: ["text": Data("hello".utf8)]
        )

        try await transferTestWaitFor("share delivered") {
            delivered.withLock { $0.count == 1 }
        }
        XCTAssertEqual(TransferURLProtocol.requests.map { $0.url?.path }, ["/imports/save", "/imports/start"])
        XCTAssertTrue(TransferURLProtocol.requests[0].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=Boundary-") == true)
        XCTAssertEqual(TransferURLProtocol.requests[1].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let startBody = try XCTUnwrap(bodiesByPath.withLock { $0["/imports/start"] })
        XCTAssertEqual(String(data: startBody, encoding: .utf8), #"{"path":"\/imports\/item","timestamp":"2026-07-09T00:00:00Z"}"#)
        XCTAssertEqual(
            delivered.withLock { $0.first },
            .delivered(serverPath: "/imports/item", serverTimestamp: "2026-07-09T00:00:00Z")
        )
    }

    @MainActor
    func testSaveRetryRebuildsBodyAndBypassesBodyCache() async throws {
        let itemID = Self.uuid(32)
        let bodyBuilds = OSAllocatedUnfairLock<Int>(initialState: 0)
        let saveAttempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let delivered = OSAllocatedUnfairLock<Int>(initialState: 0)
        TransferURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/imports/save")
            let attempt = saveAttempts.withLock { value in
                value += 1
                return value
            }
            if attempt == 1 {
                return (Self.response(for: request, statusCode: 503), Data())
            }
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/retry","timestamp":"2026-07-09T00:00:01Z"}"#.utf8)
            )
        }
        let engine = self.makeEngine(bodyBuilder: { item, spool in
            if item.manifest.saveThenStart?.phase != .savePending {
                return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
            }
            bodyBuilds.withLock { $0 += 1 }
            return try ShareImportSaveBody.build(item: item, spool: spool)
        })
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { _, _ in
            delivered.withLock { $0 += 1 }
        }
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareManifest(itemID: itemID, kind: .text),
            payloads: ["text": Data("retry text".utf8)]
        )

        try await transferTestWaitFor("retry delivered") {
            delivered.withLock { $0 == 1 }
        }
        XCTAssertEqual(saveAttempts.withLock { $0 }, 2)
        XCTAssertEqual(bodyBuilds.withLock { $0 }, 2)
        XCTAssertEqual(TransferURLProtocol.bodies.count, 2)
    }

    @MainActor
    func testSave413MovesToAttentionKeepsPayloadAndSkipsLedger() async throws {
        let itemID = Self.uuid(33)
        let payload = Data("keep-these-bytes".utf8)
        let hookCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let store = ShareImportStore(
            cacheRootURL: self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        )
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 413), Data("rejected".utf8))
        }
        let engine = self.makeEngine(bodyBuilder: { item, spool in
            if item.manifest.saveThenStart?.phase == .savePending {
                return try ShareImportSaveBody.build(item: item, spool: spool)
            }
            return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
        })
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { manifest, successKind in
            hookCount.withLock { $0 += 1 }
            try await MainActor.run {
                try store.recordDelivered(manifest: manifest, successKind: successKind)
            }
        }
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareManifest(itemID: itemID, kind: .file),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("share 413 attention") {
            await engine.snapshot().counters.attentionCount == 1
        }

        let snapshot = await engine.itemSnapshot(itemID: itemID)
        XCTAssertEqual(snapshot?.state, .attention)
        let attentionRaw = self.tempDirectory
            .appendingPathComponent("Transfers/\(TransferSpool.attentionDirectoryName)/\(itemID.uuidString)/raw.bin")
        XCTAssertEqual(try Data(contentsOf: attentionRaw), payload)
        XCTAssertEqual(try store.loadLedger().count, 0)
        XCTAssertEqual(hookCount.withLock { $0 }, 0)
    }

    @MainActor
    func testSave400ContentAlreadyImportedIsDeliveredNotAttention() async throws {
        let itemID = Self.uuid(90)
        let payload = Data("shared-twice-bytes".utf8)
        let store = ShareImportStore(
            cacheRootURL: self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        )
        TransferURLProtocol.handler = { request, _ in
            (
                Self.response(for: request, statusCode: 400),
                Data(#"{"error":"that action isn't available in the current state.","reason_code":"invalid_operation_for_state","detail":"content already imported"}"#.utf8)
            )
        }
        let engine = self.makeEngine(bodyBuilder: { item, spool in
            if item.manifest.saveThenStart?.phase == .savePending {
                return try ShareImportSaveBody.build(item: item, spool: spool)
            }
            return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
        })
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { manifest, successKind in
            try await MainActor.run {
                try store.recordDelivered(manifest: manifest, successKind: successKind)
            }
        }
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareManifest(itemID: itemID, kind: .file),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("share duplicate delivered") {
            await MainActor.run {
                (try? store.loadLedger()[itemID.uuidString.lowercased()]) != nil
            }
        }

        let counters = await engine.snapshot().counters
        XCTAssertEqual(counters.deliveredCount, 1)
        XCTAssertEqual(counters.attentionCount, 0)
        let attentionRaw = self.tempDirectory
            .appendingPathComponent("Transfers/\(TransferSpool.attentionDirectoryName)/\(itemID.uuidString)/raw.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: attentionRaw.path))
    }

    @MainActor
    func testSave200DoNotStartRemovesPayloadAndWritesLedger() async throws {
        let itemID = Self.uuid(34)
        let payload = Data("delivered-bytes".utf8)
        let store = ShareImportStore(
            cacheRootURL: self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        )
        TransferURLProtocol.handler = { request, _ in
            (
                Self.response(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/item","timestamp":"2026-07-09T00:00:02Z"}"#.utf8)
            )
        }
        let engine = self.makeEngine(bodyBuilder: { item, spool in
            if item.manifest.saveThenStart?.phase == .savePending {
                return try ShareImportSaveBody.build(item: item, spool: spool)
            }
            return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
        })
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { manifest, successKind in
            try await MainActor.run {
                try store.recordDelivered(manifest: manifest, successKind: successKind)
            }
        }
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareManifest(itemID: itemID, kind: .file),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("share 200 delivered") {
            await MainActor.run {
                (try? store.loadLedger()[itemID.uuidString.lowercased()]) != nil
            }
        }

        let deliveredCount = await engine.snapshot().counters.deliveredCount
        XCTAssertEqual(deliveredCount, 1)
        let queuedRaw = self.tempDirectory
            .appendingPathComponent("Transfers/\(TransferSpool.queuedDirectoryName)/\(itemID.uuidString)/raw.bin")
        let attentionRaw = self.tempDirectory
            .appendingPathComponent("Transfers/\(TransferSpool.attentionDirectoryName)/\(itemID.uuidString)/raw.bin")
        XCTAssertFalse(FileManager.default.fileExists(atPath: queuedRaw.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attentionRaw.path))
        XCTAssertNotNil(try store.loadLedger()[itemID.uuidString.lowercased()])
    }

    @MainActor
    func testImportSavedByEarlierJournalIsSavedAgainToNewlyPairedJournal() async throws {
        let itemID = Self.uuid(41)
        try self.seedStartPendingImport(itemID: itemID, followedPairing: "pairing-a")
        let delivered = OSAllocatedUnfairLock<[TransferSuccessKind]>(initialState: [])
        let startBodies = OSAllocatedUnfairLock<[String]>(initialState: [])
        TransferURLProtocol.handler = { request, body in
            switch request.url?.path {
            case "/imports/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"recommended_action":"start","path":"/journal-b/imports/item","timestamp":"2026-07-09T00:00:05Z"}"#.utf8)
                )
            case "/imports/start":
                let text = String(decoding: body, as: UTF8.self)
                startBodies.withLock { $0.append(text) }
                // A journal that never saved this item can answer an earlier journal's path this
                // way, and the app reads that answer as delivered.
                if text.contains("journal-a") {
                    return (
                        Self.response(for: request, statusCode: 400),
                        Data(#"{"error":"that action isn't available in the current state.","reason_code":"invalid_operation_for_state","detail":"content already imported; will not start"}"#.utf8)
                    )
                }
                return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok","task_id":"task-b"}"#.utf8))
            default:
                XCTFail("Unexpected path \(request.url?.path ?? "nil")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }
        let resolver = TransferEndpointResolverStub(.unavailable("journal-send-held"))
        let engine = self.makeEngine(resolver: resolver, bodyBuilder: Self.shareBodyBuilder)
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { _, successKind in
            delivered.withLock { $0.append(successKind) }
        }

        // The app can report the connection before the engine has loaded the spool.
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-b")
        try await engine.start()
        await engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(TransferURLProtocol.requests.count, 0, "nothing is sent before the new journal's mark is confirmed")
        let heldValue = await engine.itemSnapshot(itemID: itemID)
        let held = try XCTUnwrap(heldValue)
        XCTAssertEqual(held.state, .queued)
        XCTAssertEqual(held.manifest.saveThenStart, TransferSaveThenStartState(phase: .savePending))
        XCTAssertEqual(self.makeSpool().followedPairing(), "pairing-b")

        resolver.setResolution(.available(Self.endpoint))
        await engine.endpointAvailabilityChanged()
        try await transferTestWaitFor("import delivered to the new journal") {
            delivered.withLock { $0.count == 1 }
        }
        XCTAssertEqual(TransferURLProtocol.requests.map { $0.url?.path }, ["/imports/save", "/imports/start"])
        XCTAssertEqual(startBodies.withLock { $0 }, [#"{"path":"\/journal-b\/imports\/item","timestamp":"2026-07-09T00:00:05Z"}"#])
        XCTAssertEqual(
            delivered.withLock { $0.first },
            .delivered(serverPath: "/journal-b/imports/item", serverTimestamp: "2026-07-09T00:00:05Z")
        )
    }

    @MainActor
    func testImportSavedBySameJournalStartsWithoutSavingAgainOnReconnect() async throws {
        let itemID = Self.uuid(42)
        try self.seedStartPendingImport(itemID: itemID, followedPairing: "pairing-a")
        let delivered = OSAllocatedUnfairLock<Int>(initialState: 0)
        TransferURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/imports/start")
            return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok","task_id":"task-a"}"#.utf8))
        }
        let engine = self.makeEngine(bodyBuilder: Self.shareBodyBuilder)
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { _, _ in
            delivered.withLock { $0 += 1 }
        }
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-a")
        try await engine.start()

        try await transferTestWaitFor("import started on the same journal") {
            delivered.withLock { $0 == 1 }
        }
        XCTAssertEqual(TransferURLProtocol.requests.map { $0.url?.path }, ["/imports/start"])
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(TransferURLProtocol.bodies.first), as: UTF8.self),
            #"{"path":"\/journal-a\/imports\/item","timestamp":"2026-07-09T00:00:00Z"}"#
        )
    }

    func testDroppedLegacySaveNuancesAreNotReimplemented() {
        let mismatchedEcho = Data(#"{"recommended_action":"do_not_start","path":"/imports/item","timestamp":"2026-07-09T00:00:00Z","client_item_id":"different"}"#.utf8)
        XCTAssertEqual(
            TransferHTTPClassifier.classify(
                result: TransferHTTPResult(statusCode: 200, data: mismatchedEcho),
                endpointPhase: .save
            ),
            .terminalSuccess(.delivered(serverPath: "/imports/item", serverTimestamp: "2026-07-09T00:00:00Z"))
        )
        XCTAssertEqual(
            TransferHTTPClassifier.classify(
                result: TransferHTTPResult(statusCode: nil, issue: .cancelled),
                endpointPhase: .save
            ),
            .transientRetry(.cancelled)
        )
    }

    @MainActor
    private func makeEngine(
        resolver: TransferEndpointResolverStub = TransferEndpointResolverStub(.available(ShareImportTransferProtocolTests.endpoint)),
        bodyBuilder: @escaping TransferBodyBuilder
    ) -> TransferEngine {
        TransferEngine(
            spool: self.makeSpool(),
            transport: TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration()),
            endpointResolver: resolver,
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate),
            maxConcurrent: 1,
            bodyBuilder: bodyBuilder
        )
    }

    private static let endpoint = TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)

    private static let shareBodyBuilder: TransferBodyBuilder = { item, spool in
        if item.manifest.saveThenStart?.phase == .savePending {
            return try ShareImportSaveBody.build(item: item, spool: spool)
        }
        return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
    }

    private func makeSpool() -> TransferSpool {
        TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("Transfers", isDirectory: true))
    }

    /// A share import the journal paired as `followedPairing` saved, with its START
    /// body already cached, still waiting to be started.
    private func seedStartPendingImport(itemID: UUID, followedPairing: String) throws {
        let spool = self.makeSpool()
        try spool.recordFollowedPairing(followedPairing)
        var manifest = self.shareManifest(itemID: itemID, kind: .text)
        manifest.saveThenStart = TransferSaveThenStartState(
            phase: .startPending,
            savedPath: "/journal-a/imports/item",
            savedTimestamp: "2026-07-09T00:00:00Z",
            recommendedAction: TransferRecommendedAction.start.rawValue
        )
        let staged = try spool.stage(manifest: manifest, payloads: ["text": Data("shared before the re-pair".utf8)])
        let queued = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        _ = try spool.writeBodyCache(
            Data(#"{"path":"\/journal-a\/imports\/item","timestamp":"2026-07-09T00:00:00Z"}"#.utf8),
            for: queued
        )
    }

    private func shareManifest(itemID: UUID, kind: TransferPayloadKind) -> TransferManifest {
        let partID = kind == .text ? "text" : "file"
        return TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: Self.baseDate,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: partID,
                    kind: kind,
                    relativePath: "raw.bin",
                    filename: kind == .text ? "text.txt" : "document.pdf",
                    contentType: kind == .text ? "text/plain" : "application/pdf"
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: "/imports/save",
                startPath: "/imports/start"
            ),
            meta: ShareImportTransferMetadata.meta(fields: ShareImportTransferMetadata.Fields(
                basis: "file",
                contentType: kind == .text ? "text/plain" : "application/pdf",
                targetJournal: "",
                filename: kind == .text ? "note.txt" : "document.pdf",
                originApp: nil,
                itemTime: "2026-07-09T00:00:00Z",
                bytes: nil,
                requestSource: kind == .text ? "quick" : "file"
            )),
            saveThenStart: TransferSaveThenStartState(phase: .savePending)
        )
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    private static let baseDate = Date(timeIntervalSince1970: 1_783_536_000)

    private static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
