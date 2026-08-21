// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class TransferTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testCrashResumeRestoresPersistedQueuedAndAttentionOnly() async throws {
        let clock = FakeTransferClock(wall: Self.baseDate)
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let queued = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(source: "alpha"),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        _ = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(source: "beta"),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        _ = try spool.writeBodyCache(Data("body".utf8), for: queued)

        let engine = self.makeEngine(spool: spool, clock: clock, resolver: TransferEndpointResolverStub(.unavailable("held")))
        try await engine.start()

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.attentionCount, 1)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
    }

    func testQueuedPredecessorObserverItemDeletesV2CacheBeforeV3Dispatch() async throws {
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let spool = TransferSpool(rootURL: self.tempDirectory)
        var manifest = self.makeManifest()
        manifest.endpoint.path = "/app/observer/ingest"
        manifest.observerIngest?.ingestProtocolVersion = nil
        let staged = try spool.stage(manifest: manifest, payloads: self.audioPayloads())
        let queuedURL = spool.queuedDirectoryURL.appendingPathComponent(
            staged.item.manifest.itemID.uuidString,
            isDirectory: true
        )
        try FileManager.default.moveItem(at: staged.item.directoryURL, to: queuedURL)
        let queued = TransferStoredItem(manifest: manifest, directoryURL: queuedURL)
        try spool.writeBodyCache(Data("stale-v2-body".utf8), for: queued)

        let resolver = TransferEndpointResolverStub(.unavailable("held"))
        let engine = self.makeEngine(spool: spool, resolver: resolver)
        try await engine.start()

        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.bodyCacheURL(for: queued).path))
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("v3 predecessor dispatch") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(TransferURLProtocol.requests[0].url?.path, "/app/devices/ingest")
        XCTAssertEqual(TransferURLProtocol.requests[0].value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName), "3")
        XCTAssertNil(TransferURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(TransferURLProtocol.bodies[0].contains(Data("audio".utf8)))
    }

    func testStagedPredecessorNormalizationFailureRecoversV3DispatchC6C8() async throws {
        let root = self.tempDirectory.appendingPathComponent("staged-normalization-recovery", isDirectory: true)
        let fileSystem = FailingManifestWriteFileSystem()
        let failingSpool = TransferSpool(rootURL: root, fileSystem: fileSystem)
        let itemID = Self.uuid(611)
        let durableBytes = Data("durable-after-normalization-failure".utf8)
        let staleV2Bytes = Data("stale-v2-body".utf8)
        _ = try self.stagePredecessor(
            spool: failingSpool,
            itemID: itemID,
            durableBytes: durableBytes,
            cachedBytes: staleV2Bytes
        )
        fileSystem.failManifestWrites = true

        let failedSnapshot = try failingSpool.initialize(now: Self.baseDate)
        let failedItem = try XCTUnwrap(failedSnapshot.attention.first { $0.manifest.itemID == itemID })
        XCTAssertFalse(failedSnapshot.queued.contains { $0.manifest.itemID == itemID })
        XCTAssertNil(failedItem.manifest.observerIngest?.ingestProtocolVersion)
        XCTAssertEqual(failedItem.manifest.endpoint.path, "/app/observer/ingest")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failingSpool.bodyCacheURL(for: failedItem).path))
        XCTAssertTrue(failedSnapshot.recoveryDiagnostics.contains {
            $0.itemID == itemID
                && $0.previousState == .staged
                && $0.nextState == .attention
                && $0.detail.hasPrefix("v3 normalization failed:")
        })

        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let resolver = TransferEndpointResolverStub(.unavailable("held"))
        let engine = self.makeEngine(
            spool: TransferSpool(rootURL: root),
            resolver: resolver
        )
        try await engine.start()
        let relaunchedItemValue = await engine.itemSnapshot(itemID: itemID)
        let relaunchedItem = try XCTUnwrap(relaunchedItemValue)
        XCTAssertEqual(relaunchedItem.manifest.observerIngest?.ingestProtocolVersion, 3)
        XCTAssertEqual(relaunchedItem.manifest.endpoint.path, "/app/devices/ingest")

        try await engine.retryAttention(itemID: itemID)
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("recovered staged predecessor dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(TransferURLProtocol.requests[0].value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName), "3")
        XCTAssertTrue(TransferURLProtocol.bodies[0].contains(durableBytes))
        XCTAssertFalse(TransferURLProtocol.bodies[0].contains(staleV2Bytes))
    }

    func testStagedNormalizationFailureDoesNotBlockHealthyItemC6() async throws {
        let root = self.tempDirectory.appendingPathComponent("staged-normalization-isolation", isDirectory: true)
        let fileSystem = FailingManifestWriteFileSystem()
        let failingSpool = TransferSpool(rootURL: root, fileSystem: fileSystem)
        let failingItemID = Self.uuid(612)
        let healthyItemID = Self.uuid(613)
        _ = try self.stagePredecessor(
            spool: failingSpool,
            itemID: failingItemID,
            durableBytes: Data("failing-durable".utf8),
            cachedBytes: Data("failing-stale-v2".utf8)
        )
        _ = try failingSpool.stage(
            manifest: self.makeManifest(itemID: healthyItemID, source: "healthy"),
            payloads: ["audio": Data("healthy-durable".utf8)]
        )
        fileSystem.failingManifestItemID = failingItemID
        fileSystem.failManifestWrites = true

        let snapshot = try failingSpool.initialize(now: Self.baseDate)
        XCTAssertTrue(snapshot.attention.contains { $0.manifest.itemID == failingItemID })
        XCTAssertTrue(snapshot.queued.contains { $0.manifest.itemID == healthyItemID })
        XCTAssertTrue(snapshot.recoveryDiagnostics.contains { $0.itemID == failingItemID })

        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root))
        try await engine.start()
        try await self.waitFor("healthy staged item dispatch") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(Self.boundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), healthyItemID)
        let engineSnapshot = await engine.snapshot()
        XCTAssertEqual(engineSnapshot.counters.deliveredCount, 1)
        XCTAssertEqual(engineSnapshot.counters.attentionCount, 1)
    }

    func testStagedNormalizationFailureNeverDispatchesV2CachedBytesC7() async throws {
        let root = self.tempDirectory.appendingPathComponent("staged-normalization-no-v2-dispatch", isDirectory: true)
        let fileSystem = FailingManifestWriteFileSystem()
        let spool = TransferSpool(rootURL: root, fileSystem: fileSystem)
        let itemID = Self.uuid(614)
        _ = try self.stagePredecessor(
            spool: spool,
            itemID: itemID,
            durableBytes: Data("durable-c7".utf8),
            cachedBytes: Data("stale-v2-c7".utf8)
        )
        fileSystem.failManifestWrites = true
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }

        let engine = self.makeEngine(spool: spool)
        try await engine.start()

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.attentionCount, 1)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
    }

    func testOutcomeClassifierTable() {
        let saveResult = TransferSaveThenStartState(
            phase: .startPending,
            savedPath: "/imports/item",
            savedTimestamp: "2026-04-20T12:00:00Z",
            recommendedAction: "start",
            serverSource: "audio"
        )
        let rows: [(TransferHTTPResult, TransferEndpointPhase, TransferOutcome)] = [
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"ok"}"#.utf8)),
                .observerIngest,
                .terminalSuccess(.delivered(serverPath: nil, serverTimestamp: nil))
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"duplicate"}"#.utf8)),
                .observerIngest,
                .terminalSuccess(.delivered(serverPath: nil, serverTimestamp: nil))
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"collision"}"#.utf8)),
                .observerIngest,
                .terminalSuccess(.delivered(serverPath: nil, serverTimestamp: nil))
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"failed","reason_code":"envelope_invalid"}"#.utf8)),
                .observerIngest,
                .terminalAttention(.httpClientError(statusCode: 200, detail: "reason_code=envelope_invalid"))
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"conflict","reason_code":"content_conflict"}"#.utf8)),
                .observerIngest,
                .terminalAttention(.httpClientError(statusCode: 200, detail: "reason_code=content_conflict"))
            ),
            (
                TransferHTTPResult(statusCode: 204),
                .observerIngest,
                .terminalAttention(.decodeFailed("invalid observer ingest response"))
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"other"}"#.utf8)),
                .observerIngest,
                .terminalAttention(.decodeFailed("unknown observer ingest status other"))
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"recommended_action":"start","path":"/imports/item","timestamp":"2026-04-20T12:00:00Z","source":"audio"}"#.utf8)),
                .save,
                .continueWithStart(saveResult)
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"recommended_action":"do_not_start","path":"/imports/item","timestamp":"2026-04-20T12:00:00Z"}"#.utf8)),
                .save,
                .terminalSuccess(.delivered(serverPath: "/imports/item", serverTimestamp: "2026-04-20T12:00:00Z"))
            ),
            (
                TransferHTTPResult(statusCode: 400, data: Data(#"{"reason_code":"invalid_operation_for_state"}"#.utf8)),
                .start(saveResult: saveResult),
                .terminalSuccess(.alreadyStartedOrComplete(serverPath: "/imports/item", serverTimestamp: "2026-04-20T12:00:00Z"))
            ),
            (
                TransferHTTPResult(statusCode: 404, data: Data("missing".utf8)),
                .observerIngest,
                .terminalAttention(.httpClientError(statusCode: 404, detail: "missing"))
            ),
            (
                TransferHTTPResult(statusCode: 426, data: Data(#"{"status":"failed","reason_code":"protocol_version_legacy"}"#.utf8)),
                .observerIngest,
                .terminalAttention(.httpClientError(statusCode: 426, detail: #"{"status":"failed","reason_code":"protocol_version_legacy"}"#))
            ),
            (
                TransferHTTPResult(statusCode: 503),
                .observerIngest,
                .transientRetry(.httpServerError(statusCode: 503))
            ),
            (
                TransferHTTPResult(statusCode: nil, issue: .timeout),
                .observerIngest,
                .transientRetry(.timeout)
            ),
            (
                TransferHTTPResult(statusCode: nil, issue: .cancelled),
                .observerIngest,
                .transientRetry(.cancelled)
            ),
            (
                TransferHTTPResult(statusCode: 200, data: Data(#"{"bad":true}"#.utf8)),
                .start(saveResult: saveResult),
                .terminalAttention(.decodeFailed("invalid start response"))
            ),
        ]

        for (result, phase, expected) in rows {
            XCTAssertEqual(TransferHTTPClassifier.classify(result: result, endpointPhase: phase), expected)
        }
    }

    func testAttentionPredecessorObserverItemNormalizesBeforeRequeueDispatch() async throws {
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("attention-v3", isDirectory: true))
        let manifest = self.makeManifest(itemID: Self.uuid(21))
        let queued = try spool.commitStagedItem(itemID: spool.stage(manifest: manifest, payloads: self.audioPayloads()).item.manifest.itemID)
        let attention = try spool.moveQueuedItemToAttention(queued, reason: "test", detail: "test", now: Self.baseDate)
        var predecessorManifest = attention.manifest
        predecessorManifest.endpoint.path = "/app/observer/ingest"
        predecessorManifest.observerIngest?.ingestProtocolVersion = nil
        try spool.writeManifestAtomically(predecessorManifest, in: attention.directoryURL)
        let predecessor = TransferStoredItem(manifest: predecessorManifest, directoryURL: attention.directoryURL)
        try spool.writeBodyCache(Data("stale-v2-body".utf8), for: predecessor)

        let resolver = TransferEndpointResolverStub(.unavailable("held"))
        let engine = self.makeEngine(spool: TransferSpool(rootURL: spool.rootURL), resolver: resolver)
        try await engine.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.bodyCacheURL(for: predecessor).path))
        try await engine.retryAttention()
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("attention v3 dispatch") { TransferURLProtocol.requests.count == 1 }
        XCTAssertEqual(TransferURLProtocol.requests[0].value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName), "3")
        XCTAssertNil(TransferURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(TransferURLProtocol.bodies[0].contains(Data("audio".utf8)))
    }

    func testNormalizedObserverItemRemainsDurableAfterNonSuccessResponse() async throws {
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"failed","reason_code":"envelope_invalid"}"#.utf8))
        }
        let delivered = OSAllocatedUnfairLock<Int>(initialState: 0)
        let engine = self.makeEngine()
        await engine.registerDeliveredHook(sourceKey: "alpha") { _, _ in delivered.withLock { $0 += 1 } }
        try await engine.start()
        _ = try await engine.enqueue(manifest: self.makeManifest(), payloads: self.audioPayloads())
        try await self.waitFor("ingest attention") { (await engine.snapshot()).counters.attentionCount == 1 }
        XCTAssertEqual(delivered.withLock { $0 }, 0)
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
    }

    func testHeldObserverEndpointMakesZeroNetworkCalls() async throws {
        let engine = self.makeEngine(resolver: TransferEndpointResolverStub(.unavailable("held")))
        try await engine.start()
        _ = try await engine.enqueue(manifest: self.makeManifest(), payloads: self.audioPayloads())
        try await self.waitFor("held observer item") { (await engine.snapshot()).counters.queuedCount == 1 }
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
    }

    func testSaveThenStartUnsupportedAndMalformedItemsMoveToAttentionWithoutRequests() async throws {
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data())
        }
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let engine = self.makeEngine(
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )
        try await engine.start()

        var savePending = self.makeManifest(itemID: Self.uuid(86))
        savePending.endpoint = TransferEndpointDescriptor(
            destinationKind: .saveThenStart,
            path: "/imports/save",
            startPath: "/imports/start"
        )
        savePending.saveThenStart = TransferSaveThenStartState(phase: .savePending)
        _ = try await engine.enqueue(manifest: savePending, payloads: self.audioPayloads())

        var malformedStart = self.makeManifest(itemID: Self.uuid(87))
        malformedStart.endpoint = TransferEndpointDescriptor(
            destinationKind: .saveThenStart,
            path: "/imports/save",
            startPath: "/imports/start"
        )
        malformedStart.saveThenStart = TransferSaveThenStartState(phase: .startPending)
        _ = try await engine.enqueue(manifest: malformedStart, payloads: self.audioPayloads())

        try await self.waitFor("save items held for attention") {
            (await engine.snapshot()).counters.attentionCount == 2
        }

        XCTAssertEqual(
            // Scoped by path: an in-flight request from a prior test's engine can outlive teardown.
            TransferURLProtocol.requests.filter { request in
                request.url?.path == "/imports/save" || request.url?.path == "/imports/start"
            }.count,
            0
        )
        XCTAssertEqual(events.withLock { values in values.filter { $0.outcome == .needsAttention }.count }, 2)
    }

    func testPacerNeverTerminalsTransientAndCapsDelayAcrossManyFailures() {
        let pacer = TransferPacer()
        let itemID = UUID()

        for attempt in 1...25 {
            let decision = pacer.delay(for: TransferPacerInput(
                itemID: itemID,
                source: "alpha",
                attemptCount: attempt,
                lastOutcome: .timeout
            ))
            XCTAssertLessThanOrEqual(decision.delay, 300)
            XCTAssertGreaterThanOrEqual(decision.delay, 0)
        }
    }

    func testEngineKeepsTransientOutcomesQueuedAcrossManyFailures() async throws {
        let steps = OSAllocatedUnfairLock<[TransferTransientStep]>(initialState: (0..<25).map { index in
            switch index % 3 {
            case 0:
                return .status(503)
            case 1:
                return .urlIssue(.timedOut)
            default:
                return .urlIssue(.cancelled)
            }
        })
        TransferURLProtocol.handler = { request, _ in
            guard let step = steps.withLock({ values -> TransferTransientStep? in
                values.isEmpty ? nil : values.removeFirst()
            }) else {
                return TransferURLProtocol.hold(request)
            }
            switch step {
            case .status(let statusCode):
                let data = statusCode == 200 ? Data(#"{"status":"ok"}"#.utf8) : Data()
                return (Self.response(for: request, statusCode: statusCode), data)
            case .urlIssue(let code):
                throw URLError(code)
            }
        }
        let clock = FakeTransferClock(wall: Self.baseDate)
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let pacer = TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [400], maxDelay: 300, jitterSalt: 1))
        let engine = self.makeEngine(
            clock: clock,
            pacer: pacer,
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )
        try await engine.start()
        let itemID = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(88)), payloads: self.audioPayloads())

        for attempt in 1...25 {
            try await self.waitFor("retry \(attempt)", timeout: .seconds(4)) {
                events.withLock { values in values.filter { $0.outcome == .retrying }.count >= attempt }
            }
            let snapshot = await engine.snapshot()
            XCTAssertEqual(snapshot.counters.attentionCount, 0)
            XCTAssertEqual(snapshot.counters.deliveredCount, 0)
            XCTAssertEqual(snapshot.counters.queuedCount, 1)
            try await self.waitFor("sleep \(attempt)") {
                clock.sleepDurations.count >= attempt
            }
            XCTAssertLessThanOrEqual(clock.sleepDurations[attempt - 1], 300)
            if attempt < 25 {
                clock.advanceWall(by: 300)
                clock.resumeSleeps()
            }
        }

        await engine.pause()
        clock.resumeSleeps()
        await engine.drop(itemID: itemID)
        let finalSnapshot = await engine.snapshot()
        XCTAssertEqual(finalSnapshot.counters.attentionCount, 0)
        XCTAssertEqual(finalSnapshot.counters.deliveredCount, 0)
    }

    func testRetryPersistenceFailureStillAppliesInMemoryBackoffAndDiagnostic() async throws {
        let fileSystem = FailingManifestWriteFileSystem()
        let spool = TransferSpool(rootURL: self.tempDirectory, fileSystem: fileSystem)
        let clock = FakeTransferClock(wall: Self.baseDate)
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let itemID = Self.uuid(89)
        TransferURLProtocol.handler = { request, _ in
            // Scoped by item: an in-flight request from a prior test's engine can outlive teardown.
            if Self.boundaryItemID(from: request) == itemID {
                fileSystem.failManifestWrites = true
                return (Self.response(for: request, statusCode: 503), Data())
            }
            return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let engine = self.makeEngine(
            spool: spool,
            clock: clock,
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [60], maxDelay: 300, jitterSalt: 1)),
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )
        try await engine.start()
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: itemID), payloads: self.audioPayloads())

        try await self.waitFor("retry persistence diagnostic") {
            events.withLock { values in
                values.contains { $0.outcome == .retrying && $0.shortDetail == "retry persistence failed" }
            }
        }
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.attentionCount, 0)
        try await self.waitFor("retry sleep after persistence failure") {
            clock.sleepDurations.count == 1
        }
        XCTAssertGreaterThan(clock.sleepDurations[0], 0)
        XCTAssertLessThanOrEqual(clock.sleepDurations[0], 300)
    }

    func testAtomicEnqueueCrashBeforeCommitLeavesOnlyDiscardableStaging() throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let staged = try spool.stage(manifest: self.makeManifest(), payloads: self.audioPayloads())

        let snapshot = try TransferSpool(rootURL: self.tempDirectory).initialize(now: Self.baseDate)

        XCTAssertEqual(snapshot.queued.count, 1)
        XCTAssertEqual(snapshot.attention.count, 0)
        let queuedURL = self.tempDirectory
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
            .appendingPathComponent(staged.item.manifest.itemID.uuidString, isDirectory: true)
        let salvageRootURL = self.tempDirectory
            .appendingPathComponent(TransferSpool.salvageDirectoryName, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: queuedURL.path))
        XCTAssertFalse(self.pathExists(containing: staged.item.manifest.itemID.uuidString, under: salvageRootURL))

        let committed = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.directoryURL.path))
    }

    func testMissingRequiredPayloadMovesQueuedItemToAttention() throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let committed = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        let audioPart = try XCTUnwrap(committed.manifest.payloadParts.first)
        try FileManager.default.removeItem(at: try spool.payloadURL(for: audioPart, in: committed.directoryURL))

        let snapshot = try spool.initialize(now: Self.baseDate)

        XCTAssertEqual(snapshot.queued.count, 0)
        XCTAssertEqual(snapshot.attention.count, 1)
        XCTAssertEqual(snapshot.attention.first?.manifest.attention?.reason, "missing_payload")
    }

    func testInitScanAdoptsDirectoryStateForMidMoveManifests() throws {
        let queuedRoot = self.tempDirectory.appendingPathComponent("queued-mismatch", isDirectory: true)
        let queuedSpool = TransferSpool(rootURL: queuedRoot)
        let queuedItem = try queuedSpool.commitStagedItem(itemID: queuedSpool.stage(
            manifest: self.makeManifest(itemID: Self.uuid(81)),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        try queuedSpool.writeManifestAtomically(queuedItem.manifest.replacingDiskState(.attention), in: queuedItem.directoryURL)

        let queuedSnapshot = try TransferSpool(rootURL: queuedRoot).initialize(now: Self.baseDate)

        XCTAssertEqual(queuedSnapshot.queued.count, 1)
        XCTAssertEqual(queuedSnapshot.attention.count, 0)
        XCTAssertEqual(queuedSnapshot.queued.first?.manifest.diskState, .queued)
        XCTAssertEqual(try TransferSpool(rootURL: queuedRoot).initialize(now: Self.baseDate).queued.first?.manifest.diskState, .queued)

        let attentionRoot = self.tempDirectory.appendingPathComponent("attention-mismatch", isDirectory: true)
        let attentionSpool = TransferSpool(rootURL: attentionRoot)
        let attentionItem = try attentionSpool.moveQueuedItemToAttention(
            try attentionSpool.commitStagedItem(itemID: attentionSpool.stage(
                manifest: self.makeManifest(itemID: Self.uuid(82)),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        try attentionSpool.writeManifestAtomically(attentionItem.manifest.replacingDiskState(.queued), in: attentionItem.directoryURL)

        let attentionSnapshot = try TransferSpool(rootURL: attentionRoot).initialize(now: Self.baseDate)

        XCTAssertEqual(attentionSnapshot.queued.count, 0)
        XCTAssertEqual(attentionSnapshot.attention.count, 1)
        XCTAssertEqual(attentionSnapshot.attention.first?.manifest.diskState, .attention)
        XCTAssertEqual(try TransferSpool(rootURL: attentionRoot).initialize(now: Self.baseDate).attention.first?.manifest.diskState, .attention)
    }

    func testOptionalUnusedPayloadDoesNotBlockObserverDelivery() async throws {
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        var manifest = self.makeManifest(itemID: Self.uuid(83))
        manifest.payloadParts.append(TransferPayloadPartDescriptor(
            partID: "notes",
            kind: .file,
            relativePath: "notes.txt",
            filename: "notes.txt",
            contentType: "text/plain",
            requiredForDispatch: false
        ))
        manifest.payloadParts.append(TransferPayloadPartDescriptor(
            partID: "location",
            kind: .location,
            relativePath: "location.jsonl",
            filename: "location.jsonl",
            contentType: "application/x-ndjson",
            requiredForDispatch: false
        ))
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let committed = try spool.commitStagedItem(itemID: spool.stage(
            manifest: manifest,
            payloads: [
                "audio": Data("audio".utf8),
                "notes": Data("notes".utf8),
                "location": Data("{\"event\":\"loc\"}\n".utf8),
            ]
        ).item.manifest.itemID)
        for partID in ["notes", "location"] {
            let part = try XCTUnwrap(committed.manifest.payloadParts.first { $0.partID == partID })
            try FileManager.default.removeItem(at: try spool.payloadURL(for: part, in: committed.directoryURL))
        }
        let engine = self.makeEngine(spool: spool)
        try await engine.start()

        try await self.waitFor("delivered") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }
        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.attentionCount, 0)
    }

    func testInitRecoveryEmitsDiagnosticForMissingPayloadMove() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let committed = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(itemID: Self.uuid(84)),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        let audioPart = try XCTUnwrap(committed.manifest.payloadParts.first)
        try FileManager.default.removeItem(at: try spool.payloadURL(for: audioPart, in: committed.directoryURL))
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let engine = self.makeEngine(
            spool: spool,
            resolver: TransferEndpointResolverStub(.unavailable("held")),
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )

        try await engine.start()

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.attentionCount, 1)
        XCTAssertTrue(events.withLock { values in
            values.contains {
                $0.itemID == Self.uuid(84)
                    && $0.previousState == .queued
                    && $0.nextState == .attention
                    && $0.outcome == .needsAttention
                    && $0.shortDetail == "audio.m4a"
            }
        })
    }

    func testEndpointAvailabilityEdgesEmitBoundedDiagnostics() async throws {
        let resolver = TransferEndpointResolverStub(.unavailable("held"))
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        TransferURLProtocol.handler = { request, _ in
            TransferURLProtocol.hold(request)
        }
        let engine = self.makeEngine(
            resolver: resolver,
            diagnosticsSink: { event in events.withLock { $0.append(event) } }
        )
        try await engine.start()
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(85)), payloads: self.audioPayloads())

        try await self.waitFor("held edge") {
            events.withLock { values in values.filter { $0.outcome == .held }.count == 1 }
        }
        await engine.endpointAvailabilityChanged()
        await engine.endpointAvailabilityChanged()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(events.withLock { values in values.filter { $0.outcome == .held }.count }, 1)

        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await engine.endpointAvailabilityChanged()

        try await self.waitFor("resumed edge") {
            events.withLock { values in values.filter { $0.outcome == .resumed }.count == 1 }
        }
        XCTAssertEqual(events.withLock { values in values.filter { $0.outcome == .held }.count }, 1)
    }

    func testDispatchSelectionRespectsFreshPriorityRoundRobinConcurrencyAndPause() async throws {
        TransferURLProtocol.handler = { request, _ in
            TransferURLProtocol.hold(request)
        }
        let clock = FakeTransferClock(wall: Self.baseDate)
        let engine = self.makeEngine(clock: clock, maxConcurrent: 2)
        try await engine.start()

        let alpha = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(1), source: "alpha"),
            payloads: self.audioPayloads()
        )
        let beta = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(2), source: "beta"),
            payloads: self.audioPayloads()
        )
        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(3), source: "alpha"),
            payloads: self.audioPayloads()
        )

        try await self.waitFor("two requests") {
            TransferURLProtocol.requests.count == 2
        }
        let boundaries = TransferURLProtocol.requests.compactMap(Self.boundaryItemID)
        XCTAssertEqual(Set(boundaries), Set([alpha, beta]))
        let inFlightSnapshot = await engine.snapshot()
        XCTAssertEqual(inFlightSnapshot.counters.inFlightCount, 2)

        await engine.pause()
        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(4), source: "gamma"),
            payloads: self.audioPayloads()
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
    }

    func testDispatchPolicyConditionsReduceConcurrencyAndCriticalPauseResumes() async throws {
        let conditions = MutableTransferConditionsProvider()
        let state = OSAllocatedUnfairLock<TransferPolicyDispatchState>(initialState: TransferPolicyDispatchState())
        TransferURLProtocol.handler = { request, _ in
            let phase = conditions.current().lowPowerModeEnabled ? "lowPower" : "normal"
            state.withLock { values in
                if let itemID = Self.boundaryItemID(from: request) {
                    values.dispatches.append(TransferPolicyDispatch(itemID: itemID, phase: phase))
                }
            }
            return TransferURLProtocol.hold(request)
        }
        let engine = self.makeEngine(
            conditions: conditions
        )
        try await engine.start()

        for index in 0..<20 {
            _ = try await engine.enqueue(
                manifest: self.makeManifest(itemID: Self.uuid(500 + index), source: "source-\(index % 3)"),
                payloads: self.audioPayloads()
            )
        }

        try await self.waitFor("initial two dispatches") {
            let normalDispatches = state.withLock { values in
                values.dispatches.filter { $0.phase == "normal" }.count
            }
            let snapshot = await engine.snapshot()
            return normalDispatches == 2 && snapshot.counters.inFlightCount == 2
        }
        conditions.update(lowPowerModeEnabled: true)
        await engine.kick()
        TransferURLProtocol.completeHeld(2)

        try await self.waitFor("first low power dispatch") {
            let lowPowerDispatches = state.withLock { values in
                values.dispatches.filter { $0.phase == "lowPower" }.count
            }
            let snapshot = await engine.snapshot()
            return lowPowerDispatches == 1 && snapshot.counters.inFlightCount == 1
        }
        TransferURLProtocol.completeHeld(1)
        try await self.waitFor("second low power dispatch") {
            let lowPowerDispatches = state.withLock { values in
                values.dispatches.filter { $0.phase == "lowPower" }.count
            }
            let snapshot = await engine.snapshot()
            return lowPowerDispatches == 2 && snapshot.counters.inFlightCount == 1
        }

        XCTAssertEqual(state.withLock { $0.dispatches.filter { $0.phase == "normal" }.count }, 2)
        XCTAssertEqual(state.withLock { $0.dispatches.filter { $0.phase == "lowPower" }.count }, 2)

        await engine.pause()
    }

    func testCriticalPolicyPauseStopsNewDispatchesAndKickResumesAfterLift() async throws {
        let conditions = MutableTransferConditionsProvider()
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        TransferURLProtocol.handler = { request, _ in
            TransferURLProtocol.hold(request)
        }
        let engine = self.makeEngine(
            diagnosticsSink: { event in events.withLock { $0.append(event) } },
            conditions: conditions
        )
        try await engine.start()
        let thirdID = Self.uuid(620)
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(618)), payloads: self.audioPayloads())
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(619)), payloads: self.audioPayloads())
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: thirdID), payloads: self.audioPayloads())

        try await self.waitFor("two in flight") {
            let snapshot = await engine.snapshot()
            return TransferURLProtocol.requests.count == 2 && snapshot.counters.inFlightCount == 2
        }
        conditions.update(thermalState: .critical)
        await engine.kick()
        TransferURLProtocol.completeHeld(2)

        try await self.waitFor("policy paused after in-flight completion") {
            let snapshot = await engine.snapshot()
            return snapshot.counters.deliveredCount == 2
                && snapshot.counters.inFlightCount == 0
                && snapshot.policyPaused
        }
        XCTAssertEqual(TransferURLProtocol.requests.count, 2)
        let pausedSnapshot = await engine.snapshot()
        XCTAssertEqual(pausedSnapshot.paused, false)
        XCTAssertTrue(events.withLock { values in
            values.contains { $0.outcome == .paused && $0.shortDetail == "thermal critical" }
        })

        conditions.update(thermalState: .nominal)
        await engine.kick()
        try await self.waitFor("dispatch resumes after policy lift") {
            TransferURLProtocol.requests.compactMap(Self.boundaryItemID(from:)).contains(thirdID)
        }
        XCTAssertTrue(events.withLock { values in
            values.contains { $0.outcome == .resumed && $0.shortDetail == "policy resumed" }
        })
    }

    func testCriticalPolicyPauseIsNotTerminalAndDoesNotConsumeAttempts() async throws {
        let conditions = MutableTransferConditionsProvider(thermalState: .critical)
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let engine = self.makeEngine(
            diagnosticsSink: { event in events.withLock { $0.append(event) } },
            conditions: conditions
        )
        try await engine.start()
        let itemID = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(621)),
            payloads: self.audioPayloads()
        )

        try await self.waitFor("policy pause snapshot") {
            (await engine.snapshot()).policyPaused
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(snapshot.counters.attentionCount, 0)
        XCTAssertEqual(snapshot.paused, false)
        XCTAssertEqual(snapshot.policyPaused, true)
        let itemSnapshot = await engine.itemSnapshot(itemID: itemID)
        XCTAssertEqual(itemSnapshot?.attempts, 0)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
        XCTAssertFalse(events.withLock { values in values.contains { $0.outcome == .needsAttention } })
    }

    func testDispatchPolicyDelayUsesTransferClockBetweenDispatches() async throws {
        let conditions = MutableTransferConditionsProvider(thermalState: .serious)
        let clock = FakeTransferClock(wall: Self.baseDate)
        var defaults = TransferDispatchPolicyDefaults.standard
        defaults.throttledConcurrency = defaults.normalConcurrency
        TransferURLProtocol.handler = { request, _ in
            TransferURLProtocol.hold(request)
        }
        let engine = self.makeEngine(
            clock: clock,
            conditions: conditions,
            dispatchPolicy: TransferDispatchPolicy(defaults: defaults)
        )
        try await engine.start()
        await engine.pause()
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(630)), payloads: self.audioPayloads())
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(631)), payloads: self.audioPayloads())
        await engine.resume()

        try await self.waitFor("first dispatch before delay") {
            TransferURLProtocol.requests.count == 1 && clock.sleepDurations == [0.5]
        }
        clock.resumeSleeps()
        try await self.waitFor("second dispatch after delay") {
            TransferURLProtocol.requests.count == 2
        }

        let dispatched = TransferURLProtocol.requests.compactMap(Self.boundaryItemID(from:))
        XCTAssertEqual(dispatched, [Self.uuid(630), Self.uuid(631)])
        XCTAssertEqual(clock.sleepDurations, [0.5])
        await engine.pause()
    }

    @MainActor
    func testSnapshotBackoffEndpointHeldAndMirrorFieldsPopulate() async throws {
        let mirror = TransferStatusMirror()
        let clock = FakeTransferClock(wall: Self.baseDate)
        let resolver = TransferEndpointResolverStub(.unavailable("waiting"))
        let engine = self.makeEngine(
            clock: clock,
            resolver: resolver,
            statusMirror: mirror
        )
        try await engine.start()
        let nextAttemptAt = Self.baseDate.addingTimeInterval(60)
        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(640), nextAttemptAt: nextAttemptAt),
            payloads: self.audioPayloads()
        )
        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(641)),
            payloads: self.audioPayloads()
        )

        try await self.waitFor("snapshot backoff and endpoint held") {
            let snapshot = await engine.snapshot()
            return snapshot.backoffPendingCount == 1
                && snapshot.soonestNextAttemptAt == nextAttemptAt
                && snapshot.endpointHeld
        }
        try await self.waitFor("mirror backoff and endpoint held") {
            await MainActor.run {
                mirror.backoffPendingCount == 1
                    && mirror.soonestNextAttemptAt == nextAttemptAt
                    && mirror.endpointHeld
            }
        }
    }

    func testBackoffRefreshClearsStaleEndpointHoldWhenEndpointReturns() async throws {
        let clock = FakeTransferClock(wall: Self.baseDate)
        let resolver = TransferEndpointResolverStub(.unavailable("waiting"))
        let engine = self.makeEngine(clock: clock, resolver: resolver)
        try await engine.start()

        let heldItemID = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(642)),
            payloads: self.audioPayloads()
        )
        try await self.waitFor("endpoint held") {
            (await engine.snapshot()).endpointHeld
        }
        await engine.drop(itemID: heldItemID)

        let nextAttemptAt = Self.baseDate.addingTimeInterval(60)
        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(643), nextAttemptAt: nextAttemptAt),
            payloads: self.audioPayloads()
        )
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await engine.endpointAvailabilityChanged()

        try await self.waitFor("stale endpoint hold cleared") {
            let snapshot = await engine.snapshot()
            return snapshot.backoffPendingCount == 1
                && snapshot.soonestNextAttemptAt == nextAttemptAt
                && !snapshot.endpointHeld
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(
            evaluateDrainRound(DrainRoundInput(
                previousTotal: 1,
                currentTotal: snapshot.counters.queuedCount,
                inFlight: snapshot.counters.inFlightCount,
                stalledRounds: 1,
                backoffPendingCount: snapshot.backoffPendingCount,
                endpointHeld: snapshot.endpointHeld
            )),
            .keepGoing(previousTotal: 1, stalledRounds: 0)
        )
    }

    func testDropInFlightAndAlreadyGoneAreNoOps() async throws {
        let gate = DispatchSemaphore(value: 0)
        TransferURLProtocol.handler = { request, _ in
            _ = gate.wait(timeout: .now() + .seconds(5))
            return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let engine = self.makeEngine()
        try await engine.start()
        let itemID = try await engine.enqueue(manifest: self.makeManifest(), payloads: self.audioPayloads())
        try await self.waitFor("in flight") {
            (await engine.snapshot()).counters.inFlightCount == 1
        }

        await engine.drop(itemID: itemID)
        gate.signal()
        try await Task.sleep(for: .milliseconds(100))
        await engine.drop(itemID: itemID)

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.attentionCount, 0)
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.deliveredCount, 0)
    }

    func testDropDuringDispatchSuspensionDoesNotDoubleDecrementSourceInFlight() async throws {
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let resolver = SecondResolveSuspendingResolver()
        let engine = self.makeEngine(resolver: resolver, bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) })
        try await engine.start()
        let itemID = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(90)), payloads: self.audioPayloads())

        await resolver.waitUntilParked()
        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.sources["alpha"]?.inFlightCount, 1)
        await engine.drop(itemID: itemID)
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.sources["alpha"]?.inFlightCount, 0)

        await resolver.resumeUnavailable()
        try await Task.sleep(for: .milliseconds(100))
        snapshot = await engine.snapshot()
        let sourceInFlightCount = snapshot.sources.values.reduce(0) { $0 + $1.inFlightCount }
        XCTAssertEqual(snapshot.sources["alpha"]?.inFlightCount, 0)
        XCTAssertEqual(snapshot.counters.inFlightCount, sourceInFlightCount)
    }

    func testPauseDuringEligibleResolvePreventsDispatch() async throws {
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let resolver = FirstResolveSuspendingResolver()
        let engine = self.makeEngine(resolver: resolver, bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) })
        try await engine.start()
        let itemID = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(91)), payloads: self.audioPayloads())

        await resolver.waitUntilParked()
        await engine.pause()
        await resolver.resumeAvailable()
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(
            TransferURLProtocol.requests.filter { Self.boundaryItemID(from: $0) == itemID }.count,
            0
        )
    }

    func testBodyUploadBuiltOnceReusedAcrossRetriesAndRemovedAfterDelivery() async throws {
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let statusCodes = OSAllocatedUnfairLock<[Int]>(initialState: [500, 500, 200])
        TransferURLProtocol.handler = { request, _ in
            let status = statusCodes.withLock { values in values.removeFirst() }
            let data = status == 200 ? Data(#"{"status":"ok"}"#.utf8) : Data()
            return (Self.response(for: request, statusCode: status), data)
        }
        let pacer = TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300, jitterSalt: 1))
        let engine = self.makeEngine(pacer: pacer, bodyBuilder: { _, _ in
            callCount.withLock { $0 += 1 }
            return .inMemory(Data("body-once".utf8))
        })
        try await engine.start()
        _ = try await engine.enqueue(manifest: self.makeManifest(), payloads: self.audioPayloads())

        try await self.waitFor("delivery") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }

        XCTAssertEqual(callCount.withLock { $0 }, 1)
        let finalSnapshot = await engine.snapshot()
        XCTAssertEqual(finalSnapshot.counters.queuedCount, 0)
    }

    @MainActor
    func testObserverIngestV3EnvelopeContainsOnlyAuthorityFields() throws {
        let boundary = "Boundary-omi"
        let body = try ObserverIngestMultipartBody.build(payload: ObserverIngestMultipartPayload(
            boundary: boundary,
            day: "20260420",
            segment: "120000_3",
            source: "mobile-segment",
            platform: "ios",
            startedAt: Self.baseDate,
            durationS: 3,
            sources: ["audio"],
            chunkIndex: 7,
            sessionID: Self.uuid(8),
            modeRawValue: ObserverMode.meeting.rawValue,
            omiMetadata: .object([
                "connection_state": .string("connected"),
                "segment": .string("cannot-shadow"),
                "day": .string("cannot-shadow"),
            ]),
            parts: [ObserverIngestMultipartPart(filename: "audio.m4a", contentType: "audio/mp4", data: Data("audio".utf8))]
        ))

        let envelope = try self.multipartEnvelope(body, boundary: boundary)
        XCTAssertEqual(Set(envelope.keys), ["day", "segment", "source", "files", "meta"])
        XCTAssertEqual(envelope["day"] as? String, "20260420")
        XCTAssertEqual(envelope["segment"] as? String, "120000_3")
        XCTAssertEqual(envelope["source"] as? String, "mobile-segment")
        XCTAssertEqual(envelope["files"] as? [[String: String]], [["submitted": "audio.m4a"]])
        let meta = try XCTUnwrap(envelope["meta"] as? [String: Any])
        XCTAssertNil(meta["segment"])
        XCTAssertNil(meta["day"])
        XCTAssertNil(meta["source"])
        XCTAssertEqual(meta["platform"] as? String, "ios")
        XCTAssertEqual(meta["chunk_index"] as? Int, 7)
        let omi = try XCTUnwrap(meta["omi"] as? [String: Any])
        XCTAssertEqual(omi["connection_state"] as? String, "connected")
        XCTAssertEqual(omi["segment"] as? String, "cannot-shadow")
        XCTAssertEqual(omi["day"] as? String, "cannot-shadow")
    }

    func testDescriptorDrivenObserverBodySupportsFileTextAndAbsentOptionalPart() throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        var manifest = self.makeManifest(itemID: Self.uuid(502))
        manifest.payloadParts = [
            TransferPayloadPartDescriptor(partID: "file", kind: .file, relativePath: "note.txt", filename: "note.txt", contentType: "text/plain"),
            TransferPayloadPartDescriptor(partID: "text", kind: .text, relativePath: "caption.txt", filename: "caption.txt", contentType: "text/plain"),
            TransferPayloadPartDescriptor(partID: "optional", kind: .file, relativePath: "optional.bin", filename: "optional.bin", contentType: "application/octet-stream", requiredForDispatch: false),
        ]
        let item = try spool.stage(
            manifest: manifest,
            payloads: [
                "file": Data("file-bytes".utf8),
                "text": Data("text-bytes".utf8),
                "optional": Data("optional-bytes".utf8),
            ]
        ).item
        let optionalPart = try XCTUnwrap(item.manifest.payloadParts.first { $0.partID == "optional" })
        try FileManager.default.removeItem(at: try spool.payloadURL(for: optionalPart, in: item.directoryURL))

        let body = try self.bodyData(DefaultTransferBodyBuilder.build(item: item, spool: spool))
        let envelope = try self.multipartEnvelope(body, boundary: TransferTransport.boundary(for: manifest.itemID))
        XCTAssertEqual(envelope["files"] as? [[String: String]], [["submitted": "note.txt"], ["submitted": "caption.txt"]])
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains(#"filename="note.txt""#))
        XCTAssertTrue(text.contains(#"filename="caption.txt""#))
        XCTAssertFalse(text.contains(#"filename="optional.bin""#))
        XCTAssertFalse(text.contains(#"name="segment""#))
        XCTAssertFalse(text.contains(#"name="day""#))
        XCTAssertFalse(text.contains(#"name="platform""#))
    }

    func testDefaultTransferBodyBuilderCarriesOnlyManifestOmiNamespace() throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let processID = Self.uuid(501)
        let metadata = OmiSegmentMetadata(
            connectionState: "reconnecting",
            processID: processID,
            reconnectCount: 3
        )
        var manifestWithOmi = self.makeManifest(itemID: Self.uuid(502))
        manifestWithOmi.meta = OmiSegmentMetadata.attaching(metadata, to: manifestWithOmi.meta)
        let itemWithOmi = try spool.stage(
            manifest: manifestWithOmi,
            payloads: self.audioPayloads()
        ).item

        let bodyWithOmi = try self.bodyData(DefaultTransferBodyBuilder.build(item: itemWithOmi, spool: spool))
        let envelopeWithOmi = try self.multipartEnvelope(
            bodyWithOmi,
            boundary: TransferTransport.boundary(for: manifestWithOmi.itemID)
        )
        let metaWithOmi = try XCTUnwrap(envelopeWithOmi["meta"] as? [String: Any])
        let omi = try XCTUnwrap(metaWithOmi[OmiSegmentMetadata.key] as? [String: Any])
        XCTAssertEqual(omi["connection_state"] as? String, "reconnecting")
        XCTAssertEqual(omi["process_id"] as? String, processID.uuidString)
        XCTAssertEqual(omi["reconnect_count"] as? Int, 3)

        let manifestWithoutOmi = self.makeManifest(itemID: Self.uuid(503))
        let itemWithoutOmi = try spool.stage(
            manifest: manifestWithoutOmi,
            payloads: self.audioPayloads()
        ).item
        let bodyWithoutOmi = try self.bodyData(DefaultTransferBodyBuilder.build(item: itemWithoutOmi, spool: spool))
        let envelopeWithoutOmi = try self.multipartEnvelope(
            bodyWithoutOmi,
            boundary: TransferTransport.boundary(for: manifestWithoutOmi.itemID)
        )
        let metaWithoutOmi = try XCTUnwrap(envelopeWithoutOmi["meta"] as? [String: Any])
        XCTAssertNil(metaWithoutOmi[OmiSegmentMetadata.key])
    }

    func testCrashTimingHonestyForBodyAndPhaseRecovery() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("a", isDirectory: true))
        _ = try spool.stage(manifest: self.makeManifest(itemID: Self.uuid(31)), payloads: self.audioPayloads())
        XCTAssertEqual(try spool.initialize(now: Self.baseDate).queued.count, 1)

        let buildCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let engine = self.makeEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("b", isDirectory: true)),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            bodyBuilder: { _, _ in
                buildCount.withLock { $0 += 1 }
                return .inMemory(Data("body".utf8))
            }
        )
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        try await engine.start()
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(32)), payloads: self.audioPayloads())
        try await self.waitFor("one delivered") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }
        XCTAssertEqual(buildCount.withLock { $0 }, 1)

        let saveResult = TransferSaveThenStartState(
            phase: .startPending,
            savedPath: "/imports/item",
            savedTimestamp: "2026-04-20T12:00:00Z",
            recommendedAction: "start"
        )
        XCTAssertEqual(
            TransferHTTPClassifier.classify(
                result: TransferHTTPResult(statusCode: 400, data: Data(#"{"reason_code":"invalid_operation_for_state"}"#.utf8)),
                endpointPhase: .start(saveResult: saveResult)
            ),
            .terminalSuccess(.alreadyStartedOrComplete(serverPath: "/imports/item", serverTimestamp: "2026-04-20T12:00:00Z"))
        )
    }

    func testHotPathCountersDoNotEnumerateDirectories() async throws {
        let fileSystem = CountingTransferFileSystem()
        let spool = TransferSpool(rootURL: self.tempDirectory, fileSystem: fileSystem)
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        let engine = self.makeEngine(spool: spool, bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) })
        try await engine.start()
        fileSystem.resetEnumerationCount()

        _ = try await engine.enqueue(manifest: self.makeManifest(), payloads: self.audioPayloads())
        try await self.waitFor("delivered") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }
        _ = await engine.snapshot()

        XCTAssertEqual(fileSystem.enumerationCount, 0)
    }

    @MainActor
    func testStatusMirrorUpdatesAreCoalescedBelowItemCount() async throws {
        let mirror = TransferStatusMirror()
        let engine = self.makeEngine(
            resolver: TransferEndpointResolverStub(.unavailable("held")),
            statusMirror: mirror,
            maxConcurrent: 1,
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
        try await engine.start()

        for index in 0..<100 {
            _ = try await engine.enqueue(
                manifest: self.makeManifest(itemID: Self.uuid(1_000 + index), source: "alpha"),
                payloads: self.audioPayloads()
            )
        }
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertLessThanOrEqual(mirror.applyCount, 20)
        XCTAssertEqual(mirror.queuedCount, 100)
    }

    func testParkedEngineSleepsOnlyOnWakeOrDeadline() async throws {
        let clock = FakeTransferClock(wall: Self.baseDate)
        let engine = self.makeEngine(clock: clock, resolver: TransferEndpointResolverStub(.unavailable("held")))
        try await engine.start()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(clock.sleepCallCount, 0)

        let futureManifest = self.makeManifest(nextAttemptAt: Self.baseDate.addingTimeInterval(60))
        let engineWithDeadline = self.makeEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("deadline", isDirectory: true)),
            clock: clock,
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
        try await engineWithDeadline.start()
        _ = try await engineWithDeadline.enqueue(manifest: futureManifest, payloads: self.audioPayloads())
        try await self.waitFor("single sleep") {
            clock.sleepCallCount == 1
        }
    }

    func testPacerJitterRangeAndNonConstantDistribution() {
        let defaults = TransferPacerDefaults(ladderSeconds: [40], maxDelay: 300, jitterSalt: 42)
        let pacer = TransferPacer(defaults: defaults)
        let delays = (0..<20).map { index in
            pacer.delay(for: TransferPacerInput(
                itemID: Self.uuid(2_000 + index),
                source: "alpha",
                attemptCount: 1,
                lastOutcome: .timeout
            )).delay
        }

        XCTAssertTrue(delays.allSatisfy { (30...50).contains($0) })
        XCTAssertGreaterThan(Set(delays.map { Int($0 * 1000) }).count, 1)
    }

    func testRetryAttentionAllAndPerSource() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let alpha = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(itemID: Self.uuid(41), source: "alpha"),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        _ = alpha
        _ = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(itemID: Self.uuid(42), source: "beta"),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let engine = self.makeEngine(spool: spool)
        try await engine.start()

        try await engine.retryAttention(source: "alpha")
        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.attentionCount, 1)

        try await engine.retryAttention()
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 2)
        XCTAssertEqual(snapshot.counters.attentionCount, 0)
    }

    func testRetryAuthenticationAttentionOnlyRequeuesInvalidPairingKey() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("retry-auth", isDirectory: true))
        let authID = Self.uuid(43)
        let unrelatedHTTPID = Self.uuid(44)
        let unrelatedReasonID = Self.uuid(45)
        for (itemID, reason, detail) in [
            (authID, "http_client_error", #"{ "error": "Invalid key", "reason_code": "auth_key_invalid" }"#),
            (unrelatedHTTPID, "http_client_error", #"{"reason_code":"invalid_payload"}"#),
            (unrelatedReasonID, "missing_payload", #"{"reason_code":"auth_key_invalid"}"#),
        ] {
            _ = try spool.moveQueuedItemToAttention(
                try spool.commitStagedItem(itemID: spool.stage(
                    manifest: self.makeManifest(itemID: itemID, source: "alpha"),
                    payloads: self.audioPayloads()
                ).item.manifest.itemID),
                reason: reason,
                detail: detail,
                now: Self.baseDate
            )
        }
        let engine = self.makeEngine(
            spool: spool,
            resolver: TransferEndpointResolverStub(.unavailable("held"))
        )
        try await engine.start()

        try await engine.retryAuthenticationAttention()

        let snapshot = await engine.snapshot()
        let authItem = await engine.itemSnapshot(itemID: authID)
        let unrelatedHTTPItem = await engine.itemSnapshot(itemID: unrelatedHTTPID)
        let unrelatedReasonItem = await engine.itemSnapshot(itemID: unrelatedReasonID)
        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.attentionCount, 2)
        XCTAssertNil(authItem?.manifest.attention)
        XCTAssertNotNil(unrelatedHTTPItem?.manifest.attention)
        XCTAssertNotNil(unrelatedReasonItem?.manifest.attention)
    }

    func testRetryAuthenticationAttentionCanBeScopedToRecoveredSource() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("retry-auth-source", isDirectory: true))
        let alphaID = Self.uuid(46)
        let betaID = Self.uuid(47)
        for (itemID, source) in [(alphaID, "alpha"), (betaID, "beta")] {
            _ = try spool.moveQueuedItemToAttention(
                try spool.commitStagedItem(itemID: spool.stage(
                    manifest: self.makeManifest(itemID: itemID, source: source),
                    payloads: self.audioPayloads()
                ).item.manifest.itemID),
                reason: "http_client_error",
                detail: #"{"reason_code":"auth_key_invalid"}"#,
                now: Self.baseDate
            )
        }
        let engine = self.makeEngine(
            spool: spool,
            resolver: TransferEndpointResolverStub(.unavailable("held"))
        )
        try await engine.start()

        try await engine.retryAuthenticationAttention(source: "alpha")

        let alpha = await engine.itemSnapshot(itemID: alphaID)
        let beta = await engine.itemSnapshot(itemID: betaID)
        XCTAssertNil(alpha?.manifest.attention)
        XCTAssertNotNil(beta?.manifest.attention)
    }

    func testFreshBandBoundaryAtFifteenMinutes() async throws {
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let clock = FakeTransferClock(wall: Self.baseDate)
        let buildOrder = OSAllocatedUnfairLock<[UUID]>(initialState: [])
        let engine = self.makeEngine(
            clock: clock,
            maxConcurrent: 3,
            bodyBuilder: { item, _ in
                buildOrder.withLock { $0.append(item.manifest.itemID) }
                return .inMemory(Data("body".utf8))
            }
        )
        try await engine.start()
        await engine.pause()

        let stale = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(51), createdAt: Self.baseDate.addingTimeInterval(-901)),
            payloads: self.audioPayloads()
        )
        let fresh = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(52), createdAt: Self.baseDate.addingTimeInterval(-899)),
            payloads: self.audioPayloads()
        )
        let exact = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(53), createdAt: Self.baseDate.addingTimeInterval(-900)),
            payloads: self.audioPayloads()
        )
        _ = stale

        await engine.resume()
        try await self.waitFor("three dispatches") {
            buildOrder.withLock { $0.count == 3 }
        }
        let firstTwo = buildOrder.withLock { Array($0.prefix(2)) }
        XCTAssertEqual(Set(firstTwo), Set([fresh, exact]))
    }

    func testPersistedFutureNextAttemptClampAndRebootGate() async throws {
        let clock = FakeTransferClock(wall: Self.baseDate)
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("restart", isDirectory: true))
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(itemID: Self.uuid(61), nextAttemptAt: Self.baseDate.addingTimeInterval(60)),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(itemID: Self.uuid(62), nextAttemptAt: Self.baseDate.addingTimeInterval(600)),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)

        let freshEngine = self.makeEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("restart", isDirectory: true)),
            clock: clock,
            maxConcurrent: 1,
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
        try await freshEngine.start()

        try await self.waitFor("clamped request") {
            TransferURLProtocol.requests.count == 1
        }
        XCTAssertEqual(Self.boundaryItemID(from: try XCTUnwrap(TransferURLProtocol.requests.first)), Self.uuid(62))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 1)
    }

    func testFileURLEnqueueMovesPayloadsWithoutReadingPayloadData() async throws {
        let fileSystem = CountingTransferFileSystem()
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("file-url", isDirectory: true), fileSystem: fileSystem)
        let resolver = TransferEndpointResolverStub(.unavailable("held"))
        let engine = self.makeEngine(spool: spool, resolver: resolver)
        try await engine.start()
        fileSystem.resetDataReadURLs()

        let sourceURL = self.tempDirectory.appendingPathComponent("source-audio.m4a")
        try Data("file-audio".utf8).write(to: sourceURL)
        let manifest = self.makeManifest(itemID: Self.uuid(300))

        _ = try await engine.enqueue(manifest: manifest, payloadFileURLs: ["audio": sourceURL])
        try await self.waitFor("held file item") {
            resolver.resolveCount > 0
        }

        let queuedPayloadURL = self.tempDirectory
            .appendingPathComponent("file-url", isDirectory: true)
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
            .appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
            .appendingPathComponent("audio.m4a", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queuedPayloadURL.path))
        XCTAssertFalse(fileSystem.dataReadURLs.contains { $0.lastPathComponent == "audio.m4a" })
    }

    func testFileURLManifestWriteFailureLeavesSourceBeforeAnyMove() throws {
        let root = self.tempDirectory.appendingPathComponent("manifest-first", isDirectory: true)
        let fileSystem = FailingManifestWriteFileSystem()
        fileSystem.failManifestWrites = true
        let spool = TransferSpool(rootURL: root, fileSystem: fileSystem)
        let sourceURL = self.tempDirectory.appendingPathComponent("manifest-first-source.m4a", isDirectory: false)
        try Data("audio".utf8).write(to: sourceURL)
        let manifest = self.makeManifest(itemID: Self.uuid(307))

        XCTAssertThrowsError(try spool.stage(manifest: manifest, payloadFileURLs: ["audio": sourceURL]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        let stagedAudioURL = root
            .appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
            .appendingPathComponent("audio.m4a", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedAudioURL.path))
    }

    func testInitPromotesCompleteStagingAndSalvagesIncompleteAndDuplicateStaging() throws {
        let root = self.tempDirectory.appendingPathComponent("staging-recovery", isDirectory: true)
        let seedSpool = TransferSpool(rootURL: root)
        let completeID = Self.uuid(301)
        _ = try seedSpool.stage(manifest: self.makeManifest(itemID: completeID), payloads: self.audioPayloads())

        let incompleteID = Self.uuid(302)
        let incomplete = try seedSpool.stage(manifest: self.makeManifest(itemID: incompleteID), payloads: self.audioPayloads())
        let incompletePart = try XCTUnwrap(incomplete.item.manifest.payloadParts.first)
        try FileManager.default.removeItem(at: try seedSpool.payloadURL(for: incompletePart, in: incomplete.item.directoryURL))

        let queuedDuplicateID = Self.uuid(303)
        _ = try seedSpool.commitStagedItem(itemID: seedSpool.stage(
            manifest: self.makeManifest(itemID: queuedDuplicateID),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        _ = try seedSpool.stage(manifest: self.makeManifest(itemID: queuedDuplicateID), payloads: self.audioPayloads())

        let attentionDuplicateID = Self.uuid(305)
        _ = try seedSpool.moveQueuedItemToAttention(
            try seedSpool.commitStagedItem(itemID: seedSpool.stage(
                manifest: self.makeManifest(itemID: attentionDuplicateID),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        _ = try seedSpool.stage(manifest: self.makeManifest(itemID: attentionDuplicateID), payloads: self.audioPayloads())

        let snapshot = try TransferSpool(rootURL: root).initialize(now: Self.baseDate)

        XCTAssertTrue(snapshot.queued.contains { $0.manifest.itemID == completeID })
        XCTAssertEqual(snapshot.queued.filter { $0.manifest.itemID == queuedDuplicateID }.count, 1)
        XCTAssertEqual(snapshot.attention.filter { $0.manifest.itemID == attentionDuplicateID }.count, 1)
        XCTAssertEqual((snapshot.queued + snapshot.attention).filter { $0.manifest.itemID == queuedDuplicateID }.count, 1)
        XCTAssertEqual((snapshot.queued + snapshot.attention).filter { $0.manifest.itemID == attentionDuplicateID }.count, 1)
        XCTAssertTrue(self.pathExists(containing: incompleteID.uuidString, under: root.appendingPathComponent(TransferSpool.salvageDirectoryName)))
        XCTAssertTrue(self.pathExists(containing: queuedDuplicateID.uuidString, under: root.appendingPathComponent(TransferSpool.salvageDirectoryName)))
        XCTAssertTrue(self.pathExists(containing: attentionDuplicateID.uuidString, under: root.appendingPathComponent(TransferSpool.salvageDirectoryName)))
        XCTAssertTrue(snapshot.recoveryDiagnostics.contains { $0.detail == "incomplete_staging" })
        XCTAssertEqual(snapshot.recoveryDiagnostics.filter { $0.detail == "committed_twin_exists" }.count, 2)
    }

    func testStageCollisionSalvagesExistingStagingAndProceeds() throws {
        let root = self.tempDirectory.appendingPathComponent("stage-collision", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let itemID = Self.uuid(306)
        let first = try spool.stage(manifest: self.makeManifest(itemID: itemID), payloads: self.audioPayloads())
        let markerURL = first.item.directoryURL.appendingPathComponent("collision-marker", isDirectory: false)
        try Data("marker".utf8).write(to: markerURL)

        let second = try spool.stage(manifest: self.makeManifest(itemID: itemID), payloads: self.audioPayloads())

        XCTAssertTrue(FileManager.default.fileExists(atPath: second.item.directoryURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(self.pathExists(containing: itemID.uuidString, under: root.appendingPathComponent(TransferSpool.salvageDirectoryName)))
        XCTAssertTrue(self.pathExists(containing: "collision-marker", under: root.appendingPathComponent(TransferSpool.salvageDirectoryName)))
        XCTAssertEqual(second.recoveryDiagnostics.first?.detail, "staging_collision")
    }

    func testFileURLPartialMoveFailureLeavesStagingForRestartSalvage() throws {
        let root = self.tempDirectory.appendingPathComponent("partial-file-url", isDirectory: true)
        let fileSystem = FailingMoveTransferFileSystem(failingPartFilename: "location.jsonl")
        let spool = TransferSpool(rootURL: root, fileSystem: fileSystem)
        var manifest = self.makeManifest(itemID: Self.uuid(304))
        manifest.payloadParts.append(TransferPayloadPartDescriptor(
            partID: "location",
            kind: .location,
            relativePath: "location.jsonl",
            filename: "location.jsonl",
            contentType: "application/x-ndjson"
        ))
        let audioURL = self.tempDirectory.appendingPathComponent("partial-audio.m4a")
        let locationURL = self.tempDirectory.appendingPathComponent("partial-location.jsonl")
        try Data("audio".utf8).write(to: audioURL)
        try Data("{\"event\":\"loc\"}\n".utf8).write(to: locationURL)

        XCTAssertThrowsError(try spool.stage(manifest: manifest, payloadFileURLs: [
            "audio": audioURL,
            "location": locationURL,
        ])) { error in
            XCTAssertEqual(
                error as? TransferSpoolError,
                .partialFileMove(
                    itemID: manifest.itemID,
                    consumedPartIDs: ["audio"],
                    failedPartID: "location",
                    detail: "forced move failure"
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: locationURL.path))
        let stagingItemURL = root
            .appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingItemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root
            .appendingPathComponent(TransferSpool.stagingDirectoryName, isDirectory: true)
            .appendingPathComponent(manifest.itemID.uuidString, isDirectory: true)
            .appendingPathComponent("audio.m4a").path))

        let snapshot = try TransferSpool(rootURL: root).initialize(now: Self.baseDate)
        XCTAssertEqual(snapshot.queued.count, 0)
        XCTAssertTrue(self.pathExists(containing: manifest.itemID.uuidString, under: root.appendingPathComponent(TransferSpool.salvageDirectoryName)))
    }

    func testPerSourceCountersUpdateAndRebuildFromDiskSnapshot() async throws {
        let root = self.tempDirectory.appendingPathComponent("source-counters", isDirectory: true)
        let alphaID = Self.uuid(310)
        let betaID = Self.uuid(311)
        let deliveredID = Self.uuid(312)
        let droppedID = Self.uuid(313)
        TransferURLProtocol.handler = { request, _ in
            if Self.boundaryItemID(from: request) == betaID {
                return (Self.response(for: request, statusCode: 404), Data("missing".utf8))
            }
            return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let resolverA = PathEndpointResolver(availablePaths: ["/attention", "/delivered"])
        let engineA = self.makeEngine(spool: TransferSpool(rootURL: root), resolver: resolverA)
        try await engineA.start()

        var alphaManifest = self.makeManifest(itemID: alphaID, source: "alpha")
        alphaManifest.endpoint = TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/queued")
        _ = try await engineA.enqueue(manifest: alphaManifest, payloads: self.audioPayloads())
        var betaManifest = self.makeManifest(itemID: betaID, source: "beta")
        betaManifest.endpoint = TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/attention")
        _ = try await engineA.enqueue(manifest: betaManifest, payloads: self.audioPayloads())
        var deliveredManifest = self.makeManifest(itemID: deliveredID, source: "delivered")
        deliveredManifest.endpoint = TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/delivered")
        _ = try await engineA.enqueue(manifest: deliveredManifest, payloads: self.audioPayloads())
        var droppedManifest = self.makeManifest(itemID: droppedID, source: "dropped")
        droppedManifest.endpoint = TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/queued")
        _ = try await engineA.enqueue(manifest: droppedManifest, payloads: self.audioPayloads())
        await engineA.drop(itemID: droppedID)

        try await self.waitFor("engine A source states") {
            let snapshot = await engineA.snapshot()
            return snapshot.sources["alpha"]?.queuedCount == 1
                && snapshot.sources["beta"]?.attentionCount == 1
                && snapshot.sources["delivered"]?.deliveredCount == 1
                && snapshot.sources["dropped"]?.droppedCount == 1
        }
        await engineA.pause()

        let engineB = self.makeEngine(
            spool: TransferSpool(rootURL: root),
            resolver: TransferEndpointResolverStub(.unavailable("held"))
        )
        try await engineB.start()
        let snapshot = await engineB.snapshot()

        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.attentionCount, 1)
        XCTAssertEqual(snapshot.counters.deliveredCount, 0)
        XCTAssertEqual(snapshot.counters.droppedCount, 0)
        XCTAssertEqual(snapshot.sources["alpha"]?.queuedCount, 1)
        XCTAssertEqual(snapshot.sources["beta"]?.attentionCount, 1)
        XCTAssertNil(snapshot.sources["delivered"])
        XCTAssertNil(snapshot.sources["dropped"])
        XCTAssertTrue(snapshot.sources.values.allSatisfy { $0.lastDeliveredAt == nil })
        XCTAssertTrue(snapshot.sources.values.allSatisfy { $0.recentErrorCount == 0 })
    }

    func testItemSnapshotsReflectQueuedInFlightAttentionAndAttempts() async throws {
        let root = self.tempDirectory.appendingPathComponent("item-snapshots", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let attentionID = Self.uuid(320)
        _ = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(itemID: attentionID, source: "beta"),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let engine = self.makeEngine(spool: spool)
        try await engine.start()
        let queuedID = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(321), source: "alpha"), payloads: self.audioPayloads())

        try await self.waitFor("in-flight snapshot") {
            (await engine.snapshot()).counters.inFlightCount == 1
        }

        let attentionSnapshot = await engine.itemSnapshot(itemID: attentionID)
        XCTAssertEqual(attentionSnapshot?.state, .attention)
        let queuedSnapshotValue = await engine.itemSnapshot(itemID: queuedID)
        let queuedSnapshot = try XCTUnwrap(queuedSnapshotValue)
        XCTAssertEqual(queuedSnapshot.state, .dispatching)
        XCTAssertEqual(queuedSnapshot.attempts, 1)
        let alphaSnapshots = await engine.itemSnapshots(sourceKey: "alpha")
        XCTAssertEqual(alphaSnapshots.map(\.itemID), [queuedID])
    }

    func testPayloadFileURLReturnsLiveDeclaredFileOnlyWhileCommitted() async throws {
        let resolver = TransferEndpointResolverStub(.unavailable("waiting"))
        let engine = self.makeEngine(resolver: resolver)
        try await engine.start()
        let itemID = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(323)),
            payloads: self.audioPayloads()
        )

        let audioURLValue = await engine.payloadFileURL(itemID: itemID, partID: "audio")
        let audioURL = try XCTUnwrap(audioURLValue)
        XCTAssertEqual(try Data(contentsOf: audioURL), Data("audio".utf8))
        let unknownURL = await engine.payloadFileURL(itemID: Self.uuid(324), partID: "audio")
        XCTAssertNil(unknownURL)
        let undeclaredURL = await engine.payloadFileURL(itemID: itemID, partID: "location")
        XCTAssertNil(undeclaredURL)

        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("payload file removed after delivery") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }

        let deliveredURL = await engine.payloadFileURL(itemID: itemID, partID: "audio")
        XCTAssertNil(deliveredURL)
    }

    func testItemSnapshotMidBackoffShowsAttemptsAndNextAttemptAt() async throws {
        let clock = FakeTransferClock(wall: Self.baseDate)
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 503), Data())
        }
        let engine = self.makeEngine(
            clock: clock,
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [60], maxDelay: 300, jitterSalt: 1)),
            diagnosticsSink: { event in events.withLock { $0.append(event) } },
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
        try await engine.start()
        let itemID = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(322)), payloads: self.audioPayloads())

        try await self.waitFor("retrying item snapshot") {
            events.withLock { values in values.contains { $0.itemID == itemID && $0.outcome == .retrying } }
        }
        let snapshotValue = await engine.itemSnapshot(itemID: itemID)
        let snapshot = try XCTUnwrap(snapshotValue)
        XCTAssertGreaterThanOrEqual(snapshot.attempts, 1)
        XCTAssertNotNil(snapshot.nextAttemptAt)
        XCTAssertEqual(snapshot.state, .queued)
    }

    func testThroughputWindowAggregatesPerSourceAndDecaysAfterWindow() async throws {
        let clock = FakeTransferClock(wall: Self.baseDate)
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        let engine = self.makeEngine(clock: clock, bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) })
        try await engine.start()

        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(330), source: "alpha"), payloads: self.audioPayloads())
        try await self.waitFor("throughput delivery") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }
        var snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.aggregateBytesPerSecond, Double(Data("audio".utf8).count) / 15.0)
        XCTAssertEqual(snapshot.sources["alpha"]?.bytesPerSecond, Double(Data("audio".utf8).count) / 15.0)

        clock.advanceWall(by: 16)
        snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.aggregateBytesPerSecond, 0)
        XCTAssertEqual(snapshot.sources["alpha"]?.bytesPerSecond, 0)
    }

    func testRetryAttentionItemIDMovesOnlyRequestedItem() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("retry-item", isDirectory: true))
        let alphaID = Self.uuid(340)
        _ = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(itemID: alphaID, source: "alpha"),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        _ = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(itemID: Self.uuid(341), source: "beta"),
                payloads: self.audioPayloads()
            ).item.manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        let engine = self.makeEngine(spool: spool, resolver: TransferEndpointResolverStub(.unavailable("held")))
        try await engine.start()

        try await engine.retryAttention(itemID: alphaID)

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 1)
        XCTAssertEqual(snapshot.counters.attentionCount, 1)
        let itemSnapshot = await engine.itemSnapshot(itemID: alphaID)
        XCTAssertEqual(itemSnapshot?.attempts, 0)
    }

    func testDeliveredHookSurvivesRelaunchFromDiskState() async throws {
        let root = self.tempDirectory.appendingPathComponent("hook-relaunch", isDirectory: true)
        let resolverA = TransferEndpointResolverStub(.unavailable("held"))
        let engineA = self.makeEngine(spool: TransferSpool(rootURL: root), resolver: resolverA)
        try await engineA.start()
        let itemID = try await engineA.enqueue(manifest: self.makeManifest(itemID: Self.uuid(350), source: "alpha"), payloads: self.audioPayloads())
        try await self.waitFor("engine A held") {
            resolverA.resolveCount > 0
        }
        await engineA.pause()

        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        let delivered = OSAllocatedUnfairLock<[TransferManifest]>(initialState: [])
        let engineB = self.makeEngine(spool: TransferSpool(rootURL: root))
        await engineB.registerDeliveredHook(sourceKey: "alpha") { manifest, _ in
            delivered.withLock { $0.append(manifest) }
        }
        try await engineB.start()

        try await self.waitFor("hook after relaunch") {
            delivered.withLock { !$0.isEmpty }
        }
        XCTAssertEqual(delivered.withLock { $0.first?.observerIngest?.sessionID }, itemID)
    }

    func testDeliveredHookFiresOncePerDeliveryWithDeliveredManifest() async throws {
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        let delivered = OSAllocatedUnfairLock<[TransferManifest]>(initialState: [])
        let itemID = Self.uuid(351)
        let engine = self.makeEngine(bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) })
        await engine.registerDeliveredHook(sourceKey: "alpha") { manifest, _ in
            delivered.withLock { $0.append(manifest) }
        }
        try await engine.start()

        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: itemID, source: "alpha"), payloads: self.audioPayloads())
        try await self.waitFor("one delivered hook") {
            delivered.withLock { $0.count == 1 }
        }

        let received = try XCTUnwrap(delivered.withLock { $0.first })
        XCTAssertEqual(delivered.withLock { $0.count }, 1)
        XCTAssertEqual(received.itemID, itemID)
        XCTAssertEqual(received.observerIngest?.sessionID, itemID)
    }

    func testDeliveredHookFiresForAllTerminalSuccessKinds() async throws {
        let deliveredID = Self.uuid(352)
        let alreadyID = Self.uuid(353)
        let completeID = Self.uuid(354)
        TransferURLProtocol.handler = { request, _ in
            if request.url?.path == "/imports/start" {
                return (
                    Self.response(for: request, statusCode: 400),
                    Data(#"{"reason_code":"invalid_operation_for_state"}"#.utf8)
                )
            }
            guard let itemID = Self.boundaryItemID(from: request) else {
                return (Self.response(for: request, statusCode: 500), Data())
            }
            if itemID == alreadyID {
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"status":"duplicate"}"#.utf8)
                )
            }
            return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let delivered = OSAllocatedUnfairLock<[UUID]>(initialState: [])
        let engine = self.makeEngine(bodyBuilder: DefaultTransferBodyBuilder.build)
        await engine.registerDeliveredHook(sourceKey: "alpha") { manifest, _ in
            delivered.withLock { $0.append(manifest.itemID) }
        }
        try await engine.start()

        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: deliveredID, source: "alpha"), payloads: self.audioPayloads())
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: alreadyID, source: "alpha"), payloads: self.audioPayloads())
        var completeManifest = self.makeManifest(itemID: completeID, source: "alpha")
        completeManifest.endpoint = TransferEndpointDescriptor(
            destinationKind: .saveThenStart,
            path: "/imports/save",
            startPath: "/imports/start"
        )
        completeManifest.saveThenStart = TransferSaveThenStartState(
            phase: .startPending,
            savedPath: "/imports/item",
            savedTimestamp: "2026-04-20T12:00:00Z",
            recommendedAction: "start"
        )
        _ = try await engine.enqueue(manifest: completeManifest, payloads: self.audioPayloads())

        try await self.waitFor("three terminal success hooks") {
            delivered.withLock { $0.count == 3 }
        }
        XCTAssertEqual(Set(delivered.withLock { $0 }), Set([deliveredID, alreadyID, completeID]))
    }

    func testThrowingDeliveredHookLeavesEngineStateAndCountersUntouched() async throws {
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        let events = OSAllocatedUnfairLock<[TransferDiagnosticEvent]>(initialState: [])
        let itemID = Self.uuid(355)
        let engine = self.makeEngine(
            diagnosticsSink: { event in events.withLock { $0.append(event) } },
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
        await engine.registerDeliveredHook(sourceKey: "alpha") { _, _ in
            throw DeliveredHookTestError.failed
        }
        try await engine.start()

        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: itemID, source: "alpha"), payloads: self.audioPayloads())
        try await self.waitFor("throwing hook diagnostic") {
            events.withLock { values in
                values.contains { $0.itemID == itemID && $0.outcome == .hookFailed }
            }
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.deliveredCount, 1)
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(snapshot.sources["alpha"]?.deliveredCount, 1)
        XCTAssertEqual(snapshot.sources["alpha"]?.queuedCount, 0)
        XCTAssertEqual(snapshot.sources["alpha"]?.inFlightCount, 0)
    }

    func testNoDeliveredHookFiresForDroppedOrAttentionItems() async throws {
        let root = self.tempDirectory.appendingPathComponent("hook-no-fire", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        let droppedID = Self.uuid(356)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(itemID: droppedID, source: "alpha"),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        let attentionID = Self.uuid(357)
        let attentionItem = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(itemID: attentionID, source: "alpha"),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        let audioPart = try XCTUnwrap(attentionItem.manifest.payloadParts.first)
        try FileManager.default.removeItem(at: try spool.payloadURL(for: audioPart, in: attentionItem.directoryURL))

        let resolver = TransferEndpointResolverStub(.unavailable("held"))
        let hookCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), resolver: resolver)
        await engine.registerDeliveredHook(sourceKey: "alpha") { _, _ in
            hookCount.withLock { $0 += 1 }
        }
        try await engine.start()
        try await self.waitFor("dropped item held") {
            resolver.resolveCount > 0
        }
        await engine.drop(itemID: droppedID)
        try await self.waitFor("drop and attention settle") {
            let snapshot = await engine.snapshot()
            return snapshot.counters.droppedCount == 1 && snapshot.counters.attentionCount == 1
        }

        XCTAssertEqual(hookCount.withLock { $0 }, 0)
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)
    }

    func testDeliverySucceedsForSourceWithNoRegisteredHook() async throws {
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        let engine = self.makeEngine(bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) })
        try await engine.start()

        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(358), source: "alpha"), payloads: self.audioPayloads())
        try await self.waitFor("delivery without hook") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.sources["alpha"]?.deliveredCount, 1)
    }

    func testDeliveredHooksAreDetachedFromDeliveryDrain() async throws {
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8)) }
        let gate = HookGate()
        let delivered = OSAllocatedUnfairLock<[UUID]>(initialState: [])
        let firstID = Self.uuid(360)
        let secondID = Self.uuid(361)
        let engine = self.makeEngine(bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) })
        await engine.registerDeliveredHook(sourceKey: "alpha") { manifest, _ in
            if manifest.itemID == firstID {
                await gate.wait()
            }
            delivered.withLock { $0.append(manifest.itemID) }
        }
        try await engine.start()

        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: firstID, source: "alpha"), payloads: self.audioPayloads())
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: secondID, source: "alpha"), payloads: self.audioPayloads())
        try await self.waitFor("two deliveries before first hook resumes") {
            (await engine.snapshot()).counters.deliveredCount == 2
        }
        try await self.waitFor("first hook waiting") {
            await gate.isWaiting
        }
        XCTAssertFalse(delivered.withLock { $0.contains(firstID) })
        await gate.resume()
        try await self.waitFor("first hook resumes") {
            delivered.withLock { $0.contains(firstID) && $0.contains(secondID) }
        }
    }

    func testStageThrowsForAnyDeclaredMissingPayload() throws {
        var dataManifest = self.makeManifest(itemID: Self.uuid(370))
        dataManifest.payloadParts.append(TransferPayloadPartDescriptor(
            partID: "location",
            kind: .location,
            relativePath: "location.jsonl",
            filename: "location.jsonl",
            contentType: "application/x-ndjson",
            requiredForDispatch: false
        ))
        let dataRoot = self.tempDirectory.appendingPathComponent("strict-stage-data", isDirectory: true)
        let dataSpool = TransferSpool(rootURL: dataRoot)
        XCTAssertThrowsError(try dataSpool.stage(manifest: dataManifest, payloads: self.audioPayloads())) { error in
            XCTAssertEqual(error as? TransferManifestError, .missingPayload("location"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataRoot
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
            .appendingPathComponent(dataManifest.itemID.uuidString, isDirectory: true)
            .path))

        var fileManifest = self.makeManifest(itemID: Self.uuid(371))
        fileManifest.payloadParts.append(TransferPayloadPartDescriptor(
            partID: "location",
            kind: .location,
            relativePath: "location.jsonl",
            filename: "location.jsonl",
            contentType: "application/x-ndjson",
            requiredForDispatch: false
        ))
        let fileRoot = self.tempDirectory.appendingPathComponent("strict-stage-file", isDirectory: true)
        let fileSpool = TransferSpool(rootURL: fileRoot)
        let audioURL = self.tempDirectory.appendingPathComponent("strict-stage-audio.m4a")
        try Data("audio".utf8).write(to: audioURL)
        XCTAssertThrowsError(try fileSpool.stage(manifest: fileManifest, payloadFileURLs: ["audio": audioURL])) { error in
            XCTAssertEqual(error as? TransferManifestError, .missingPayload("location"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileRoot
            .appendingPathComponent(TransferSpool.queuedDirectoryName, isDirectory: true)
            .appendingPathComponent(fileManifest.itemID.uuidString, isDirectory: true)
            .path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testCommittedItemPayloadPresenceValidationNamesMissingRequiredPayload() throws {
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("payload-validation", isDirectory: true))
        let committed = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(itemID: Self.uuid(372)),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        XCTAssertNil(spool.validatePayloads(for: committed))

        let audioPart = try XCTUnwrap(committed.manifest.payloadParts.first)
        try FileManager.default.removeItem(at: try spool.payloadURL(for: audioPart, in: committed.directoryURL))
        XCTAssertEqual(spool.validatePayloads(for: committed), "audio.m4a")
    }

    @MainActor
    func testLinkedDeviceIngestAndReconciliationNeverInvokeRegistrationOrSetAuthorization() async throws {
        TransferURLProtocol.handler = { request, _ in
            if request.httpMethod == "GET" {
                return (
                    Self.response(for: request, statusCode: 200),
                    Data(#"{"protocol_version":3,"total":0,"items":[]}"#.utf8)
                )
            }
            return (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        let loadKeyCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let registration = ObserverRegistration(
            resolveDescriptor: { nil },
            version: "test",
            streamType: "test",
            retryDelays: [],
            sleep: { _ in },
            loadKey: { loadKeyCalls.withLock { $0 += 1 }; return nil },
            saveKey: { _ in },
            deleteKey: {},
            loadPrefix: { nil },
            savePrefix: { _ in },
            deletePrefix: {}
        )
        registration.activeLocalPort = 7071
        loadKeyCalls.withLock { $0 = 0 }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        let transport = TransferTransport(sessionConfiguration: configuration)
        let engine = TransferEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("auth", isDirectory: true)),
            transport: transport,
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
        try await engine.start()
        _ = try await engine.enqueue(manifest: self.makeManifest(itemID: Self.uuid(380)), payloads: self.audioPayloads())

        try await self.waitFor("ingest request") {
            TransferURLProtocol.requests.count == 1
        }
        let readConfiguration = URLSessionConfiguration.ephemeral
        readConfiguration.protocolClasses = [TransferURLProtocol.self]
        let readClient = LinkedDeviceIngestClient(session: URLSession(configuration: readConfiguration))
        let readResult = await readClient.fetchSegments(
            localPort: 7071,
            source: ObserverAudioTransferSource.mobileSegment,
            day: "20260420"
        )
        XCTAssertEqual(readResult, .success(LinkedDeviceIngestSegmentsResponse(protocolVersion: 3, total: 0, items: [])))
        XCTAssertEqual(loadKeyCalls.withLock { $0 }, 0)
        XCTAssertTrue(TransferURLProtocol.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == nil
                && $0.value(forHTTPHeaderField: ObserverServerURL.protocolVersionHeaderName) == "3"
        })
    }

    func testKickCoalescesIdleDrainPassesAndPreservesRetryDeadline() async throws {
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let root = self.tempDirectory.appendingPathComponent("kick", isDirectory: true)
        let spool = TransferSpool(rootURL: root)
        _ = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(itemID: Self.uuid(390)),
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        let resolver = BlockedUnavailableResolver()
        let engine = self.makeEngine(spool: TransferSpool(rootURL: root), resolver: resolver)
        try await engine.start()
        try await self.waitFor("initial held pass") {
            await resolver.resolveCount > 0
        }
        await resolver.resetResolveCount()
        await resolver.setBlocked(true)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    await engine.kick()
                }
            }
            await group.waitForAll()
        }
        try await self.waitFor("blocked kick pass") {
            await resolver.resolveCount > 0
        }
        await resolver.setBlocked(false)
        try await Task.sleep(for: .milliseconds(200))

        let resolveCount = await resolver.resolveCount
        XCTAssertLessThanOrEqual(resolveCount, 2)
        // Engines outlive the test that made them, so `requests` is not exclusively ours.
        // Scope the no-dispatch assertion to this engine's only item.
        let dispatched = TransferURLProtocol.requests.compactMap(Self.boundaryItemID(from:))
        XCTAssertFalse(dispatched.contains(Self.uuid(390)))
    }

    func testByteCountPopulatedForDataAndFileURLAndBackfilledWithoutEnumeration() async throws {
        let dataSpool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("byte-data", isDirectory: true))
        let dataStaged = try dataSpool.stage(manifest: self.makeManifest(itemID: Self.uuid(400)), payloads: self.audioPayloads())
        XCTAssertEqual(dataStaged.item.manifest.payloadParts.first?.byteCount, Data("audio".utf8).count)

        let fileRoot = self.tempDirectory.appendingPathComponent("byte-file", isDirectory: true)
        let fileSpool = TransferSpool(rootURL: fileRoot)
        let sourceURL = self.tempDirectory.appendingPathComponent("byte-audio.m4a")
        try Data("legacy-audio".utf8).write(to: sourceURL)
        let fileStaged = try fileSpool.stage(
            manifest: self.makeManifest(itemID: Self.uuid(401)),
            payloadFileURLs: ["audio": sourceURL]
        )
        XCTAssertEqual(fileStaged.item.manifest.payloadParts.first?.byteCount, Data("legacy-audio".utf8).count)

        let fileSystem = CountingTransferFileSystem()
        let root = self.tempDirectory.appendingPathComponent("byte-legacy", isDirectory: true)
        let legacySpool = TransferSpool(rootURL: root, fileSystem: fileSystem)
        var legacyManifest = self.makeManifest(itemID: Self.uuid(402), source: "legacy")
        legacyManifest.payloadParts[0].byteCount = nil
        let committed = try legacySpool.commitStagedItem(itemID: legacySpool.stage(
            manifest: legacyManifest,
            payloads: self.audioPayloads()
        ).item.manifest.itemID)
        try legacySpool.writeManifestAtomically(legacyManifest.replacingDiskState(.queued), in: committed.directoryURL)

        let resolver = TransferEndpointResolverStub(.unavailable("held"))
        let engine = self.makeEngine(
            spool: TransferSpool(rootURL: root, fileSystem: fileSystem),
            resolver: resolver,
            bodyBuilder: { _, _ in .inMemory(Data("body".utf8)) }
        )
        TransferURLProtocol.handler = { request, _ in
            (Self.response(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
        }
        try await engine.start()
        try await self.waitFor("legacy held") {
            resolver.resolveCount > 0
        }
        fileSystem.resetEnumerationCount()
        resolver.setResolution(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        await engine.endpointAvailabilityChanged()
        try await self.waitFor("legacy delivered") {
            (await engine.snapshot()).counters.deliveredCount == 1
        }

        let snapshot = await engine.snapshot()
        XCTAssertEqual(fileSystem.enumerationCount, 0)
        XCTAssertEqual(snapshot.sources["legacy"]?.bytesPerSecond, Double(Data("audio".utf8).count) / 15.0)
    }

    func testProjectYmlAutoIncludesTransferSourcesAndTests() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL)

        XCTAssertTrue(project.contains("solstone-swift:\n    type: application\n    platform: iOS\n    sources:\n      - path: Sources"))
        XCTAssertFalse(project.contains("excludes:\n          - SPLTunnel"))
        XCTAssertTrue(project.contains("solstone-swiftTests:\n    type: bundle.unit-test\n    platform: iOS\n    sources:\n      - Tests"))
        XCTAssertFalse(project.contains("Sources/Transfer/"))
    }
}

private extension TransferTests {
    static let baseDate = Date(timeIntervalSince1970: 1_713_624_000)

    func bodyData(_ payload: TransferBodyPayload) throws -> Data {
        switch payload {
        case .inMemory(let data):
            return data
        case .written(let url, _):
            return try Data(contentsOf: url)
        }
    }

    func multipartEnvelope(_ body: Data, boundary: String) throws -> [String: Any] {
        let text = String(decoding: body, as: UTF8.self)
        let marker = "name=\"envelope\"\r\n\r\n"
        let start = try XCTUnwrap(text.range(of: marker)?.upperBound)
        let end = try XCTUnwrap(text[start...].range(of: "\r\n--\(boundary)")).lowerBound
        let data = Data(text[start..<end].utf8)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func makeEngine(
        spool: TransferSpool? = nil,
        clock: FakeTransferClock = FakeTransferClock(wall: TransferTests.baseDate),
        resolver: any TransferEndpointResolver = TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
        pacer: TransferPacer = TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
        diagnosticsSink: @escaping TransferDiagnosticSink = { _ in },
        statusMirror: TransferStatusMirror? = nil,
        conditions: (any TransferConditionsProviding)? = nil,
        dispatchPolicy: TransferDispatchPolicy = TransferDispatchPolicy(),
        maxConcurrent: Int = 3,
        bodyBuilder: @escaping TransferBodyBuilder = DefaultTransferBodyBuilder.build
    ) -> TransferEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        return TransferEngine(
            spool: spool ?? TransferSpool(rootURL: self.tempDirectory),
            transport: TransferTransport(sessionConfiguration: configuration),
            endpointResolver: resolver,
            pacer: pacer,
            clock: clock,
            diagnosticsSink: diagnosticsSink,
            statusMirror: statusMirror,
            conditions: conditions,
            dispatchPolicy: dispatchPolicy,
            maxConcurrent: maxConcurrent,
            bodyBuilder: bodyBuilder
        )
    }

    func makeManifest(
        itemID: UUID = UUID(),
        source: String = "alpha",
        createdAt: Date = TransferTests.baseDate,
        priority: TransferBasePriority = .normal,
        nextAttemptAt: Date? = nil
    ) -> TransferManifest {
        TransferManifest(
            itemID: itemID,
            source: source,
            createdAt: createdAt,
            priority: TransferPriorityInputs(basePriority: priority, sourceKey: source),
            payloadParts: [
                TransferPayloadPartDescriptor(
                    partID: "audio",
                    kind: .audio,
                    relativePath: "audio.m4a",
                    filename: "audio.m4a",
                    contentType: "audio/mp4"
                ),
            ],
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/devices/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                segment: "120000_3",
                day: "20260420",
                startedAt: createdAt,
                durationS: 3,
                sources: ["audio"],
                chunkIndex: 0,
                sessionID: itemID,
                modeRawValue: "meeting",
                segmentID: itemID,
                ingestProtocolVersion: 3
            ),
            meta: .object(["kind": .string("test")]),
            nextAttemptAt: nextAttemptAt
        )
    }

    func audioPayloads() -> [String: Data] {
        ["audio": Data("audio".utf8)]
    }

    func stagePredecessor(
        spool: TransferSpool,
        itemID: UUID,
        durableBytes: Data,
        cachedBytes: Data
    ) throws -> TransferStoredItem {
        var manifest = self.makeManifest(itemID: itemID)
        manifest.endpoint.path = "/app/observer/ingest"
        manifest.observerIngest?.ingestProtocolVersion = nil
        let staged = try spool.stage(manifest: manifest, payloads: ["audio": durableBytes])
        try spool.writeBodyCache(cachedBytes, for: staged.item)
        return staged.item
    }

    func waitFor(
        _ label: String,
        timeout: Duration = .seconds(2),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }

    static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func boundaryItemID(from request: URLRequest) -> UUID? {
        guard let contentType = request.value(forHTTPHeaderField: "Content-Type"),
              let boundaryRange = contentType.range(of: "boundary=Boundary-")
        else {
            return nil
        }
        return UUID(uuidString: String(contentType[boundaryRange.upperBound...]))
    }

    func pathExists(containing needle: String, under root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator where url.path.contains(needle) {
            return true
        }
        return false
    }
}

