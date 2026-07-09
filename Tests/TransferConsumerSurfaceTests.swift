// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class TransferConsumerSurfaceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TransferConsumerSurfaceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        TransferURLProtocol.reset()
        TransferConsumerHealthURLProtocol.reset()
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        TransferConsumerHealthURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testAC8RealEngineStateFeedsAllOmiAndWatchConsumerSurfaces() async throws {
        let clock = FakeTransferClock(wall: Date(timeIntervalSince1970: 1_780_480_800))
        let responses = OSAllocatedUnfairLock<[UUID: RoutedTransferResponse]>(initialState: [:])
        TransferURLProtocol.handler = { request, _ in
            guard let itemID = transferTestBoundaryItemID(from: request) else {
                return (transferTestResponse(for: request, statusCode: 204), Data())
            }
            switch responses.withLock({ $0[itemID] ?? .hold }) {
            case .status(let statusCode, let body):
                return (transferTestResponse(for: request, statusCode: statusCode), body)
            case .hold:
                return nil
            }
        }

        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            clock: clock,
            maxConcurrent: 1
        )
        try await harness.engine.start()
        let zeroSurfaces = self.makeZeroUploadSurfaces()
        let deliveredID = Self.uuid(1)
        let omiQueuedIDs = [Self.uuid(10), Self.uuid(11), Self.uuid(12)]
        let watchAttentionIDs = [Self.uuid(20), Self.uuid(21)]
        responses.withLock { $0[deliveredID] = .status(204, Data()) }
        _ = try await harness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: deliveredID,
                sidecar: makeTransferTestSidecar(
                    sessionID: UUID(),
                    chunkIndex: 0,
                    startedAt: clock.wallNow()
                )
            ),
            payloads: ["audio": Data("delivered".utf8)]
        )
        try await transferTestWaitFor("initial delivery") {
            await harness.engine.snapshot().counters.deliveredCount == 1
        }

        responses.withLock {
            $0[watchAttentionIDs[0]] = .status(404, Data("watch-A".utf8))
            $0[watchAttentionIDs[1]] = .status(404, Data("watch-B".utf8))
        }
        for (offset, itemID) in watchAttentionIDs.enumerated() {
            _ = try await harness.engine.enqueue(
                manifest: ObserverAudioTransferEnqueuer.makeWatchManifest(
                    itemID: itemID,
                    sidecar: makeTransferTestSidecar(
                        sessionID: UUID(),
                        chunkIndex: offset,
                        startedAt: clock.wallNow().addingTimeInterval(TimeInterval(offset + 1))
                    ),
                    hasLocation: false
                ),
                payloads: ["audio": Data("watch-\(offset)".utf8)]
            )
        }
        try await transferTestWaitFor("watch attention") {
            await harness.engine.snapshot().sources[ObserverAudioTransferSource.watch]?.attentionCount == 2
        }

        await harness.engine.pause()
        let omiSessionID = UUID()
        for (offset, itemID) in omiQueuedIDs.enumerated() {
            _ = try await harness.engine.enqueue(
                manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                    itemID: itemID,
                    sidecar: makeTransferTestSidecar(
                        sessionID: omiSessionID,
                        chunkIndex: offset + 10,
                        startedAt: clock.wallNow().addingTimeInterval(TimeInterval(offset + 10))
                    )
                ),
                payloads: ["audio": Data("omi-\(offset)".utf8)]
            )
        }
        await harness.engine.resume()
        try await transferTestWaitFor("one omi item in flight") {
            await harness.engine.snapshot().sources[ObserverAudioTransferSource.omi]?.inFlightCount == 1
        }
        try await transferTestWaitFor("mirror has seeded transfer state", timeout: .seconds(3)) {
            await MainActor.run {
                harness.omi.pendingCount == 3 &&
                    harness.omi.inFlightCount == 1 &&
                    harness.watch.failedCount == 2 &&
                    harness.watch.lastError == "watch-B"
            }
        }

        XCTAssertEqual(harness.omi.pendingCount, 3)
        XCTAssertEqual(harness.omi.confirmedActiveTransferCount, 1)
        XCTAssertEqual(harness.watch.failedCount, 2)
        XCTAssertEqual(harness.watch.recentErrorCount, 2)
        XCTAssertEqual(harness.watch.lastError, "watch-B")

        let omiBeaconPayload = try await self.emitHealthPayload(
            queueHealth: harness.omi,
            streamType: "omi",
            prefix: "obs_omi_"
        )
        XCTAssertEqual(omiBeaconPayload["pending_queue_depth"] as? Int, 3)
        XCTAssertEqual(omiBeaconPayload["last_successful_sync"] as? String, ISO8601DateFormatter().string(from: clock.wallNow()))
        let watchBeaconPayload = try await self.emitHealthPayload(
            queueHealth: harness.watch,
            streamType: "watch",
            prefix: "obs_watch_"
        )
        XCTAssertEqual(watchBeaconPayload["recent_error_count"] as? Int, 2)
        XCTAssertEqual(watchBeaconPayload["last_error_reason"] as? String, "watch-B")

        var aggregate = await OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: zeroSurfaces.importQueue,
            mobileSegmentUploader: zeroSurfaces.mobileSegmentUploader,
            transferEngine: harness.engine
        )
        XCTAssertTrue(omiQueuedIDs.allSatisfy { itemID in
            aggregate.items.contains { $0.id == OnThisPhoneItemID.transferIDString(itemID: itemID, source: .omi) }
        })
        XCTAssertTrue(watchAttentionIDs.allSatisfy { itemID in
            aggregate.items.contains { $0.id == OnThisPhoneItemID.transferIDString(itemID: itemID, source: .watch) }
        })
        XCTAssertEqual(aggregate.items.filter { $0.sendState == .sending }.count, 1)
        XCTAssertEqual(aggregate.items.filter { $0.sendState == .needsAttention }.count, 2)

        var totals = uploadTotals(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: zeroSurfaces.importQueue
        )
        XCTAssertEqual(totals.pending, 3)
        XCTAssertEqual(totals.failed, 2)
        XCTAssertEqual(uploadInFlight(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: zeroSurfaces.importQueue
        ), 1)
        XCTAssertEqual(lastSyncedAt(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: zeroSurfaces.importQueue
        ), clock.wallNow())

        let syncModel = ConnectionSyncModel(clock: MockObserverClock()) {
            let totals = uploadTotals(
                mobileSegment: zeroSurfaces.mobileSegmentHolder,
                omi: harness.omi,
                watch: harness.watch,
                importQueue: zeroSurfaces.importQueue
            )
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 7071, via: .lan),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: confirmedTransferCount(
                    mobileSegment: zeroSurfaces.mobileSegmentHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    importQueue: zeroSurfaces.importQueue
                ),
                recentBytesPerSecond: recentBytesTotal(
                    mobileSegment: zeroSurfaces.mobileSegmentHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    importQueue: zeroSurfaces.importQueue
                ),
                backlogPending: totals.pending,
                backlogFailed: totals.failed
            )
        }
        XCTAssertEqual(syncModel.status, .connectedTransferring)

        await harness.engine.drop(itemID: omiQueuedIDs[1])
        try await transferTestWaitFor("dropped item leaves surfaces") {
            await MainActor.run { harness.omi.pendingCount == 2 }
        }
        aggregate = await OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: zeroSurfaces.importQueue,
            mobileSegmentUploader: zeroSurfaces.mobileSegmentUploader,
            transferEngine: harness.engine
        )
        XCTAssertFalse(aggregate.items.contains {
            $0.id == OnThisPhoneItemID.transferIDString(itemID: omiQueuedIDs[1], source: .omi)
        })
        totals = uploadTotals(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: zeroSurfaces.importQueue
        )
        XCTAssertEqual(totals.pending, 2)
        let droppedOmiPayload = try await self.emitHealthPayload(
            queueHealth: harness.omi,
            streamType: "omi",
            prefix: "obs_omi_"
        )
        XCTAssertEqual(droppedOmiPayload["pending_queue_depth"] as? Int, 2)

        try await harness.engine.retryAttention(itemID: watchAttentionIDs[0])
        try await transferTestWaitFor("single watch item retried") {
            await MainActor.run {
                harness.watch.pendingCount == 1 && harness.watch.failedCount == 1
            }
        }
        aggregate = await OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: zeroSurfaces.importQueue,
            mobileSegmentUploader: zeroSurfaces.mobileSegmentUploader,
            transferEngine: harness.engine
        )
        let retried = try XCTUnwrap(aggregate.items.first {
            $0.id == OnThisPhoneItemID.transferIDString(itemID: watchAttentionIDs[0], source: .watch)
        })
        let stillAttention = try XCTUnwrap(aggregate.items.first {
            $0.id == OnThisPhoneItemID.transferIDString(itemID: watchAttentionIDs[1], source: .watch)
        })
        XCTAssertEqual(retried.sendState, .savedOnThisPhone)
        XCTAssertNil(retried.failureReason)
        XCTAssertEqual(stillAttention.sendState, .needsAttention)
        XCTAssertEqual(stillAttention.failureReason, "http_client_error: watch-B")
    }

    func testAC8RealMobileEngineStateFeedsConsumerSurfaces() async throws {
        let clock = FakeTransferClock(wall: Date(timeIntervalSince1970: 1_780_480_800))
        let responses = OSAllocatedUnfairLock<[UUID: RoutedTransferResponse]>(initialState: [:])
        TransferURLProtocol.handler = { request, _ in
            guard let itemID = transferTestBoundaryItemID(from: request) else {
                return (transferTestResponse(for: request, statusCode: 204), Data())
            }
            switch responses.withLock({ $0[itemID] ?? .hold }) {
            case .status(let statusCode, let body):
                return (transferTestResponse(for: request, statusCode: statusCode), body)
            case .hold:
                return nil
            }
        }

        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("mobile-transfer", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            clock: clock,
            maxConcurrent: 1
        )
        try await harness.engine.start()
        let mobileUploader = MobileSegmentUploader(
            transferEngine: harness.engine,
            store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("mobile-store", isDirectory: true)),
            clock: MockObserverClock()
        )
        let mobileHolder = MobileSegmentTransferHolder(
            transferEngine: harness.engine,
            mirror: harness.mirror,
            uploader: mobileUploader
        )
        let importQueue = ImportQueue(
            cacheRootURL: self.tempDirectory.appendingPathComponent("mobile-import-zero", isDirectory: true),
            sessionConfiguration: .ephemeral,
            mode: .enqueueOnly,
            startPathMonitor: false
        )

        let deliveredID = Self.uuid(100)
        responses.withLock { $0[deliveredID] = .status(204, Data()) }
        _ = try await harness.engine.enqueue(
            manifest: Self.mobileManifest(itemID: deliveredID, segmentID: Self.uuid(1), startedAt: clock.wallNow()),
            payloads: ["audio": Data("delivered-mobile".utf8)]
        )
        try await transferTestWaitFor("mobile delivery") {
            await harness.engine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount == 1
        }

        let attentionID = Self.uuid(101)
        responses.withLock { $0[attentionID] = .status(404, Data("mobile-A".utf8)) }
        _ = try await harness.engine.enqueue(
            manifest: Self.mobileManifest(itemID: attentionID, segmentID: Self.uuid(2), startedAt: clock.wallNow().addingTimeInterval(1)),
            payloads: ["audio": Data("attention-mobile".utf8)]
        )
        try await transferTestWaitFor("mobile attention") {
            await harness.engine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.attentionCount == 1
        }

        await harness.engine.pause()
        let queuedID = Self.uuid(102)
        _ = try await harness.engine.enqueue(
            manifest: Self.mobileManifest(itemID: queuedID, segmentID: Self.uuid(3), startedAt: clock.wallNow().addingTimeInterval(2)),
            payloads: ["audio": Data("queued-mobile".utf8)]
        )
        await harness.engine.resume()
        try await transferTestWaitFor("mobile holder observes in-flight state") {
            await MainActor.run {
                mobileHolder.pendingCount == 1 &&
                    mobileHolder.inFlightCount == 1 &&
                    mobileHolder.failedCount == 1 &&
                    mobileHolder.lastError == "mobile-A"
            }
        }

        XCTAssertEqual(mobileHolder.recentErrorCount, 1)
        XCTAssertEqual(mobileHolder.lastUploadAt, clock.wallNow())
        let totals = uploadTotals(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: importQueue
        )
        XCTAssertEqual(totals.pending, 1)
        XCTAssertEqual(totals.failed, 1)
        XCTAssertEqual(uploadFailedTotal(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: importQueue
        ), 1)
        XCTAssertEqual(uploadInFlight(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: importQueue
        ), 1)
        XCTAssertEqual(lastSyncedAt(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: importQueue
        ), clock.wallNow())
        XCTAssertEqual(confirmedTransferCount(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: importQueue
        ), 1)
        XCTAssertGreaterThan(recentBytesTotal(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: importQueue
        ), 0)

        let mobileBeaconPayload = try await self.emitHealthPayload(
            queueHealth: mobileHolder,
            streamType: "observer",
            prefix: "obs_mobile_"
        )
        XCTAssertEqual(mobileBeaconPayload["pending_queue_depth"] as? Int, 1)
        XCTAssertEqual(mobileBeaconPayload["recent_error_count"] as? Int, 1)
        XCTAssertEqual(mobileBeaconPayload["last_error_reason"] as? String, "mobile-A")
        XCTAssertEqual(mobileBeaconPayload["last_successful_sync"] as? String, ISO8601DateFormatter().string(from: clock.wallNow()))

        let syncModel = ConnectionSyncModel(clock: MockObserverClock()) {
            let totals = uploadTotals(
                mobileSegment: mobileHolder,
                omi: harness.omi,
                watch: harness.watch,
                importQueue: importQueue
            )
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 7071, via: .lan),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: confirmedTransferCount(
                    mobileSegment: mobileHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    importQueue: importQueue
                ),
                recentBytesPerSecond: recentBytesTotal(
                    mobileSegment: mobileHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    importQueue: importQueue
                ),
                backlogPending: totals.pending,
                backlogFailed: totals.failed
            )
        }
        XCTAssertEqual(syncModel.status, .connectedTransferring)
    }
}

