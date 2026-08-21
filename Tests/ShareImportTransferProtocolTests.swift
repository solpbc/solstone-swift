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
                return try ShareImportSaveBody.build(item: item, spool: spool, observerHandle: "handle-1")
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
    func testSaveRetryFetchesHandlePerAttemptAndBypassesBodyCache() async throws {
        let itemID = Self.uuid(32)
        let handles = OSAllocatedUnfairLock<[String]>(initialState: [])
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
            let handle = handles.withLock { values -> String in
                let value = "handle-\(values.count + 1)"
                values.append(value)
                return value
            }
            return try ShareImportSaveBody.build(item: item, spool: spool, observerHandle: handle)
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
        XCTAssertEqual(handles.withLock { $0 }, ["handle-1", "handle-2"])
        XCTAssertEqual(TransferURLProtocol.bodies.count, 2)
        XCTAssertEqual(self.multipartValue(named: "observer_handle", in: TransferURLProtocol.bodies[0]), "handle-1")
        XCTAssertEqual(self.multipartValue(named: "observer_handle", in: TransferURLProtocol.bodies[1]), "handle-2")
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
                return try ShareImportSaveBody.build(item: item, spool: spool, observerHandle: "handle-1")
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
                return try ShareImportSaveBody.build(item: item, spool: spool, observerHandle: "handle-1")
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
    private func makeEngine(bodyBuilder: @escaping TransferBodyBuilder) -> TransferEngine {
        TransferEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("Transfers", isDirectory: true)),
            transport: TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration()),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate),
            maxConcurrent: 1,
            bodyBuilder: bodyBuilder
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