private enum TransferTransientStep: Sendable {
    case status(Int)
    case urlIssue(URLError.Code)
}

private struct TransferPolicyDispatch: Equatable, Sendable {
    var itemID: UUID
    var phase: String
}

private struct TransferPolicyDispatchState: Sendable {
    var dispatches: [TransferPolicyDispatch] = []
}

private final class MutableTransferConditionsProvider: TransferConditionsProviding, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<TransferDispatchConditions>

    init(
        thermalState: ProcessInfo.ThermalState = .nominal,
        lowPowerModeEnabled: Bool = false,
        isExpensive: Bool = false,
        isConstrained: Bool = false
    ) {
        self.state = OSAllocatedUnfairLock(initialState: TransferDispatchConditions(
            thermalState: thermalState,
            lowPowerModeEnabled: lowPowerModeEnabled,
            isExpensive: isExpensive,
            isConstrained: isConstrained
        ))
    }

    func current() -> TransferDispatchConditions {
        self.state.withLock { $0 }
    }

    func update(
        thermalState: ProcessInfo.ThermalState? = nil,
        lowPowerModeEnabled: Bool? = nil,
        isExpensive: Bool? = nil,
        isConstrained: Bool? = nil
    ) {
        self.state.withLock { conditions in
            if let thermalState {
                conditions.thermalState = thermalState
            }
            if let lowPowerModeEnabled {
                conditions.lowPowerModeEnabled = lowPowerModeEnabled
            }
            if let isExpensive {
                conditions.isExpensive = isExpensive
            }
            if let isConstrained {
                conditions.isConstrained = isConstrained
            }
        }
    }
}