private enum RoutedTransferResponse: Sendable {
    case status(Int, Data)
    case hold
}

private extension TransferConsumerSurfaceTests {
    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    static func mobileManifest(itemID: UUID, segmentID: UUID, startedAt: Date) -> TransferManifest {
        let durationS: TimeInterval = 60
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = startedAt.addingTimeInterval(durationS)
        manifest.durationS = durationS
        manifest.audio = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: Int64(Data("mobile".utf8).count),
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(durationS),
            durationS: durationS,
            mode: .meeting
        )
        return ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: itemID,
            manifest: manifest,
            now: startedAt.addingTimeInterval(durationS),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
    }

    func makeZeroUploadSurfaces() -> (
        mobileSegmentUploader: MobileSegmentUploader,
        mobileSegmentHolder: MobileSegmentTransferHolder,
        importQueue: ImportQueue
    ) {
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("zero-transfer", isDirectory: true)
        )
        let mobileSegmentUploader = MobileSegmentUploader(
            transferEngine: transferHarness.engine,
            store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("mobile", isDirectory: true)),
            clock: MockObserverClock()
        )
        let mobileSegmentHolder = MobileSegmentTransferHolder(
            transferEngine: transferHarness.engine,
            mirror: transferHarness.mirror,
            uploader: mobileSegmentUploader
        )
        let importQueue = ImportQueue(
            cacheRootURL: self.tempDirectory.appendingPathComponent("import", isDirectory: true),
            sessionConfiguration: .ephemeral,
            mode: .enqueueOnly,
            startPathMonitor: false
        )
        return (mobileSegmentUploader, mobileSegmentHolder, importQueue)
    }

    func emitHealthPayload(
        queueHealth: any ObserverQueueHealthProviding,
        streamType: String,
        prefix: String
    ) async throws -> [String: Any] {
        TransferConsumerHealthURLProtocol.reset()
        TransferConsumerHealthURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let beacon = ObserverHealthBeacon(
            registration: makeTransferTestRegistration(
                streamType: streamType,
                version: "1.0.0",
                key: "test-\(streamType)-key",
                prefix: prefix
            ),
            uploader: queueHealth,
            isJournalConfigured: { true },
            session: self.healthSession(),
            clock: MockObserverClock(),
            interval: .seconds(300)
        )
        beacon.start()
        try await transferTestWaitFor("health payload \(streamType)") {
            TransferConsumerHealthURLProtocol.bodies.count == 1
        }
        beacon.stop()
        let body = try XCTUnwrap(TransferConsumerHealthURLProtocol.bodies.first)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func healthSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferConsumerHealthURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class TransferConsumerHealthURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var bodies: [Data] {
        self.bodiesBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.bodiesBox.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        do {
            guard let handler = Self.handler else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            let (response, data) = try handler(self.request)
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

        var output = Data()
        let bufferSize = 4_096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 {
                break
            }
            output.append(buffer, count: read)
        }
        return output
    }
}
