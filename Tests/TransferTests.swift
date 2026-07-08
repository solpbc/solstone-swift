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
        ).manifest.itemID)
        _ = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(source: "beta"),
                payloads: self.audioPayloads()
            ).manifest.itemID),
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
                TransferHTTPResult(statusCode: 200, data: Data(#"{"status":"already_delivered"}"#.utf8)),
                .observerIngest,
                .terminalSuccess(.alreadyDelivered)
            ),
            (
                TransferHTTPResult(statusCode: 204),
                .observerIngest,
                .terminalSuccess(.delivered(serverPath: nil, serverTimestamp: nil))
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

    func testAtomicEnqueueCrashBeforeCommitLeavesOnlyDiscardableStaging() throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        _ = try spool.stage(manifest: self.makeManifest(), payloads: self.audioPayloads())

        let snapshot = try TransferSpool(rootURL: self.tempDirectory).initialize(now: Self.baseDate)

        XCTAssertEqual(snapshot.queued.count, 0)
        XCTAssertEqual(snapshot.attention.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.tempDirectory.appendingPathComponent(TransferSpool.stagingDirectoryName).appendingPathComponent("unused").path))

        let committed = try spool.commitStagedItem(itemID: spool.stage(
            manifest: self.makeManifest(),
            payloads: self.audioPayloads()
        ).manifest.itemID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: committed.directoryURL.path))
    }

    func testMissingRequiredPayloadMovesQueuedItemToAttention() throws {
        let spool = TransferSpool(rootURL: self.tempDirectory)
        let staged = try spool.stage(manifest: self.makeManifest(), payloads: [:])
        _ = try spool.commitStagedItem(itemID: staged.manifest.itemID)

        let snapshot = try spool.initialize(now: Self.baseDate)

        XCTAssertEqual(snapshot.queued.count, 0)
        XCTAssertEqual(snapshot.attention.count, 1)
        XCTAssertEqual(snapshot.attention.first?.manifest.attention?.reason, "missing_payload")
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

    func testDropInFlightAndAlreadyGoneAreNoOps() async throws {
        let gate = DispatchSemaphore(value: 0)
        TransferURLProtocol.handler = { request, _ in
            _ = gate.wait(timeout: .now() + .seconds(5))
            return (Self.response(for: request, statusCode: 200), Data())
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

    func testBodyUploadBuiltOnceReusedAcrossRetriesAndRemovedAfterDelivery() async throws {
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let statusCodes = OSAllocatedUnfairLock<[Int]>(initialState: [500, 500, 200])
        TransferURLProtocol.handler = { request, _ in
            let status = statusCodes.withLock { values in values.removeFirst() }
            return (Self.response(for: request, statusCode: status), Data())
        }
        let pacer = TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300, jitterSalt: 1))
        let engine = self.makeEngine(pacer: pacer, bodyBuilder: { _, _ in
            callCount.withLock { $0 += 1 }
            return Data("body-once".utf8)
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
    func testObserverIngestMultipartBuilderMatchesExistingObserverUploaderBytes() throws {
        let audioURL = self.tempDirectory.appendingPathComponent("audio.m4a")
        let screenURL = self.tempDirectory.appendingPathComponent("screen.mp4")
        try Data("audio-bytes".utf8).write(to: audioURL)
        try Data("screen-bytes".utf8).write(to: screenURL)
        let location = Data("{\"event\":\"loc\"}\n".utf8)
        let segmentID = Self.uuid(9)
        let metadata = ObserverIngestMultipartMetadata(
            segment: "120000_3",
            day: "20260420",
            startedAt: Self.baseDate,
            durationS: 3,
            chunkIndex: 7,
            sessionID: Self.uuid(8),
            mode: .meeting,
            segmentID: segmentID,
            sources: ["audio", "location", "screen"]
        )
        let boundary = "Boundary-\(segmentID.uuidString)"

        let uploader = ObserverUploader(cacheRootURL: self.tempDirectory)
        let request = try uploader.buildMobileSegmentRequestBody(
            segmentID: segmentID,
            metadata: metadata,
            audioURL: audioURL,
            locationJSONL: location,
            screenURL: screenURL
        )
        let wrapperBody = try Data(contentsOf: request.requestBodyURL)
        let sharedBody = try ObserverIngestMultipartBody.build(input: ObserverIngestMultipartInput(
            boundary: boundary,
            platform: "ios",
            segment: metadata.segment,
            day: metadata.day,
            startedAt: metadata.startedAt,
            durationS: metadata.durationS,
            sources: metadata.sources,
            chunkIndex: metadata.chunkIndex,
            sessionID: metadata.sessionID,
            modeRawValue: metadata.mode?.rawValue,
            segmentID: metadata.segmentID,
            artifacts: ObserverIngestMultipartArtifacts(
                audioData: try Data(contentsOf: audioURL),
                locationJSONL: location,
                screenData: try Data(contentsOf: screenURL)
            )
        ))

        XCTAssertEqual(wrapperBody, sharedBody)
        let body = String(decoding: sharedBody, as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(body.range(of: #"name="segment""#)?.lowerBound), try XCTUnwrap(body.range(of: #"name="day""#)?.lowerBound))
        XCTAssertTrue(body.contains(#"name="files"; filename="audio.m4a""#))
        XCTAssertTrue(body.contains("Content-Type: application/x-ndjson"))
        XCTAssertTrue(body.contains(#""chunk_index":7"#))
    }

    func testCrashTimingHonestyForBodyAndPhaseRecovery() async throws {
        let spool = TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("a", isDirectory: true))
        _ = try spool.stage(manifest: self.makeManifest(itemID: Self.uuid(31)), payloads: self.audioPayloads())
        XCTAssertEqual(try spool.initialize(now: Self.baseDate).queued.count, 0)

        let buildCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let engine = self.makeEngine(
            spool: TransferSpool(rootURL: self.tempDirectory.appendingPathComponent("b", isDirectory: true)),
            pacer: TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
            bodyBuilder: { _, _ in
                buildCount.withLock { $0 += 1 }
                return Data("body".utf8)
            }
        )
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data()) }
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
        TransferURLProtocol.handler = { request, _ in (Self.response(for: request, statusCode: 200), Data()) }
        let engine = self.makeEngine(spool: spool, bodyBuilder: { _, _ in Data("body".utf8) })
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
            bodyBuilder: { _, _ in Data("body".utf8) }
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
            bodyBuilder: { _, _ in Data("body".utf8) }
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
            ).manifest.itemID),
            reason: "needs_attention",
            detail: "held",
            now: Self.baseDate
        )
        _ = alpha
        _ = try spool.moveQueuedItemToAttention(
            try spool.commitStagedItem(itemID: spool.stage(
                manifest: self.makeManifest(itemID: Self.uuid(42), source: "beta"),
                payloads: self.audioPayloads()
            ).manifest.itemID),
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

    func testFreshBandBoundaryAtFifteenMinutes() async throws {
        TransferURLProtocol.handler = { request, _ in TransferURLProtocol.hold(request) }
        let clock = FakeTransferClock(wall: Self.baseDate)
        let buildOrder = OSAllocatedUnfairLock<[UUID]>(initialState: [])
        let engine = self.makeEngine(
            clock: clock,
            maxConcurrent: 3,
            bodyBuilder: { item, _ in
                buildOrder.withLock { $0.append(item.manifest.itemID) }
                return Data("body".utf8)
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
        let engine = self.makeEngine(clock: clock, maxConcurrent: 1, bodyBuilder: { _, _ in Data("body".utf8) })
        try await engine.start()

        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(61), nextAttemptAt: Self.baseDate.addingTimeInterval(60)),
            payloads: self.audioPayloads()
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(TransferURLProtocol.requests.count, 0)

        _ = try await engine.enqueue(
            manifest: self.makeManifest(itemID: Self.uuid(62), nextAttemptAt: Self.baseDate.addingTimeInterval(600)),
            payloads: self.audioPayloads()
        )
        try await self.waitFor("clamped request") {
            TransferURLProtocol.requests.count == 1
        }
    }

    func testProjectYmlAutoIncludesTransferSourcesAndTests() throws {
        let projectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
        let project = try String(contentsOf: projectURL)

        XCTAssertTrue(project.contains("- path: Sources\n        excludes:\n          - SPLTunnel"))
        XCTAssertTrue(project.contains("solstone-swiftTests:\n    type: bundle.unit-test\n    platform: iOS\n    sources:\n      - Tests"))
        XCTAssertFalse(project.contains("Sources/Transfer/"))
    }
}

private extension TransferTests {
    static let baseDate = Date(timeIntervalSince1970: 1_713_624_000)

    func makeEngine(
        spool: TransferSpool? = nil,
        clock: FakeTransferClock = FakeTransferClock(wall: TransferTests.baseDate),
        resolver: TransferEndpointResolverStub = TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
        pacer: TransferPacer = TransferPacer(defaults: TransferPacerDefaults(ladderSeconds: [0], maxDelay: 300)),
        statusMirror: TransferStatusMirror? = nil,
        maxConcurrent: Int = 3,
        bodyBuilder: @escaping TransferBodyBuilder = DefaultTransferBodyBuilder.build
    ) -> TransferEngine {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferURLProtocol.self]
        return TransferEngine(
            spool: spool ?? TransferSpool(rootURL: self.tempDirectory),
            transport: TransferTransport(sessionConfiguration: configuration, authProvider: { "test-transfer-key" }),
            endpointResolver: resolver,
            pacer: pacer,
            clock: clock,
            diagnosticsSink: { _ in },
            statusMirror: statusMirror,
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
            endpoint: TransferEndpointDescriptor(destinationKind: .observerIngest, path: "/app/observer/ingest"),
            observerIngest: TransferObserverIngestMetadata(
                segment: "120000_3",
                day: "20260420",
                startedAt: createdAt,
                durationS: 3,
                sources: ["audio"],
                chunkIndex: 0,
                sessionID: itemID,
                modeRawValue: "meeting",
                segmentID: itemID
            ),
            meta: .object(["kind": .string("test")]),
            nextAttemptAt: nextAttemptAt
        )
    }

    func audioPayloads() -> [String: Data] {
        ["audio": Data("audio".utf8)]
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
}

private final class FakeTransferClock: TransferClock, @unchecked Sendable {
    private struct State {
        var wall: Date
        var sleepCallCount = 0
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
}

private final class TransferEndpointResolverStub: TransferEndpointResolver, @unchecked Sendable {
    private struct State {
        var resolution: TransferEndpointResolution
        var descriptors: [TransferEndpointDescriptor] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ resolution: TransferEndpointResolution) {
        self.state = OSAllocatedUnfairLock(initialState: State(resolution: resolution))
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

private final class CountingTransferFileSystem: TransferFileSystem, @unchecked Sendable {
    private let fileManager = FileManager.default
    private let enumerationCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)

    var enumerationCount: Int {
        self.enumerationCountBox.withLock { $0 }
    }

    func resetEnumerationCount() {
        self.enumerationCountBox.withLock { $0 = 0 }
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
        try Data(contentsOf: url)
    }
}

private final class TransferURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) throws -> (HTTPURLResponse, Data)?

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let requestsBox = OSAllocatedUnfairLock<[URLRequest]>(initialState: [])
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])

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
    }

    static func hold(_ request: URLRequest) -> (HTTPURLResponse, Data)? {
        nil
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