private enum DeliveredHookTestError: Error, Sendable {
    case failed
}

private actor HookGate {
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool {
        self.continuation != nil
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

final class FakeTransferClock: TransferClock, @unchecked Sendable {
    private struct State {
        var wall: Date
        var sleepCallCount = 0
        var sleepDurations: [TimeInterval] = []
        var sleepers: [CheckedContinuation<Void, Never>] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let baseInstant = ContinuousClock.now

    init(wall: Date) {
        self.state = OSAllocatedUnfairLock(initialState: State(wall: wall))
    }

    var sleepCallCount: Int {
        self.state.withLock { $0.sleepCallCount }
    }

    var sleepDurations: [TimeInterval] {
        self.state.withLock { $0.sleepDurations }
    }

    func wallNow() -> Date {
        self.state.withLock { $0.wall }
    }

    func monotonicNow() -> ContinuousClock.Instant {
        self.baseInstant
    }

    func sleep(for duration: Duration) async {
        await withCheckedContinuation { continuation in
            self.state.withLock { state in
                state.sleepCallCount += 1
                state.sleepDurations.append(Self.seconds(from: duration))
                state.sleepers.append(continuation)
            }
        }
    }

    func advanceWall(by interval: TimeInterval) {
        self.state.withLock { $0.wall = $0.wall.addingTimeInterval(interval) }
    }

    func resumeSleeps() {
        let sleepers = self.state.withLock { state in
            let sleepers = state.sleepers
            state.sleepers = []
            return sleepers
        }
        for sleeper in sleepers {
            sleeper.resume()
        }
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000)
    }
}

final class TransferEndpointResolverStub: TransferEndpointResolver, @unchecked Sendable {
    private struct State {
        var resolution: TransferEndpointResolution
        var descriptors: [TransferEndpointDescriptor] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ resolution: TransferEndpointResolution) {
        self.state = OSAllocatedUnfairLock(initialState: State(resolution: resolution))
    }

    var resolveCount: Int {
        self.state.withLock { $0.descriptors.count }
    }

    func resetResolveCount() {
        self.state.withLock { $0.descriptors = [] }
    }

    func setResolution(_ resolution: TransferEndpointResolution) {
        self.state.withLock { $0.resolution = resolution }
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        self.state.withLock { state in
            state.descriptors.append(descriptor)
            return state.resolution
        }
    }
}

struct PathEndpointResolver: TransferEndpointResolver {
    let availablePaths: Set<String>

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        if self.availablePaths.contains(descriptor.path) {
            return .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
        }
        return .unavailable("held")
    }
}

private actor FirstResolveSuspendingResolver: TransferEndpointResolver {
    private var parked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilParked() async {
        while !self.parked {
            await Task.yield()
        }
    }

    func resumeAvailable() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        guard !self.parked else {
            return .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
        }
        self.parked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
    }
}

