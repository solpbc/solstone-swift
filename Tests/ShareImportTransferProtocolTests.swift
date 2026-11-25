// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Crypto
import Foundation
import Network
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
    func testSave401And403HoldImportQueueWithoutMovingToAttentionAndResumeAfterReconnect() async throws {
        for statusCode in [401, 403] {
            TransferURLProtocol.reset()
            let item1ID = Self.uuid(statusCode * 10 + 1)
            let item2ID = Self.uuid(statusCode * 10 + 2)
            let payload1 = Data("first-import-\(statusCode)".utf8)
            let payload2 = Data("second-import-\(statusCode)".utf8)
            let rejectAuth = OSAllocatedUnfairLock<Bool>(initialState: true)
            let saveRequests = OSAllocatedUnfairLock<Int>(initialState: 0)

            TransferURLProtocol.handler = { request, _ in
                saveRequests.withLock { $0 += 1 }
                if rejectAuth.withLock({ $0 }) {
                    return (Self.response(for: request, statusCode: statusCode), Data("unauthorized".utf8))
                }
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"recommended_action":"do_not_start","path":"/imports/ok","timestamp":"2026-07-09T00:00:10Z"}"#.utf8)
                )
            }

            let root = self.tempDirectory.appendingPathComponent("auth-hold-\(statusCode)", isDirectory: true)
            let mirror = TransferStatusMirror()
            let engine = TransferEngine(
                spool: TransferSpool(rootURL: root.appendingPathComponent("Transfers", isDirectory: true)),
                transport: TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration()),
                endpointResolver: TransferEndpointResolverStub(.available(Self.endpoint)),
                pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
                clock: FakeTransferClock(wall: Self.baseDate),
                statusMirror: mirror,
                maxConcurrent: 1,
                bodyBuilder: Self.shareBodyBuilder
            )
            let store = ShareImportStore(cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true))
            let holder = ShareTransferHolder(transferEngine: engine, mirror: mirror, store: store)
            try await engine.start()

            var firstManifest = self.shareManifest(itemID: item1ID, kind: .file)
            firstManifest.createdAt = Self.baseDate
            var secondManifest = self.shareManifest(itemID: item2ID, kind: .file)
            secondManifest.createdAt = Self.baseDate.addingTimeInterval(1)

            _ = try await engine.enqueue(manifest: firstManifest, payloads: ["file": payload1])
            _ = try await engine.enqueue(manifest: secondManifest, payloads: ["file": payload2])

            try await transferTestWaitFor("auth hold on \(statusCode)") {
                await MainActor.run { holder.isPairingRefused }
            }
            // Give the actor a brief turn to verify item 2 is never dispatched while held.
            try await Task.sleep(for: .milliseconds(80))

            let heldSnapshot = await engine.snapshot()
            XCTAssertEqual(saveRequests.withLock { $0 }, 1, "item 2 must not be attempted once \(statusCode) holds the queue")
            XCTAssertEqual(heldSnapshot.counters.queuedCount, 2)
            XCTAssertEqual(heldSnapshot.counters.attentionCount, 0)
            XCTAssertEqual(heldSnapshot.counters.inFlightCount, 0)
            XCTAssertEqual(heldSnapshot.sources[ObserverAudioTransferSource.share]?.authHeld, true)
            let item1State = await engine.itemSnapshot(itemID: item1ID)?.state
            let item2State = await engine.itemSnapshot(itemID: item2ID)?.state
            XCTAssertEqual(item1State, .held)
            XCTAssertEqual(item2State, .held)
            XCTAssertTrue(holder.isPairingRefused)
            XCTAssertEqual(holder.failedCount, 0)
            XCTAssertEqual(holder.pendingCount, 2)
            XCTAssertEqual(holder.unsendableCount, 2)
            XCTAssertEqual(
                ImportQueueHoldPresentation.holdLine(
                    isPaired: true,
                    isPairingRefused: holder.isPairingRefused,
                    awaitingMarkConfirmation: false,
                    isConnected: true
                ),
                AppStrings.ios_app_importholdrefused()
            )
            // Local bytes remain intact on disk.
            let raw1URL = await engine.payloadFileURL(itemID: item1ID, partID: "file")
            let raw2URL = await engine.payloadFileURL(itemID: item2ID, partID: "file")
            let raw1 = try XCTUnwrap(raw1URL)
            let raw2 = try XCTUnwrap(raw2URL)
            XCTAssertEqual(try Data(contentsOf: raw1), payload1)
            XCTAssertEqual(try Data(contentsOf: raw2), payload2)

            // Re-pairing / reconnecting clears the hold and drains both queued imports.
            rejectAuth.withLock { $0 = false }
            holder.clearPairingRefused()
            await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-fixed")
            await engine.endpointAvailabilityChanged()

            try await transferTestWaitFor("auth hold resumed and drained \(statusCode)") {
                await engine.snapshot().counters.deliveredCount == 2
            }
            XCTAssertFalse(holder.isPairingRefused)
            let resumedAttention = await engine.snapshot().counters.attentionCount
            XCTAssertEqual(resumedAttention, 0)
            XCTAssertEqual(saveRequests.withLock { $0 }, 3)
            await engine.pause()
        }
    }

    @MainActor
    func testStart401HoldsImportQueueWithSavedStateIntactAndResumesOnReconnect() async throws {
        let item1ID = Self.uuid(411)
        let item2ID = Self.uuid(412)
        let startRejects = OSAllocatedUnfairLock<Bool>(initialState: true)
        let pathsSeen = OSAllocatedUnfairLock<[String]>(initialState: [])

        TransferURLProtocol.handler = { request, _ in
            let path = request.url?.path ?? ""
            pathsSeen.withLock { $0.append(path) }
            switch path {
            case "/imports/save":
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"recommended_action":"start","path":"/imports/saved","timestamp":"2026-07-09T00:00:11Z"}"#.utf8)
                )
            case "/imports/start":
                if startRejects.withLock({ $0 }) {
                    return (Self.response(for: request, statusCode: 401), Data("unauthorized".utf8))
                }
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"status":"ok","task_id":"task-401"}"#.utf8)
                )
            default:
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }

        let mirror = TransferStatusMirror()
        let engine = TransferEngine(
            spool: self.makeSpool(),
            transport: TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration()),
            endpointResolver: TransferEndpointResolverStub(.available(Self.endpoint)),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate),
            statusMirror: mirror,
            maxConcurrent: 1,
            bodyBuilder: Self.shareBodyBuilder
        )
        try await engine.start()

        var m1 = self.shareManifest(itemID: item1ID, kind: .file)
        m1.createdAt = Self.baseDate
        var m2 = self.shareManifest(itemID: item2ID, kind: .file)
        m2.createdAt = Self.baseDate.addingTimeInterval(1)
        _ = try await engine.enqueue(manifest: m1, payloads: ["file": Data("one".utf8)])
        _ = try await engine.enqueue(manifest: m2, payloads: ["file": Data("two".utf8)])

        try await transferTestWaitFor("start 401 auth hold") {
            await engine.snapshot().sources[ObserverAudioTransferSource.share]?.authHeld == true
        }
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertEqual(pathsSeen.withLock { $0 }, ["/imports/save", "/imports/start"])
        let startHeldAttention = await engine.snapshot().counters.attentionCount
        let item1Phase = await engine.itemSnapshot(itemID: item1ID)?.manifest.saveThenStart?.phase
        XCTAssertEqual(startHeldAttention, 0)
        XCTAssertEqual(item1Phase, .startPending)

        startRejects.withLock { $0 = false }
        await engine.noteNewConnectionEstablished(pairingIdentity: "same-pairing")
        await engine.endpointAvailabilityChanged()

        try await transferTestWaitFor("start 401 resumed and drained") {
            await engine.snapshot().counters.deliveredCount == 2
        }
        await engine.pause()
    }

    @MainActor
    func testSave413RemainsPerItemAttentionWithoutHoldingSiblingImport() async throws {
        let oversizedID = Self.uuid(4131)
        let normalID = Self.uuid(4132)
        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)

        TransferURLProtocol.handler = { request, _ in
            let index = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            if index == 1 {
                return (
                    Self.response(for: request, statusCode: 413),
                    Data(#"{"error":"that file is too large to bring in.","reason_code":"multipart_part_too_large"}"#.utf8)
                )
            }
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/sibling","timestamp":"2026-07-09T00:00:12Z"}"#.utf8)
            )
        }

        let mirror = TransferStatusMirror()
        let engine = TransferEngine(
            spool: self.makeSpool(),
            transport: TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration()),
            endpointResolver: TransferEndpointResolverStub(.available(Self.endpoint)),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate),
            statusMirror: mirror,
            maxConcurrent: 1,
            bodyBuilder: Self.shareBodyBuilder
        )
        try await engine.start()

        var m1 = self.shareManifest(itemID: oversizedID, kind: .file)
        m1.createdAt = Self.baseDate
        var m2 = self.shareManifest(itemID: normalID, kind: .file)
        m2.createdAt = Self.baseDate.addingTimeInterval(1)
        _ = try await engine.enqueue(manifest: m1, payloads: ["file": Data("too-big".utf8)])
        _ = try await engine.enqueue(manifest: m2, payloads: ["file": Data("fine".utf8)])

        try await transferTestWaitFor("413 attention and sibling delivered") {
            let counters = await engine.snapshot().counters
            return counters.attentionCount == 1 && counters.deliveredCount == 1
        }

        let snap = await engine.snapshot()
        XCTAssertEqual(snap.sources[ObserverAudioTransferSource.share]?.authHeld, false)
        let oversizedState = await engine.itemSnapshot(itemID: oversizedID)?.state
        XCTAssertEqual(oversizedState, .attention)
        await engine.pause()
    }

    @MainActor
    func testSave403FromLoopbackProxyRetriesWithoutTrippingPairingRefusal() async throws {
        let itemID = Self.uuid(4039)
        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)

        TransferURLProtocol.handler = { request, _ in
            let index = attempts.withLock { count -> Int in
                count += 1
                return count
            }
            if index == 1 {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["X-SPL-Loopback-Refused": "missing"]
                )!
                return (response, Data("refused: missing local secret\n".utf8))
            }
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/after-loopback","timestamp":"2026-07-09T00:00:13Z"}"#.utf8)
            )
        }

        let mirror = TransferStatusMirror()
        let engine = TransferEngine(
            spool: self.makeSpool(),
            transport: TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration()),
            endpointResolver: TransferEndpointResolverStub(.available(Self.endpoint)),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            clock: FakeTransferClock(wall: Self.baseDate),
            statusMirror: mirror,
            maxConcurrent: 1,
            bodyBuilder: Self.shareBodyBuilder
        )
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareManifest(itemID: itemID, kind: .file),
            payloads: ["file": Data("loopback-retry".utf8)]
        )

        try await transferTestWaitFor("loopback 403 retried and delivered") {
            await engine.snapshot().counters.deliveredCount == 1
        }

        let snap = await engine.snapshot()
        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertEqual(snap.counters.attentionCount, 0)
        XCTAssertEqual(snap.sources[ObserverAudioTransferSource.share]?.authHeld, false)
        await engine.pause()
    }

    @MainActor
    func testFileSaveAndRetryStreamFromCustodyWithoutCreatingBodySpool() async throws {
        let itemID = Self.uuid(35)
        let payload = Data((0..<(256 * 1024)).map { UInt8($0 & 0xFF) })
        let spoolRoot = self.tempDirectory.appendingPathComponent("Transfers", isDirectory: true)
        let bodyUploadURL = spoolRoot
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent("body.upload", isDirectory: false)
        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let bodySpoolSeenOnAttempt = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        let delivered = OSAllocatedUnfairLock<Int>(initialState: 0)

        TransferURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.url?.path, "/imports/save")
            bodySpoolSeenOnAttempt.withLock {
                $0.append(FileManager.default.fileExists(atPath: bodyUploadURL.path))
            }
            let attempt = attempts.withLock { count in
                count += 1
                return count
            }
            if attempt == 1 {
                return (Self.response(for: request, statusCode: 503), Data())
            }
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/streamed","timestamp":"2026-07-09T00:00:05Z"}"#.utf8)
            )
        }

        let engine = self.makeEngine(bodyBuilder: Self.shareBodyBuilder)
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { _, _ in
            delivered.withLock { $0 += 1 }
        }
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareManifest(itemID: itemID, kind: .file),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("streamed file retry delivered") {
            delivered.withLock { $0 == 1 }
        }

        XCTAssertEqual(attempts.withLock { $0 }, 2)
        XCTAssertEqual(bodySpoolSeenOnAttempt.withLock { $0 }, [false, false])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyUploadURL.path))
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        XCTAssertEqual(TransferURLProtocol.bodies.count, 2)
        for (index, request) in TransferURLProtocol.requests.enumerated() {
            let receivedBody = TransferURLProtocol.bodies[index]
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Content-Length"),
                "\(receivedBody.count)"
            )
            XCTAssertTrue(receivedBody.range(of: payload) != nil)
        }
    }

    @MainActor
    func testLiveLoopbackStreamedUploadPreservesExactBytesContentLengthAndZeroSpoolCopy() async throws {
        let itemID = Self.uuid(36)
        // 4 MiB payload (64x the 64 KiB bound-stream buffer) exercises real kernel loopback flow control.
        let byteCount = 4 * 1024 * 1024
        var payload = Data(count: byteCount)
        payload.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for idx in 0..<byteCount {
                bytes[idx] = UInt8((idx &* 31 &+ 17) & 0xFF)
            }
        }
        let expectedDigest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        let spool = self.makeSpool()
        let staged = try spool.stage(
            manifest: self.shareManifest(itemID: itemID, kind: .file),
            payloads: ["file": payload]
        )
        let queued = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        let built = try ShareImportSaveBody.build(item: queued, spool: spool)
        guard case .streamed(let streamed) = built else {
            XCTFail("expected .streamed save body")
            return
        }
        XCTAssertFalse(spool.bodyCacheExists(for: queued))

        let server = try await LoopbackMultipartCaptureServer.start(
            responseStatus: "200 OK",
            responseBody: Data(#"{"recommended_action":"do_not_start","path":"/imports/live","timestamp":"2026-07-09T00:00:06Z"}"#.utf8)
        )
        defer { server.stop() }

        let transport = TransferTransport(sessionConfiguration: .ephemeral)
        defer { transport.invalidateAndCancel() }
        let endpoint = TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        let result = await transport.send(
            item: queued,
            body: .streamed(streamed),
            endpoint: endpoint,
            phase: .save
        )

        XCTAssertEqual(result.statusCode, 200)
        XCTAssertNil(result.issue)
        XCTAssertFalse(spool.bodyCacheExists(for: queued))

        let captured = try await server.capturedRequest()
        XCTAssertEqual(captured.headers["content-length"], "\(streamed.contentLength)")
        XCTAssertNil(captured.headers["transfer-encoding"])
        XCTAssertEqual(Int64(captured.body.count), streamed.contentLength)
        let expectedWire = try streamed.materialize()
        XCTAssertEqual(captured.body.count, expectedWire.count)
        let fileHeaderEnd = try XCTUnwrap(captured.body.range(of: Data("Content-Type: application/pdf\r\n\r\n".utf8))?.upperBound)
        let fileRangeEnd = fileHeaderEnd + payload.count
        XCTAssertLessThanOrEqual(fileRangeEnd, captured.body.count)
        let receivedPayload = captured.body[fileHeaderEnd..<fileRangeEnd]
        let actualDigest = SHA256.hash(data: receivedPayload).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(actualDigest, expectedDigest)
    }

    @MainActor
    func testLiveLoopbackStreamedUploadCancellationUnblocksCleanly() async throws {
        let itemID = Self.uuid(37)
        let payload = Data(repeating: 0x5A, count: 4 * 1024 * 1024)
        let spool = self.makeSpool()
        let staged = try spool.stage(
            manifest: self.shareManifest(itemID: itemID, kind: .file),
            payloads: ["file": payload]
        )
        let queued = try spool.commitStagedItem(itemID: staged.item.manifest.itemID)
        guard case .streamed(let streamed) = try ShareImportSaveBody.build(item: queued, spool: spool) else {
            XCTFail("expected .streamed save body")
            return
        }

        let server = try await LoopbackMultipartCaptureServer.startStalled()
        defer { server.stop() }

        let transport = TransferTransport(sessionConfiguration: .ephemeral)
        defer { transport.invalidateAndCancel() }
        let endpoint = TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:\(server.port)")!)

        let sendTask = Task {
            await transport.send(
                item: queued,
                body: .streamed(streamed),
                endpoint: endpoint,
                phase: .save
            )
        }
        try await server.waitForConnectionAccepted()
        sendTask.cancel()
        let result = await sendTask.value

        XCTAssertNil(result.statusCode)
        XCTAssertEqual(result.issue, .cancelled)
        XCTAssertFalse(spool.bodyCacheExists(for: queued))
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

private nonisolated struct CapturedLoopbackHTTPRequest: Sendable {
    let headers: [String: String]
    let body: Data
}

private nonisolated final class LoopbackMultipartCaptureServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "solstone.test.loopback-stream-server")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var accepted = false
    private var acceptedContinuations: [CheckedContinuation<Void, Error>] = []
    private var captured: CapturedLoopbackHTTPRequest?
    private var captureContinuations: [CheckedContinuation<CapturedLoopbackHTTPRequest, Error>] = []
    private var portValue: UInt16 = 0
    var port: UInt16 {
        self.lock.withLock { self.portValue }
    }

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start(
        responseStatus: String,
        responseBody: Data
    ) async throws -> LoopbackMultipartCaptureServer {
        try await self.startServer(stalled: false, responseStatus: responseStatus, responseBody: responseBody)
    }

    static func startStalled() async throws -> LoopbackMultipartCaptureServer {
        try await self.startServer(stalled: true, responseStatus: "200 OK", responseBody: Data())
    }

    private static func startServer(
        stalled: Bool,
        responseStatus: String,
        responseBody: Data
    ) async throws -> LoopbackMultipartCaptureServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        let server = LoopbackMultipartCaptureServer(listener: listener)
        let queue = DispatchQueue(label: "solstone.test.loopback-stream-listener")
        listener.newConnectionHandler = { [weak server] connection in
            server?.handle(
                connection: connection,
                stalled: stalled,
                responseStatus: responseStatus,
                responseBody: responseBody
            )
        }
        let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue,
                       resumed.withLock({ let was = $0; $0 = true; return !was })
                    {
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if resumed.withLock({ let was = $0; $0 = true; return !was }) {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        server.lock.withLock { server.portValue = readyPort }
        return server
    }

    func waitForConnectionAccepted() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let alreadyAccepted: Bool = self.lock.withLock {
                if self.accepted { return true }
                self.acceptedContinuations.append(continuation)
                return false
            }
            if alreadyAccepted {
                continuation.resume()
            }
        }
    }

    func capturedRequest() async throws -> CapturedLoopbackHTTPRequest {
        try await withCheckedThrowingContinuation { continuation in
            let existing: CapturedLoopbackHTTPRequest? = self.lock.withLock {
                if let captured = self.captured { return captured }
                self.captureContinuations.append(continuation)
                return nil
            }
            if let existing {
                continuation.resume(returning: existing)
            }
        }
    }

    func stop() {
        let (conns, acceptWaiters, captureWaiters) = self.lock.withLock {
            let conns = self.connections
            let acceptWaiters = self.acceptedContinuations
            let captureWaiters = self.captureContinuations
            self.connections.removeAll()
            self.acceptedContinuations.removeAll()
            self.captureContinuations.removeAll()
            return (conns, acceptWaiters, captureWaiters)
        }
        for connection in conns {
            connection.cancel()
        }
        self.listener.cancel()
        for waiter in acceptWaiters {
            waiter.resume(throwing: CancellationError())
        }
        for waiter in captureWaiters {
            waiter.resume(throwing: CancellationError())
        }
    }

    private func handle(
        connection: NWConnection,
        stalled: Bool,
        responseStatus: String,
        responseBody: Data
    ) {
        let acceptWaiters: [CheckedContinuation<Void, Error>] = self.lock.withLock {
            self.connections.append(connection)
            self.accepted = true
            let waiters = self.acceptedContinuations
            self.acceptedContinuations.removeAll()
            return waiters
        }
        for waiter in acceptWaiters {
            waiter.resume()
        }
        connection.start(queue: self.queue)
        if stalled {
            return
        }
        let buffer = OSAllocatedUnfairLock<Data>(initialState: Data())
        let headerSeparator = Data("\r\n\r\n".utf8)
        func receiveNext() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    buffer.withLock { $0.append(data) }
                }
                let current = buffer.withLock { $0 }
                if let headerEnd = current.range(of: headerSeparator) {
                    let headerText = String(decoding: current[..<headerEnd.lowerBound], as: UTF8.self)
                    var headers: [String: String] = [:]
                    for line in headerText.split(separator: "\r\n").dropFirst() {
                        if let colon = line.firstIndex(of: ":") {
                            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                            headers[key] = value
                        }
                    }
                    let expectedLength = headers["content-length"].flatMap(Int.init) ?? 0
                    let bodyStart = headerEnd.upperBound
                    let receivedBody = current[bodyStart...]
                    if receivedBody.count >= expectedLength || isComplete || error != nil {
                        let captured = CapturedLoopbackHTTPRequest(
                            headers: headers,
                            body: Data(receivedBody.prefix(expectedLength))
                        )
                        self.recordCaptured(captured)
                        let reply = Data((
                            "HTTP/1.1 \(responseStatus)\r\n"
                                + "Content-Type: application/json\r\n"
                                + "Content-Length: \(responseBody.count)\r\n"
                                + "Connection: close\r\n\r\n"
                        ).utf8) + responseBody
                        connection.send(content: reply, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        return
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                receiveNext()
            }
        }
        receiveNext()
    }

    private func recordCaptured(_ request: CapturedLoopbackHTTPRequest) {
        let waiters: [CheckedContinuation<CapturedLoopbackHTTPRequest, Error>] = self.lock.withLock {
            self.captured = request
            let waiters = self.captureContinuations
            self.captureContinuations.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume(returning: request)
        }
    }
}
