// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Crypto
import Foundation
import Network
import os
import XCTest

nonisolated final class ResumableImportUploadTests: XCTestCase {
    private var tempDirectory = FileManager.default.temporaryDirectory

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResumableImportUploadTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        super.tearDown()
    }

    // MARK: - Capability gate & threshold

    @MainActor
    func testBelowAdvertisedThresholdUsesSinglePostSaveAndAtThresholdUsesResumable() async throws {
        let smallID = Self.uuid(1)
        let largeID = Self.uuid(2)
        let smallPayload = Self.deterministicData(count: 8 * 1024, seed: 1)
        let largePayload = Self.deterministicData(count: 150 * 1024, seed: 2)
        let largeSHA = ResumableFileReader.sha256Hex(of: largePayload)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 128 * 1024,
            chunkBytes: 64 * 1024
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let engine = self.makeEngine()
        let delivered = OSAllocatedUnfairLock<[UUID]>(initialState: [])
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { manifest, _ in
            delivered.withLock { $0.append(manifest.itemID) }
        }
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: smallID, filename: "small.bin", byteCount: smallPayload.count),
            payloads: ["file": smallPayload]
        )
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: largeID, filename: "large.bin", byteCount: largePayload.count),
            payloads: ["file": largePayload]
        )

        try await transferTestWaitFor("both small and large delivered") {
            delivered.withLock { $0.count == 2 }
        }

        let snapshot = state.withLock { $0 }
        XCTAssertEqual(snapshot.saveCount, 1)
        XCTAssertEqual(snapshot.createCount, 1)
        XCTAssertEqual(snapshot.putOffsets, [0, 64 * 1024, 128 * 1024])
        XCTAssertEqual(snapshot.commitCount, 1)
        XCTAssertEqual(snapshot.startCount, 2)
        XCTAssertEqual(snapshot.assembledSHA256[largeID.uuidString.lowercased()], largeSHA)
        XCTAssertEqual(snapshot.lastCreateDeviceNoun, "ipad")
        XCTAssertEqual(snapshot.lastCreateImportedVia, ShareImportOrigin.importedVia)
        let advertisedThreshold = await engine.snapshot().advertisedResumableThresholdBytes
        XCTAssertEqual(advertisedThreshold, 128 * 1024)
        await engine.pause()
    }

    @MainActor
    func testOlderJournalWithoutCapabilityFallsBackSilentlyToSinglePostSave() async throws {
        let itemID = Self.uuid(3)
        let payload = Self.deterministicData(count: 200 * 1024, seed: 3)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: false,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let engine = self.makeEngine()
        try await engine.start()
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "archive.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("fallback save delivered") {
            await engine.snapshot().counters.deliveredCount == 1
        }

        let snapshot = state.withLock { $0 }
        XCTAssertEqual(snapshot.saveCount, 1)
        XCTAssertEqual(snapshot.createCount, 0)
        XCTAssertEqual(snapshot.putOffsets, [])
        await engine.pause()
    }

    @MainActor
    func testUnprobed405OnCreateFallsBackSilentlyToSinglePostSave() async throws {
        let itemID = Self.uuid(4)
        let payload = Self.deterministicData(count: 150 * 1024, seed: 4)
        let saveCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let createCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        TransferURLProtocol.handler = { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", ImporterServerURL.uploadsPath):
                createCount.withLock { $0 += 1 }
                return (Self.response(for: request, statusCode: 405), Data())
            case ("POST", ImporterServerURL.savePath):
                saveCount.withLock { $0 += 1 }
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"recommended_action":"do_not_start","path":"/imports/fallback","timestamp":"20261125_120000"}"#.utf8)
                )
            default:
                XCTFail("Unexpected request \(request.httpMethod ?? "") \(request.url?.path ?? "")")
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }

        let stubProbe = StaticResumableProbe(result: .supported(ResumableImportConfig(
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            maxFileBytes: ResumableImportDefaults.maxFileBytes
        )))
        let engine = self.makeEngine(probe: stubProbe)
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "old.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("405 fallback delivered") {
            await engine.snapshot().counters.deliveredCount == 1
        }

        XCTAssertEqual(createCount.withLock { $0 }, 1)
        XCTAssertEqual(saveCount.withLock { $0 }, 1)
        let marked = await stubProbe.markedUnsupportedCount
        XCTAssertEqual(marked, 1)
        await engine.pause()
    }

    // MARK: - Pre-upload deduplication

    @MainActor
    func testCreateAlreadyStagedUnwrapsSaveResponseAndRunsStart() async throws {
        let itemID = Self.uuid(5)
        let payload = Self.deterministicData(count: 150 * 1024, seed: 5)
        let startCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let putCount = OSAllocatedUnfairLock<Int>(initialState: 0)

        TransferURLProtocol.handler = { request, _ in
            switch (request.httpMethod, request.url?.path) {
            case ("POST", ImporterServerURL.uploadsPath):
                let body = """
                {
                  "status": "already_staged",
                  "replay": true,
                  "save_response": {
                    "status": "staged",
                    "recommended_action": "start",
                    "path": "/imports/20261125_120001/export.zip",
                    "timestamp": "20261125_120001"
                  }
                }
                """
                return (Self.response(for: request, statusCode: 200), Data(body.utf8))
            case ("POST", ImporterServerURL.startPath):
                startCount.withLock { $0 += 1 }
                return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok","task_id":"task-staged"}"#.utf8))
            case ("PUT", _):
                putCount.withLock { $0 += 1 }
                return (Self.response(for: request, statusCode: 500), Data())
            default:
                return (Self.response(for: request, statusCode: 404), Data())
            }
        }

        let engine = self.makeEngine(probe: StaticResumableProbe(result: .supported(ResumableImportConfig(
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            maxFileBytes: ResumableImportDefaults.maxFileBytes
        ))))
        try await engine.start()
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "export.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("already_staged started and delivered") {
            await engine.snapshot().counters.deliveredCount == 1
        }
        XCTAssertEqual(putCount.withLock { $0 }, 0)
        XCTAssertEqual(startCount.withLock { $0 }, 1)
        await engine.pause()
    }

    @MainActor
    func testCreateAlreadyImportedCompletesWithoutUploadingBytes() async throws {
        let itemID = Self.uuid(6)
        let payload = Self.deterministicData(count: 150 * 1024, seed: 6)
        let deliveredKinds = OSAllocatedUnfairLock<[TransferSuccessKind]>(initialState: [])

        TransferURLProtocol.handler = { request, _ in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, ImporterServerURL.uploadsPath)
            let body = #"{"status":"already_imported","import_id":"20261125_120002","reason_code":"invalid_operation_for_state","kind":"already_imported"}"#
            return (Self.response(for: request, statusCode: 200), Data(body.utf8))
        }

        let engine = self.makeEngine(probe: StaticResumableProbe(result: .supported(ResumableImportConfig(
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            maxFileBytes: ResumableImportDefaults.maxFileBytes
        ))))
        await engine.registerDeliveredHook(sourceKey: ObserverAudioTransferSource.share) { _, kind in
            deliveredKinds.withLock { $0.append(kind) }
        }
        try await engine.start()
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "dup.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("already_imported delivered") {
            deliveredKinds.withLock { $0.count == 1 }
        }
        XCTAssertEqual(
            deliveredKinds.withLock { $0.first },
            .alreadyStartedOrComplete(serverPath: nil, serverTimestamp: "20261125_120002")
        )
        await engine.pause()
    }

    // MARK: - Chunk checksum retry, 409 offset resync (JSON + bodyless)

    @MainActor
    func testChunkChecksum422ResendsChunkAnd409OffsetMismatchAndBodyless409Resync() async throws {
        let itemID = Self.uuid(7)
        let payload = Self.deterministicData(count: 192 * 1024, seed: 7)
        let expectedSHA = ResumableFileReader.sha256Hex(of: payload)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            injectChunkChecksum422AtOffsets: [0],
            injectBodyless409AtCallIndex: 3
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let engine = self.makeEngine()
        try await engine.start()
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "chunks.bin", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("recovered chunk checksum & 409 delivered") {
            await engine.snapshot().counters.deliveredCount == 1
        }

        let snap = state.withLock { $0 }
        // Offset 0 failed 422 once and was resent; offset 64K got bodyless 409 -> GET resync -> resumed cleanly.
        XCTAssertEqual(snap.putOffsets.filter { $0 == 0 }.count, 2)
        XCTAssertGreaterThanOrEqual(snap.statusGetCount, 1)
        XCTAssertEqual(snap.assembledSHA256[itemID.uuidString.lowercased()], expectedSHA)
        await engine.pause()
    }

    // MARK: - Resume across restart, network switch, and relay restart (0 confirmed chunks re-sent)

    @MainActor
    func testResumeAcrossAppRelaunchAndNetworkSwitchNeverResendsConfirmedChunks() async throws {
        let itemID = Self.uuid(8)
        let payload = Self.deterministicData(count: 256 * 1024, seed: 8)
        let expectedSHA = ResumableFileReader.sha256Hex(of: payload)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            inject503AtPutOffsets: [128 * 1024]
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let spool = self.makeSpool()
        let resolver = MutableEndpointResolver(endpoint: Self.endpoint(port: 19001, instanceID: "journal-A"))
        let engine1 = self.makeEngine(spool: spool, endpointResolver: resolver, retrySteps: [60])
        try await engine1.start()
        await engine1.noteNewConnectionEstablished(pairingIdentity: "pairing-A")

        _ = try await engine1.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "resume.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        // Wait until first 2 chunks (128 KiB) are confirmed and chunk 3 hits 503 -> paused.
        try await transferTestWaitFor("paused after 128 KiB") {
            guard let snap = await engine1.itemSnapshot(itemID: itemID) else { return false }
            return snap.resumableProgress?.bytesSent == 128 * 1024
                && snap.resumableProgress?.phase == .paused
                && snap.state == .queued
        }
        await engine1.pause()

        // Verify persisted manifest on disk carries uploadID, remoteOffset == 128 KiB, and uploadInstanceID.
        let persisted = try spool.initialize(now: Self.baseDate).queued.first
        XCTAssertEqual(persisted?.manifest.saveThenStart?.resumable?.remoteOffset, 128 * 1024)
        XCTAssertEqual(persisted?.manifest.saveThenStart?.resumable?.uploadInstanceID, "journal-A")
        XCTAssertNotNil(persisted?.manifest.saveThenStart?.resumable?.uploadID)
        XCTAssertEqual(persisted?.manifest.saveThenStart?.resumable?.wholeFileSHA256, expectedSHA)

        // Simulate app relaunch + network switch to a new local loopback port for the SAME journal instance.
        await resolver.switchTo(Self.endpoint(port: 19002, instanceID: "journal-A"))
        let engine2 = self.makeEngine(spool: spool, endpointResolver: resolver, retrySteps: [0.01])
        try await engine2.start()
        await engine2.noteNewConnectionEstablished(pairingIdentity: "pairing-A")

        try await transferTestWaitFor("resumed upload delivered on new engine & port") {
            await engine2.snapshot().counters.deliveredCount == 1
        }

        let snap = state.withLock { $0 }
        // Confirmed chunks at offsets 0 and 64 KiB were NEVER re-sent after relaunch/reconnect!
        XCTAssertEqual(snap.putOffsets.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(snap.putOffsets.filter { $0 == 64 * 1024 }.count, 1)
        XCTAssertGreaterThanOrEqual(snap.statusGetCount, 1)
        XCTAssertEqual(snap.createCount, 1)
        XCTAssertEqual(snap.assembledSHA256[itemID.uuidString.lowercased()], expectedSHA)
        await engine2.pause()
    }

    @MainActor
    func testInterruptedChunkReconcilesAcrossRestartAndKeepsItsWorkingSize() async throws {
        let unit = 256 * 1024
        let id = Self.uuid(48)
        let payload = Self.deterministicData(count: 8 * unit, seed: 48)
        let journal = OSAllocatedUnfairLock(initialState: MockResumableJournalState(
            advertiseCapability: true, thresholdBytes: 64 * 1024, chunkBytes: 4 * unit
        ))
        let attempts = OSAllocatedUnfairLock(initialState: [Int]())
        let loseStatus = OSAllocatedUnfairLock(initialState: true)
        let routeAvailable = OSAllocatedUnfairLock(initialState: true)
        TransferURLProtocol.handler = { request, body in
            if request.httpMethod == "GET", request.url?.path.contains("/uploads/") == true,
               loseStatus.withLock({ value in
                   let first = value
                   value = false
                   return first
               }) {
                throw URLError(.timedOut)
            }
            guard request.httpMethod == "PUT" else {
                return Self.handleMockJournal(request: request, body: body, state: journal)
            }
            let number = attempts.withLock { calls in
                calls.append(body.count)
                return calls.count
            }
            if number == 1 {
                _ = Self.handleMockJournal(request: request, body: body, state: journal)
                routeAvailable.withLock { $0 = false }
                throw URLError(.networkConnectionLost) // A late result from the retired route, after journal storage.
            }
            if body.count > unit { throw URLError(number == 2 ? .networkConnectionLost : .timedOut) }
            return Self.handleMockJournal(request: request, body: body, state: journal)
        }
        let spool = self.makeSpool()
        let resolver = MutableEndpointResolver(endpoint: Self.endpoint(port: 19001, instanceID: "journal-A")) {
            routeAvailable.withLock { $0 }
        }
        let first = self.makeEngine(spool: spool, endpointResolver: resolver, retrySteps: [60])
        try await first.start()
        await first.noteNewConnectionEstablished(pairingIdentity: "pairing-A")
        _ = try await first.enqueue(
            manifest: self.shareFileManifest(itemID: id, filename: "relay.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )
        try await transferTestWaitFor("waiting for the lost acknowledgement") {
            await first.itemSnapshot(itemID: id)?.manifest.saveThenStart?.resumable?.interruptedChunkBytes == 4 * unit
        }
        await first.pause()
        let stored = try spool.initialize(now: Self.baseDate).queued.first?.manifest.saveThenStart?.resumable
        XCTAssertEqual(stored?.remoteOffset, 0)
        XCTAssertEqual(stored?.interruptedChunkBytes, 4 * unit)
        await resolver.switchTo(Self.endpoint(port: 19002, instanceID: "journal-A"))
        routeAvailable.withLock { $0 = true }
        let next = self.makeEngine(spool: spool, endpointResolver: resolver, retrySteps: [0.01])
        try await next.start()
        await next.noteNewConnectionEstablished(pairingIdentity: "pairing-A")
        try await transferTestWaitFor("delivered through the new relay connection") {
            await next.snapshot().counters.deliveredCount == 1
        }
        XCTAssertEqual(attempts.withLock { $0 }, [4 * unit, 4 * unit, 2 * unit, unit, unit, unit, unit])
        let receipt = journal.withLock { $0 }
        XCTAssertEqual(receipt.putOffsets, [0, 4, 5, 6, 7].map { Int64($0 * unit) })
        XCTAssertEqual(receipt.createCount, 1)
        XCTAssertEqual(receipt.assembledSHA256[id.uuidString.lowercased()], ResumableFileReader.sha256Hex(of: payload))
        await next.pause()
    }

    // MARK: - Pairing-switch rule

    @MainActor
    func testPairingSwitchClearsRemoteSessionAndStartsCleanFromOffsetZeroOnNewJournal() async throws {
        let itemID = Self.uuid(9)
        let payload = Self.deterministicData(count: 192 * 1024, seed: 9)
        let expectedSHA = ResumableFileReader.sha256Hex(of: payload)

        let stateA = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            inject503AtPutOffsets: [64 * 1024]
        ))
        let stateB = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024
        ))

        TransferURLProtocol.handler = { request, body in
            if request.url?.port == 19101 {
                return Self.handleMockJournal(request: request, body: body, state: stateA)
            }
            return Self.handleMockJournal(request: request, body: body, state: stateB)
        }

        let spool = self.makeSpool()
        let resolver = MutableEndpointResolver(endpoint: Self.endpoint(port: 19101, instanceID: "journal-A"))
        let engine = self.makeEngine(spool: spool, endpointResolver: resolver, retrySteps: [60])
        try await engine.start()
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-A")

        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "switch.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        // Wait for chunk 0 confirmed on journal-A, then paused at 64 KiB.
        try await transferTestWaitFor("paused on journal-A at 64 KiB") {
            guard let snap = await engine.itemSnapshot(itemID: itemID) else { return false }
            return snap.resumableProgress?.bytesSent == 64 * 1024
                && snap.resumableProgress?.phase == .paused
        }

        // Switch paired journal to journal-B (different instance_id and port).
        await resolver.switchTo(Self.endpoint(port: 19102, instanceID: "journal-B"))
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-B")

        try await transferTestWaitFor("delivered cleanly to journal-B") {
            await engine.snapshot().counters.deliveredCount == 1
        }

        let snapB = stateB.withLock { $0 }
        XCTAssertEqual(snapB.statusGetCount, 0, "must NOT reuse journal-A upload_id on journal-B")
        XCTAssertEqual(snapB.createCount, 1)
        XCTAssertEqual(snapB.putOffsets, [0, 64 * 1024, 128 * 1024])
        XCTAssertEqual(snapB.assembledSHA256[itemID.uuidString.lowercased()], expectedSHA)
        await engine.pause()
    }

    // MARK: - Real faults vs auth hold vs lost commit response

    @MainActor
    func test507InsufficientSpaceMovesToRetryableAttentionAndPreservesLocalBytesAndOffset() async throws {
        let itemID = Self.uuid(10)
        let payload = Self.deterministicData(count: 192 * 1024, seed: 10)
        let expectedSHA = ResumableFileReader.sha256Hex(of: payload)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            inject507AtPutOffsets: [64 * 1024]
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let engine = self.makeEngine()
        try await engine.start()
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-A")
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "big.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("moved to attention on 507") {
            await engine.snapshot().counters.attentionCount == 1
        }

        let heldSnapshot = await engine.itemSnapshot(itemID: itemID)
        let held = try XCTUnwrap(heldSnapshot)
        XCTAssertEqual(held.state, .attention)
        XCTAssertEqual(held.manifest.attention?.journalReasonCode, TransferReasonCodes.insufficientJournalSpace)
        XCTAssertEqual(held.manifest.attention?.isRetryableAttention, true)
        XCTAssertEqual(held.manifest.attention?.suppressesAutoRetry, true)
        XCTAssertEqual(held.manifest.saveThenStart?.resumable?.remoteOffset, 64 * 1024)
        let payloadURLAfter507 = await engine.payloadFileURL(itemID: itemID, partID: "file")
        XCTAssertNotNil(payloadURLAfter507)

        // Reconnect must NOT auto-retry a 507 attention item.
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-A")
        await engine.kick()
        try await Task.sleep(for: .milliseconds(100))
        let attentionAfterReconnect = await engine.snapshot().counters.attentionCount
        XCTAssertEqual(attentionAfterReconnect, 1)

        // Owner taps "try now": resumes from 64 KiB without re-sending offset 0.
        let retried507 = try await engine.retryAttention(itemID: itemID)
        XCTAssertTrue(retried507)
        try await transferTestWaitFor("507 retried and delivered") {
            await engine.snapshot().counters.deliveredCount == 1
        }

        let snap = state.withLock { $0 }
        XCTAssertEqual(snap.putOffsets.filter { $0 == 0 }.count, 1)
        XCTAssertEqual(snap.assembledSHA256[itemID.uuidString.lowercased()], expectedSHA)
        await engine.pause()
    }

    @MainActor
    func test422WholeFileMismatchAnd404ExpiredSurfacedAsAttentionAndRetryStartsNewResumableUploadNeverSave() async throws {
        let itemID = Self.uuid(11)
        let payload = Self.deterministicData(count: 128 * 1024, seed: 11)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            inject422WholeFileMismatchOnFirstCommit: true,
            inject404ExpiredOnPutCallIndex: 4
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let engine = self.makeEngine()
        try await engine.start()
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "verify.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        // 1. First commit triggers 422 whole_file_checksum_mismatch -> real fault in attention.
        try await transferTestWaitFor("422 whole-file mismatch in attention") {
            await engine.snapshot().counters.attentionCount == 1
        }
        let firstFaultSnapshot = await engine.itemSnapshot(itemID: itemID)
        let firstFault = try XCTUnwrap(firstFaultSnapshot)
        XCTAssertEqual(firstFault.manifest.attention?.journalReasonCode, TransferReasonCodes.wholeFileChecksumMismatch)
        XCTAssertNil(firstFault.manifest.saveThenStart?.resumable?.uploadID)
        XCTAssertNil(firstFault.manifest.saveThenStart?.resumable?.wholeFileSHA256)
        XCTAssertEqual(firstFault.manifest.attention?.isRetryableAttention, true)

        // 2. Owner retries -> runs POST /uploads again (never /save), hits 404 upload_not_found on PUT -> attention.
        let retriedAfter422 = try await engine.retryAttention(itemID: itemID)
        XCTAssertTrue(retriedAfter422)
        try await transferTestWaitFor("404 expired in attention") {
            let item = await engine.itemSnapshot(itemID: itemID)
            return item?.state == .attention && item?.manifest.attention?.journalReasonCode == TransferReasonCodes.uploadNotFound
        }
        let expiredFaultSnapshot = await engine.itemSnapshot(itemID: itemID)
        let expiredFault = try XCTUnwrap(expiredFaultSnapshot)
        XCTAssertNil(expiredFault.manifest.saveThenStart?.resumable?.uploadID)
        XCTAssertEqual(expiredFault.manifest.attention?.isRetryableAttention, true)

        // 3. Owner retries again -> starts clean POST /uploads (still never /save) and delivers.
        let retriedAfter404 = try await engine.retryAttention(itemID: itemID)
        XCTAssertTrue(retriedAfter404)
        try await transferTestWaitFor("recovered after 404 delivered") {
            await engine.snapshot().counters.deliveredCount == 1
        }
        let snap = state.withLock { $0 }
        XCTAssertEqual(snap.saveCount, 0, "once advertised, 404 upload_not_found must NEVER fall back to /save")
        XCTAssertEqual(snap.createCount, 3)
        await engine.pause()
    }

    @MainActor
    func test401PairingRefusalHoldsResumableQueueWithoutAttentionOrByteDeletion() async throws {
        let itemID = Self.uuid(12)
        let payload = Self.deterministicData(count: 128 * 1024, seed: 12)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            inject401AtPutOffsets: [64 * 1024]
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let mirror = TransferStatusMirror()
        let engine = self.makeEngine(statusMirror: mirror)
        try await engine.start()
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-A")
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "auth.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("auth held on 401") {
            await engine.snapshot().sources[ObserverAudioTransferSource.share]?.authHeld == true
        }
        let snap = await engine.snapshot()
        XCTAssertEqual(snap.counters.attentionCount, 0)
        XCTAssertEqual(snap.counters.queuedCount, 1)
        let bytesSentOnAuthHold = await engine.itemSnapshot(itemID: itemID)?.resumableProgress?.bytesSent
        XCTAssertEqual(bytesSentOnAuthHold, 64 * 1024)
        let payloadURLOnAuthHold = await engine.payloadFileURL(itemID: itemID, partID: "file")
        XCTAssertNotNil(payloadURLOnAuthHold)

        // Reconnect clears auth hold and resumes from 64 KiB.
        await engine.noteNewConnectionEstablished(pairingIdentity: "pairing-A")
        try await transferTestWaitFor("delivered after auth hold cleared") {
            await engine.snapshot().counters.deliveredCount == 1
        }
        XCTAssertEqual(state.withLock { $0.putOffsets.filter { $0 == 0 }.count }, 1)
        await engine.pause()
    }

    @MainActor
    func testLostCommitResponseRetriesCommitDirectlyWithoutFalse404FromGet() async throws {
        let itemID = Self.uuid(13)
        let payload = Self.deterministicData(count: 128 * 1024, seed: 13)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            dropFirstCommitResponseAfterServerCommits: true
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let engine = self.makeEngine(retrySteps: [0.02])
        try await engine.start()
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "commit-drop.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("lost commit response recovered cleanly") {
            await engine.snapshot().counters.deliveredCount == 1
        }

        let snap = state.withLock { $0 }
        XCTAssertEqual(snap.statusGetCount, 0, "when remoteOffset == totalBytes, retry must call commit directly, not GET")
        XCTAssertEqual(snap.commitCount, 2)
        XCTAssertEqual(snap.startCount, 1)
        await engine.pause()
    }

    @MainActor
    func testCancelDropsItemAndSendsBestEffortDeleteToOwningJournal() async throws {
        let itemID = Self.uuid(14)
        let payload = Self.deterministicData(count: 256 * 1024, seed: 14)

        let state = OSAllocatedUnfairLock<MockResumableJournalState>(initialState: MockResumableJournalState(
            advertiseCapability: true,
            thresholdBytes: 64 * 1024,
            chunkBytes: 64 * 1024,
            inject503AtPutOffsets: [64 * 1024]
        ))
        TransferURLProtocol.handler = { request, body in
            Self.handleMockJournal(request: request, body: body, state: state)
        }

        let engine = self.makeEngine(retrySteps: [60])
        try await engine.start()
        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "cancel.zip", byteCount: payload.count),
            payloads: ["file": payload]
        )

        try await transferTestWaitFor("paused after 64 KiB before cancel") {
            guard let snap = await engine.itemSnapshot(itemID: itemID) else { return false }
            return snap.resumableProgress?.bytesSent == 64 * 1024
                && snap.resumableProgress?.phase == .paused
        }

        await engine.drop(itemID: itemID)

        try await transferTestWaitFor("DELETE received by journal") {
            state.withLock { !$0.deletedUploadIDs.isEmpty }
        }
        let afterCancel = await engine.snapshot()
        XCTAssertEqual(afterCancel.counters.queuedCount, 0)
        XCTAssertEqual(afterCancel.counters.droppedCount, 1)
        await engine.pause()
    }

    // MARK: - Live kernel-loopback wire framing (4 MiB chunk, exact Content-Length, no chunked TE, no Expect)

    @MainActor
    func testLiveLoopback4MiBChunkWireFramingAndZeroSpoolCopyAndOffMainThreadHashing() async throws {
        let itemID = Self.uuid(15)
        // 5 MiB payload: one full 4 MiB chunk + one 1 MiB tail chunk over real kernel loopback TCP.
        let byteCount = 5 * 1024 * 1024
        let payload = Self.deterministicData(count: byteCount, seed: 15)
        let expectedSHA = ResumableFileReader.sha256Hex(of: payload)

        // Prove off-MainActor hashing & chunk reading directly.
        let fileURL = self.tempDirectory.appendingPathComponent("off-main.bin")
        try payload.write(to: fileURL)
        let computedSHA = try await ResumableFileReader.sha256Hex(at: fileURL)
        XCTAssertEqual(computedSHA, expectedSHA)
        let readSlice = try await ResumableFileReader.readChunk(at: fileURL, offset: 4 * 1024 * 1024, length: 1024 * 1024)
        XCTAssertEqual(readSlice, payload.subdata(in: (4 * 1024 * 1024)..<byteCount))

        let server = try await LiveResumableLoopbackServer.start(
            thresholdBytes: 4 * 1024 * 1024,
            chunkBytes: 4 * 1024 * 1024
        )
        defer { server.stop() }

        let spool = self.makeSpool()
        let endpoint = TransferResolvedEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(server.port)")!,
            port: server.port,
            dispatchOwner: TransferDispatchOwner(
                pairingGeneration: 1,
                ownerID: UUID(),
                credentialCID: "live-cid",
                journalInstanceID: "live-journal"
            )
        )
        let transport = TransferTransport(sessionConfiguration: .ephemeral)
        let probe = JournalResumableImportCapabilityProbe(transport: transport)
        let engine = TransferEngine(
            spool: spool,
            transport: transport,
            endpointResolver: TransferEndpointResolverStub(.available(endpoint)),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0.05], maxDelay: 10)),
            clock: LiveTransferClock(),
            maxConcurrent: 1,
            bodyBuilder: Self.shareBodyBuilder,
            resumableImportProbe: probe,
            resumableRetryLadder: ResumableRetryLadder(stepsSeconds: [0.05]),
            deviceNoun: "iphone"
        )
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.shareFileManifest(itemID: itemID, filename: "five-mib.bin", byteCount: payload.count),
            payloads: ["file": payload]
        )

        let bodyUploadURL = spool.queuedDirectoryURL
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent(TransferSpool.bodyUploadFilename, isDirectory: false)

        try await transferTestWaitFor("5 MiB live loopback upload delivered", timeout: .seconds(15)) {
            await engine.snapshot().counters.deliveredCount == 1
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: bodyUploadURL.path))

        let capturedPuts = server.capturedPutWireRequests
        XCTAssertEqual(capturedPuts.count, 2)
        XCTAssertEqual(capturedPuts[0].body.count, 4 * 1024 * 1024)
        XCTAssertEqual(capturedPuts[1].body.count, 1 * 1024 * 1024)

        for put in capturedPuts {
            XCTAssertEqual(put.header("content-length"), "\(put.body.count)")
            XCTAssertNil(put.header("transfer-encoding"), "PUT chunk must never use Transfer-Encoding: chunked")
            XCTAssertNil(put.header("expect"), "PUT chunk must never send Expect: 100-continue")
            XCTAssertEqual(put.header("content-type"), "application/octet-stream")
            XCTAssertEqual(put.header("x-chunk-sha256"), ResumableFileReader.sha256Hex(of: put.body))
            XCTAssertNotNil(put.header("cookie"), "loopback capability cookie must be attached on 127.0.0.1")
        }

        XCTAssertEqual(server.assembledSHA256, expectedSHA)
        await engine.pause()
        transport.invalidateAndCancel()
    }

    // MARK: - Retry ladder bounds & Legacy manifest compatibility

    func testResumableRetryLadderUsesExpectedStepsAnd20PercentJitter() {
        let ladder = ResumableRetryLadder()
        let itemID = Self.uuid(20)
        let expectedBases: [TimeInterval] = [1, 2, 5, 10, 30, 60, 60]
        for (index, base) in expectedBases.enumerated() {
            let delay = ladder.delay(itemID: itemID, attempt: index + 1)
            XCTAssertGreaterThanOrEqual(delay, base * 0.8 - 0.0001)
            XCTAssertLessThanOrEqual(delay, base * 1.2 + 0.0001)
        }
    }

    func testLegacyTransferManifestWithoutResumableDecodesCleanly() throws {
        let legacyJSON = """
        {
          "createdAt": "2026-11-24T12:00:00Z",
          "diskState": "queued",
          "endpoint": {
            "destinationKind": "save_then_start",
            "path": "/app/import/api/save",
            "startPath": "/app/import/api/start"
          },
          "itemID": "00000000-0000-0000-0000-000000000099",
          "meta": {},
          "payloadParts": [
            {
              "contentType": "application/zip",
              "filename": "legacy.zip",
              "kind": "file",
              "partID": "file",
              "relativePath": "raw.bin",
              "requiredForDispatch": true
            }
          ],
          "priority": {
            "basePriority": "normal",
            "sourceKey": "share",
            "userInitiated": false
          },
          "saveThenStart": {
            "phase": "save_pending"
          },
          "schemaVersion": "solstone.transfer.item/1",
          "source": "share"
        }
        """
        let decoded = try TransferSpool.decoder().decode(TransferManifest.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.saveThenStart?.phase, .savePending)
        XCTAssertNil(decoded.saveThenStart?.resumable)
    }

    func testResumableFileReaderPOSIXHashAndChunkReadsEdgeCases() async throws {
        // Multi-buffer payload spanning several 64 KiB hash reads plus non-aligned tail.
        let byteCount = (64 * 1024 * 5) + 12345
        let payload = Self.deterministicData(count: byteCount, seed: 42)
        let fileURL = self.tempDirectory.appendingPathComponent("posix reader sample.bin")
        try payload.write(to: fileURL)

        let expectedSHA = ResumableFileReader.sha256Hex(of: payload)
        let actualSHA = try await ResumableFileReader.sha256Hex(at: fileURL)
        XCTAssertEqual(actualSHA, expectedSHA)

        // Exact slice from middle offset and tail offset up to EOF.
        let midOffset = 100_003
        let midLength = 70_000
        let midChunk = try await ResumableFileReader.readChunk(
            at: fileURL,
            offset: Int64(midOffset),
            length: midLength
        )
        XCTAssertEqual(midChunk, payload.subdata(in: midOffset..<(midOffset + midLength)))

        let tailOffset = byteCount - 512
        let tailChunk = try await ResumableFileReader.readChunk(
            at: fileURL,
            offset: Int64(tailOffset),
            length: 512
        )
        XCTAssertEqual(tailChunk, payload.subdata(in: tailOffset..<byteCount))

        // Reading past EOF throws unexpectedEOF with the partial byte count.
        do {
            _ = try await ResumableFileReader.readChunk(
                at: fileURL,
                offset: Int64(tailOffset),
                length: 1024
            )
            XCTFail("Expected unexpectedEOF")
        } catch let error as ResumableFileReaderError {
            XCTAssertEqual(error, .unexpectedEOF(expected: 1024, actual: 512))
        }

        // Unreadable paths (missing file and directory) throw .unreadable.
        let missingURL = self.tempDirectory.appendingPathComponent("does-not-exist.bin")
        do {
            _ = try await ResumableFileReader.sha256Hex(at: missingURL)
            XCTFail("Expected unreadable for missing file")
        } catch let error as ResumableFileReaderError {
            XCTAssertEqual(error, .unreadable("does-not-exist.bin"))
        }

        do {
            _ = try await ResumableFileReader.sha256Hex(at: self.tempDirectory)
            XCTFail("Expected unreadable for directory")
        } catch let error as ResumableFileReaderError {
            XCTAssertEqual(error, .unreadable(self.tempDirectory.lastPathComponent))
        }

        // Cancelled task returns .cancelled.
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ResumableFileReader.readChunk(at: fileURL, offset: 0, length: 64)
        }
        do {
            _ = try await cancelledTask.value
            XCTFail("Expected cancelled")
        } catch let error as ResumableFileReaderError {
            XCTAssertEqual(error, .cancelled)
        }
    }

    // MARK: - Helpers

    private static let baseDate = Date(timeIntervalSince1970: 1_795_520_000)

    private static func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private static func endpoint(port: Int = 19000, instanceID: String = "journal-A") -> TransferResolvedEndpoint {
        TransferResolvedEndpoint(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            port: port,
            dispatchOwner: TransferDispatchOwner(
                pairingGeneration: 1,
                ownerID: UUID(),
                credentialCID: "cid-\(instanceID)",
                journalInstanceID: instanceID
            )
        )
    }

    private func makeSpool() -> TransferSpool {
        TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("Transfers", isDirectory: true))
    }

    private func makeEngine(
        spool: TransferSpool? = nil,
        endpointResolver: (any TransferEndpointResolver)? = nil,
        statusMirror: TransferStatusMirror? = nil,
        probe: (any ResumableImportCapabilityProbing)? = nil,
        retrySteps: [TimeInterval] = [0.01, 0.02, 0.05]
    ) -> TransferEngine {
        let transport = TransferTransport(sessionConfiguration: makeTransferTestURLSessionConfiguration())
        let effectiveProbe = probe ?? JournalResumableImportCapabilityProbe(transport: transport)
        return TransferEngine(
            spool: spool ?? self.makeSpool(),
            transport: transport,
            endpointResolver: endpointResolver ?? TransferEndpointResolverStub(.available(Self.endpoint())),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0.01], maxDelay: 300)),
            clock: LiveTransferClock(),
            statusMirror: statusMirror,
            maxConcurrent: 1,
            bodyBuilder: Self.shareBodyBuilder,
            resumableImportProbe: effectiveProbe,
            resumableRetryLadder: ResumableRetryLadder(stepsSeconds: retrySteps),
            deviceNoun: "ipad"
        )
    }

    private static let shareBodyBuilder: TransferBodyBuilder = { item, spool in
        if item.manifest.saveThenStart?.phase == .savePending {
            return try ShareImportSaveBody.build(item: item, spool: spool)
        }
        return try DefaultTransferBodyBuilder.build(item: item, spool: spool)
    }

    private func shareFileManifest(itemID: UUID, filename: String, byteCount: Int) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: ObserverAudioTransferSource.share,
            createdAt: Self.baseDate,
            priority: TransferPriorityInputs(basePriority: .normal, sourceKey: ObserverAudioTransferSource.share),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "file",
                    kind: .file,
                    relativePath: "raw.bin",
                    filename: filename,
                    contentType: "application/octet-stream",
                    byteCount: byteCount
                ),
            ],
            endpoint: TransferEndpointDescriptor(
                destinationKind: .saveThenStart,
                path: ImporterServerURL.savePath,
                startPath: ImporterServerURL.startPath
            ),
            meta: ShareImportTransferMetadata.meta(fields: ShareImportTransferMetadata.Fields(
                basis: "file",
                contentType: "public.data",
                targetJournal: "journal-A",
                filename: filename,
                originApp: nil,
                itemTime: nil,
                bytes: Int64(byteCount),
                requestSource: "file"
            )),
            saveThenStart: TransferSaveThenStartState(phase: .savePending)
        )
    }

    private static func deterministicData(count: Int, seed: UInt8) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for idx in 0..<count {
                ptr[idx] = UInt8((idx &* 37 &+ Int(seed) &* 13) & 0xFF)
            }
        }
        return data
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    // MARK: - Stateful Mock Journal

    private struct MockUploadSession {
        var uploadID: String
        var clientItemID: String
        var totalBytes: Int64
        var expectedSHA256: String?
        var buffer = Data()
        var committed = false
    }

    private struct MockResumableJournalState {
        var advertiseCapability: Bool
        var thresholdBytes: Int64
        var chunkBytes: Int
        var injectChunkChecksum422AtOffsets: Set<Int64> = []
        var injectBodyless409AtCallIndex: Int? = nil
        var inject503AtPutOffsets: Set<Int64> = []
        var inject507AtPutOffsets: Set<Int64> = []
        var inject401AtPutOffsets: Set<Int64> = []
        var inject422WholeFileMismatchOnFirstCommit = false
        var inject404ExpiredOnPutCallIndex: Int? = nil
        var dropFirstCommitResponseAfterServerCommits = false

        var saveCount = 0
        var createCount = 0
        var statusGetCount = 0
        var commitCount = 0
        var startCount = 0
        var putCallCount = 0
        var putOffsets: [Int64] = []
        var deletedUploadIDs: [String] = []
        var lastCreateDeviceNoun: String?
        var lastCreateImportedVia: String?
        var sessions: [String: MockUploadSession] = [:]
        var recentCommittedByUploadID: [String: String] = [:]
        var assembledSHA256: [String: String] = [:]
    }

    private static func handleMockJournal(
        request: URLRequest,
        body: Data,
        state: OSAllocatedUnfairLock<MockResumableJournalState>
    ) -> (HTTPURLResponse, Data) {
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""

        if method == "GET", path == ResumableImportDefaults.statusPath {
            let advertised = state.withLock { $0.advertiseCapability }
            let caps = advertised ? #"["resumable_import_uploads"]"# : #"[]"#
            return (Self.response(for: request, statusCode: 200), Data(#"{"capabilities":\#(caps)}"#.utf8))
        }

        if method == "GET", path == ResumableImportDefaults.sourcesPath {
            let (advertised, threshold, chunk) = state.withLock { ($0.advertiseCapability, $0.thresholdBytes, $0.chunkBytes) }
            if advertised {
                let json = #"{"resumable":{"threshold_bytes":\#(threshold),"chunk_bytes":\#(chunk),"max_file_bytes":4294967296}}"#
                return (Self.response(for: request, statusCode: 200), Data(json.utf8))
            }
            return (Self.response(for: request, statusCode: 200), Data(#"{}"#.utf8))
        }

        if method == "POST", path == ImporterServerURL.savePath {
            state.withLock { $0.saveCount += 1 }
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"recommended_action":"start","path":"/imports/save","timestamp":"20261125_120100"}"#.utf8)
            )
        }

        if method == "POST", path == ImporterServerURL.startPath {
            state.withLock { $0.startCount += 1 }
            return (
                Self.response(for: request, statusCode: 200),
                Data(#"{"status":"ok","task_id":"task-1"}"#.utf8)
            )
        }

        if method == "POST", path == ImporterServerURL.uploadsPath {
            guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                  let clientItemID = json["client_item_id"] as? String,
                  let totalBytes = (json["total_bytes"] as? NSNumber)?.int64Value
            else {
                return (Self.response(for: request, statusCode: 400), Data(#"{"error":"bad create"}"#.utf8))
            }
            let sha256 = json["sha256"] as? String
            let deviceNoun = json["device_noun"] as? String
            let importedVia = json["imported_via"] as? String
            let result = state.withLock { st -> (Int, Data) in
                st.createCount += 1
                st.lastCreateDeviceNoun = deviceNoun
                st.lastCreateImportedVia = importedVia
                let uploadID = "upload-\(st.createCount)"
                st.sessions[uploadID] = MockUploadSession(
                    uploadID: uploadID,
                    clientItemID: clientItemID,
                    totalBytes: totalBytes,
                    expectedSHA256: sha256
                )
                let resp = """
                {
                  "upload_id": "\(uploadID)",
                  "client_item_id": "\(clientItemID)",
                  "status": "open",
                  "next_offset": 0,
                  "total_bytes": \(totalBytes),
                  "chunk_bytes": \(st.chunkBytes),
                  "expires_at": "2026-12-02T12:00:00Z"
                }
                """
                return (201, Data(resp.utf8))
            }
            return (Self.response(for: request, statusCode: result.0), result.1)
        }

        let prefix = ImporterServerURL.uploadsPath + "/"
        if path.hasPrefix(prefix) {
            let rest = String(path.dropFirst(prefix.count))
            if method == "POST", rest.hasSuffix("/commit") {
                let uploadID = String(rest.dropLast("/commit".count))
                let result = state.withLock { st -> (Int, Data) in
                    st.commitCount += 1
                    if let replayItem = st.recentCommittedByUploadID[uploadID] {
                        _ = replayItem
                        let resp = #"{"status":"staged","replay":true,"recommended_action":"start","path":"/imports/replay","timestamp":"20261125_120200"}"#
                        return (200, Data(resp.utf8))
                    }
                    guard var session = st.sessions[uploadID] else {
                        return (404, Data(#"{"error":"upload expired","reason_code":"upload_not_found"}"#.utf8))
                    }
                    if st.inject422WholeFileMismatchOnFirstCommit {
                        st.inject422WholeFileMismatchOnFirstCommit = false
                        st.sessions.removeValue(forKey: uploadID)
                        return (422, Data(#"{"error":"file check failed","reason_code":"whole_file_checksum_mismatch"}"#.utf8))
                    }
                    let actualSHA = ResumableFileReader.sha256Hex(of: session.buffer)
                    if let expected = session.expectedSHA256, expected != actualSHA {
                        st.sessions.removeValue(forKey: uploadID)
                        return (422, Data(#"{"error":"file check failed","reason_code":"whole_file_checksum_mismatch"}"#.utf8))
                    }
                    session.committed = true
                    st.assembledSHA256[session.clientItemID] = actualSHA
                    st.sessions.removeValue(forKey: uploadID)
                    st.recentCommittedByUploadID[uploadID] = session.clientItemID
                    if st.dropFirstCommitResponseAfterServerCommits {
                        st.dropFirstCommitResponseAfterServerCommits = false
                        return (503, Data())
                    }
                    let resp = #"{"status":"staged","recommended_action":"start","path":"/imports/committed","timestamp":"20261125_120200"}"#
                    return (200, Data(resp.utf8))
                }
                return (Self.response(for: request, statusCode: result.0), result.1)
            }

            let uploadID = rest
            if method == "GET" {
                let result = state.withLock { st -> (Int, Data) in
                    st.statusGetCount += 1
                    guard let session = st.sessions[uploadID] else {
                        return (404, Data(#"{"error":"upload expired","reason_code":"upload_not_found"}"#.utf8))
                    }
                    let resp = """
                    {
                      "upload_id": "\(uploadID)",
                      "client_item_id": "\(session.clientItemID)",
                      "status": "open",
                      "phase": "sending",
                      "next_offset": \(session.buffer.count),
                      "total_bytes": \(session.totalBytes),
                      "chunk_bytes": \(st.chunkBytes),
                      "expires_at": "2026-12-02T12:00:00Z"
                    }
                    """
                    return (200, Data(resp.utf8))
                }
                return (Self.response(for: request, statusCode: result.0), result.1)
            }

            if method == "DELETE" {
                let result = state.withLock { st -> (Int, Data) in
                    st.deletedUploadIDs.append(uploadID)
                    st.sessions.removeValue(forKey: uploadID)
                    return (200, Data(#"{"deleted":true,"upload_id":"\#(uploadID)"}"#.utf8))
                }
                return (Self.response(for: request, statusCode: result.0), result.1)
            }

            if method == "PUT" {
                let queryItems = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let offset = queryItems.first(where: { $0.name == "offset" })?.value.flatMap(Int64.init) ?? -1
                let chunkHeader = request.value(forHTTPHeaderField: "X-Chunk-Sha256")
                XCTAssertEqual(chunkHeader, ResumableFileReader.sha256Hex(of: body))

                let result = state.withLock { st -> (Int, Data) in
                    st.putCallCount += 1
                    st.putOffsets.append(offset)
                    if let targetCall = st.inject404ExpiredOnPutCallIndex, st.putCallCount == targetCall {
                        st.sessions.removeValue(forKey: uploadID)
                        return (404, Data(#"{"error":"upload expired","reason_code":"upload_not_found"}"#.utf8))
                    }
                    if st.inject401AtPutOffsets.remove(offset) != nil {
                        return (401, Data(#"{"error":"unauthorized"}"#.utf8))
                    }
                    if st.inject507AtPutOffsets.remove(offset) != nil {
                        return (507, Data(#"{"error":"journal full","reason_code":"insufficient_journal_space"}"#.utf8))
                    }
                    if st.inject503AtPutOffsets.remove(offset) != nil {
                        return (503, Data())
                    }
                    if st.injectChunkChecksum422AtOffsets.remove(offset) != nil {
                        return (422, Data(#"{"error":"chunk mismatch","reason_code":"chunk_checksum_mismatch"}"#.utf8))
                    }
                    guard var session = st.sessions[uploadID] else {
                        return (404, Data(#"{"error":"upload expired","reason_code":"upload_not_found"}"#.utf8))
                    }
                    if let target409 = st.injectBodyless409AtCallIndex, st.putCallCount == target409 {
                        // Advance server buffer to simulate a previous chunk whose ACK was lost,
                        // then return a bodyless 409 so client must GET resync.
                        session.buffer.append(body)
                        st.sessions[uploadID] = session
                        return (409, Data())
                    }
                    if offset != Int64(session.buffer.count) {
                        let resp = #"{"error":"offset mismatch","reason_code":"offset_mismatch","next_offset":\#(session.buffer.count),"total_bytes":\#(session.totalBytes)}"#
                        return (409, Data(resp.utf8))
                    }
                    session.buffer.append(body)
                    st.sessions[uploadID] = session
                    let complete = Int64(session.buffer.count) == session.totalBytes
                    let resp = """
                    {
                      "upload_id": "\(uploadID)",
                      "next_offset": \(session.buffer.count),
                      "total_bytes": \(session.totalBytes),
                      "complete": \(complete ? "true" : "false"),
                      "expires_at": "2026-12-02T12:00:00Z"
                    }
                    """
                    return (200, Data(resp.utf8))
                }
                return (Self.response(for: request, statusCode: result.0), result.1)
            }
        }

        return (Self.response(for: request, statusCode: 404), Data())
    }
}

// MARK: - Test Doubles

private actor StaticResumableProbe: ResumableImportCapabilityProbing {
    private var result: ResumableImportCapabilityResult
    private(set) var markedUnsupportedCount = 0

    init(result: ResumableImportCapabilityResult) {
        self.result = result
    }

    func capability(for endpoint: TransferResolvedEndpoint, journalVersion: String?) async -> ResumableImportCapabilityResult {
        self.result
    }

    func markUnsupported(for endpoint: TransferResolvedEndpoint, journalVersion: String?) async {
        self.markedUnsupportedCount += 1
        self.result = .unsupported
    }

    func invalidate() async {}
}

private actor MutableEndpointResolver: TransferEndpointResolver {
    private var currentEndpoint: TransferResolvedEndpoint

    private let available: @Sendable () -> Bool

    init(endpoint: TransferResolvedEndpoint, available: @escaping @Sendable () -> Bool = { true }) {
        self.available = available
        self.currentEndpoint = endpoint
    }

    func switchTo(_ next: TransferResolvedEndpoint) {
        self.currentEndpoint = next
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        available() ? .available(self.currentEndpoint) : .unavailable("disconnected")
    }

    func isCurrent(_ endpoint: TransferResolvedEndpoint) async -> Bool {
        available() && endpoint == self.currentEndpoint
    }
}

// MARK: - Live Kernel-Loopback Raw HTTP/1.1 Server

private nonisolated final class LiveResumableLoopbackServer: @unchecked Sendable {
    struct CapturedRequest: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data

        func header(_ name: String) -> String? {
            self.headers[name.lowercased()]
        }
    }

    private struct State {
        var buffer = Data()
        var totalBytes: Int64 = 0
        var expectedSHA256: String?
        var putRequests: [CapturedRequest] = []
        var assembledSHA256: String?
    }

    var port: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.live.resumable.loopback")
    private let thresholdBytes: Int64
    private let chunkBytes: Int
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    var capturedPutWireRequests: [CapturedRequest] {
        self.state.withLock { $0.putRequests }
    }

    var assembledSHA256: String? {
        self.state.withLock { $0.assembledSHA256 }
    }

    private init(listener: NWListener, port: Int, thresholdBytes: Int64, chunkBytes: Int) {
        self.listener = listener
        self.port = port
        self.thresholdBytes = thresholdBytes
        self.chunkBytes = chunkBytes
    }

    static func start(thresholdBytes: Int64, chunkBytes: Int) async throws -> LiveResumableLoopbackServer {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        let listener = try NWListener(using: params, on: .any)
        let server = LiveResumableLoopbackServer(
            listener: listener,
            port: 0,
            thresholdBytes: thresholdBytes,
            chunkBytes: chunkBytes
        )
        listener.newConnectionHandler = { [weak server] connection in
            server?.handle(connection: connection)
        }
        let port: Int = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }
                    if let assigned = listener.port?.rawValue {
                        continuation.resume(returning: Int(assigned))
                    } else {
                        continuation.resume(throwing: URLError(.cannotConnectToHost))
                    }
                case .failed(let error):
                    guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: server.queue)
        }
        server.port = port
        return server
    }

    func stop() {
        self.listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: self.queue)
        self.readNextRequest(on: connection, accumulated: Data())
    }

    private func readNextRequest(on connection: NWConnection, accumulated: Data) {
        var buffer = accumulated
        let headerSeparator = Data("\r\n\r\n".utf8)
        if let range = buffer.range(of: headerSeparator) {
            let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            let bodyStart = range.upperBound
            if let headerText = String(data: headerData, encoding: .utf8) {
                let lines = headerText.components(separatedBy: "\r\n")
                let requestLine = lines.first?.split(separator: " ", maxSplits: 2) ?? []
                let method = requestLine.count > 0 ? String(requestLine[0]) : "GET"
                let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[key] = value
                    }
                }
                let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
                let availableBody = buffer.count - bodyStart
                if availableBody >= contentLength {
                    let bodyEnd = bodyStart + contentLength
                    let body = buffer.subdata(in: bodyStart..<bodyEnd)
                    let remainder = buffer.subdata(in: bodyEnd..<buffer.endIndex)
                    let captured = CapturedRequest(method: method, target: target, headers: headers, body: body)
                    let responseBytes = self.respond(to: captured)
                    connection.send(content: responseBytes, completion: .contentProcessed { [weak self] error in
                        if error != nil {
                            connection.cancel()
                            return
                        }
                        self?.readNextRequest(on: connection, accumulated: remainder)
                    })
                    return
                }
            }
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                self.readNextRequest(on: connection, accumulated: buffer)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func respond(to req: CapturedRequest) -> Data {
        let pathOnly = req.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? req.target
        if req.method == "GET", pathOnly == ResumableImportDefaults.statusPath {
            return Self.httpResponse(status: "200 OK", json: #"{"capabilities":["resumable_import_uploads"]}"#)
        }
        if req.method == "GET", pathOnly == ResumableImportDefaults.sourcesPath {
            return Self.httpResponse(
                status: "200 OK",
                json: #"{"resumable":{"threshold_bytes":\#(self.thresholdBytes),"chunk_bytes":\#(self.chunkBytes),"max_file_bytes":4294967296}}"#
            )
        }
        if req.method == "POST", pathOnly == ImporterServerURL.uploadsPath {
            let parsed = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
            let clientItemID = parsed?["client_item_id"] as? String ?? "item"
            let total = (parsed?["total_bytes"] as? NSNumber)?.int64Value ?? 0
            let sha = parsed?["sha256"] as? String
            self.state.withLock {
                $0.buffer = Data()
                $0.totalBytes = total
                $0.expectedSHA256 = sha
            }
            return Self.httpResponse(
                status: "201 Created",
                json: #"{"upload_id":"live-1","client_item_id":"\#(clientItemID)","status":"open","next_offset":0,"total_bytes":\#(total),"chunk_bytes":\#(self.chunkBytes),"expires_at":"2026-12-02T12:00:00Z"}"#
            )
        }
        if req.method == "PUT", pathOnly == "\(ImporterServerURL.uploadsPath)/live-1" {
            let (nextOffset, total, complete) = self.state.withLock { st -> (Int64, Int64, Bool) in
                st.putRequests.append(req)
                st.buffer.append(req.body)
                let next = Int64(st.buffer.count)
                return (next, st.totalBytes, next == st.totalBytes)
            }
            return Self.httpResponse(
                status: "200 OK",
                json: #"{"upload_id":"live-1","next_offset":\#(nextOffset),"total_bytes":\#(total),"complete":\#(complete ? "true" : "false"),"expires_at":"2026-12-02T12:00:00Z"}"#
            )
        }
        if req.method == "POST", pathOnly == "\(ImporterServerURL.uploadsPath)/live-1/commit" {
            self.state.withLock { st in
                st.assembledSHA256 = ResumableFileReader.sha256Hex(of: st.buffer)
            }
            return Self.httpResponse(
                status: "200 OK",
                json: #"{"status":"staged","recommended_action":"start","path":"/imports/live","timestamp":"20261125_120500"}"#
            )
        }
        if req.method == "POST", pathOnly == ImporterServerURL.startPath {
            return Self.httpResponse(status: "200 OK", json: #"{"status":"ok","task_id":"live-task"}"#)
        }
        return Self.httpResponse(status: "404 Not Found", json: #"{"error":"not found"}"#)
    }

    private static func httpResponse(status: String, json: String) -> Data {
        let body = Data(json.utf8)
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
        return Data(header.utf8) + body
    }
}