private actor SecondResolveSuspendingResolver: TransferEndpointResolver {
    private var resolveCount = 0
    private var parked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilParked() async {
        while !self.parked {
            await Task.yield()
        }
    }

    func resumeUnavailable() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        self.resolveCount += 1
        guard self.resolveCount > 1 else {
            return .available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))
        }
        self.parked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return .unavailable("held")
    }
}

private actor BlockedUnavailableResolver: TransferEndpointResolver {
    private var count = 0
    private var blocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var resolveCount: Int {
        self.count
    }

    func resetResolveCount() {
        self.count = 0
    }

    func setBlocked(_ blocked: Bool) {
        self.blocked = blocked
        guard !blocked else { return }
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func resolve(_ descriptor: TransferEndpointDescriptor) async -> TransferEndpointResolution {
        self.count += 1
        if self.blocked {
            await withCheckedContinuation { continuation in
                self.waiters.append(continuation)
            }
        }
        return .unavailable("held")
    }
}

private final class CountingTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let enumerationCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private let dataReadURLsBox = OSAllocatedUnfairLock<[URL]>(initialState: [])

    var enumerationCount: Int {
        self.enumerationCountBox.withLock { $0 }
    }

    var dataReadURLs: [URL] {
        self.dataReadURLsBox.withLock { $0 }
    }

    func resetEnumerationCount() {
        self.enumerationCountBox.withLock { $0 = 0 }
    }

    func resetDataReadURLs() {
        self.dataReadURLsBox.withLock { $0 = [] }
    }

    func fileExists(atPath path: String) -> Bool {
        self.fileManager.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        self.enumerationCountBox.withLock { $0 += 1 }
        return try self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    func removeItem(at url: URL) throws {
        try self.fileManager.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        _ = try self.fileManager.replaceItemAt(originalURL, withItemAt: newURL)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }

    func data(contentsOf url: URL) throws -> Data {
        self.dataReadURLsBox.withLock { $0.append(url) }
        return try Data(contentsOf: url)
    }

    func byteCount(at url: URL) throws -> Int {
        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.intValue
    }

    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return }
            try consume(data)
        }
    }

    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try FoundationTransferFileSystem().writeStream(to: url, body)
    }
}

final class FailingManifestWriteFileSystem: TransferFileSystem, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let failBox = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let failingItemIDBox = OSAllocatedUnfairLock<UUID?>(initialState: nil)

    var failManifestWrites: Bool {
        get { self.failBox.withLock { $0 } }
        set { self.failBox.withLock { $0 = newValue } }
    }

    var failingManifestItemID: UUID? {
        get { self.failingItemIDBox.withLock { $0 } }
        set { self.failingItemIDBox.withLock { $0 = newValue } }
    }

    func fileExists(atPath path: String) -> Bool {
        self.fileManager.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    func removeItem(at url: URL) throws {
        try self.fileManager.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        _ = try self.fileManager.replaceItemAt(originalURL, withItemAt: newURL)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        let failingItemID = self.failingManifestItemID
        let shouldFail = self.failBox.withLock { failManifestWrites in
            guard failManifestWrites, url.lastPathComponent.hasPrefix(".manifest-") else {
                return false
            }
            if let failingItemID,
               url.deletingLastPathComponent().lastPathComponent != failingItemID.uuidString
            {
                return false
            }
            failManifestWrites = false
            return true
        }
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: options)
    }

    func data(contentsOf url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func byteCount(at url: URL) throws -> Int {
        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.intValue
    }

    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return }
            try consume(data)
        }
    }

    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try FoundationTransferFileSystem().writeStream(to: url, body)
    }
}

private struct ForcedMoveFailure: Error, CustomStringConvertible, Sendable {
    var description: String {
        "forced move failure"
    }
}

private final class FailingMoveTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let failingPartFilename: String

    init(failingPartFilename: String) {
        self.failingPartFilename = failingPartFilename
    }

    func fileExists(atPath path: String) -> Bool {
        self.fileManager.fileExists(atPath: path)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try self.fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try self.fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    func removeItem(at url: URL) throws {
        try self.fileManager.removeItem(at: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if destinationURL.lastPathComponent == self.failingPartFilename {
            throw ForcedMoveFailure()
        }
        try self.fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func replaceItem(at originalURL: URL, withItemAt newURL: URL) throws {
        _ = try self.fileManager.replaceItemAt(originalURL, withItemAt: newURL)
    }

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        try data.write(to: url, options: options)
    }

    func data(contentsOf url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func byteCount(at url: URL) throws -> Int {
        let attributes = try self.fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CocoaError(.fileReadUnknown)
        }
        return size.intValue
    }

    func readChunks(at url: URL, chunkSize: Int, _ consume: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while true {
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { return }
            try consume(data)
        }
    }

    func writeStream(to url: URL, _ body: (any TransferByteSink) throws -> Void) throws -> Int {
        try FoundationTransferFileSystem().writeStream(to: url, body)
    }
}

final class TransferURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)?

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let requestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])
    private static let heldBox = OSAllocatedUnfairLock<[TransferURLProtocol]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var requests: [URLRequest] {
        self.requestsBox.withLock { $0 }
    }

    static var bodies: [Data] {
        self.bodiesBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.requestsBox.withLock { $0 = [] }
        self.bodiesBox.withLock { $0 = [] }
        self.heldBox.withLock { $0 = [] }
    }

    static func hold(_ request: URLRequest) -> (HTTPURLResponse, Data)? {
        nil
    }

    static func completeHeld(
        _ count: Int = 1,
        statusCode: Int = 200,
        data: Data = Data(#"{"status":"ok"}"#.utf8)
    ) {
        let held = self.heldBox.withLock { protocols -> [TransferURLProtocol] in
            let completeCount = min(count, protocols.count)
            let completed = Array(protocols.prefix(completeCount))
            protocols.removeFirst(completeCount)
            return completed
        }
        for urlProtocol in held {
            urlProtocol.complete(statusCode: statusCode, data: data)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestsBox.withLock { $0.append(self.request) }
        let body = Self.bodyData(from: self.request)
        Self.bodiesBox.withLock { $0.append(body) }

        guard let handler = Self.handler else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        do {
            guard let (response, data) = try handler(self.request, body) else {
                Self.heldBox.withLock { $0.append(self) }
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func complete(statusCode: Int, data: Data) {
        guard let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        ) else {
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    private static func bodyData(from request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
