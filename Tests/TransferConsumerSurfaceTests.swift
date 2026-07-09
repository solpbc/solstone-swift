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
            mobileSegment: zeroSurfaces.mobileSegmentUploader,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: zeroSurfaces.importQueue
        )
        XCTAssertEqual(totals.pending, 3)
        XCTAssertEqual(totals.failed, 2)
        XCTAssertEqual(uploadInFlight(
            mobileSegment: zeroSurfaces.mobileSegmentUploader,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: zeroSurfaces.importQueue
        ), 1)
        XCTAssertEqual(lastSyncedAt(
            mobileSegment: zeroSurfaces.mobileSegmentUploader,
            omi: harness.omi,
            watch: harness.watch,
            importQueue: zeroSurfaces.importQueue
        ), clock.wallNow())

        let observerUploader = zeroSurfaces.observerUploader
        let syncModel = ConnectionSyncModel(clock: MockObserverClock()) {
            let totals = uploadTotals(
                mobileSegment: zeroSurfaces.mobileSegmentUploader,
                omi: harness.omi,
                watch: harness.watch,
                importQueue: zeroSurfaces.importQueue
            )
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 7071, via: .lan),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: confirmedTransferCount(
                    observer: observerUploader,
                    omi: harness.omi,
                    watch: harness.watch,
                    importQueue: zeroSurfaces.importQueue
                ),
                recentBytesPerSecond: recentBytesTotal(
                    observer: observerUploader,
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
            mobileSegment: zeroSurfaces.mobileSegmentUploader,
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
}

private enum RoutedTransferResponse: Sendable {
    case status(Int, Data)
    case hold
}

private extension TransferConsumerSurfaceTests {
    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    func makeZeroUploadSurfaces() -> (
        observerUploader: ObserverUploader,
        mobileSegmentUploader: MobileSegmentUploader,
        importQueue: ImportQueue
    ) {
        let observerUploader = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("observer", isDirectory: true),
            sessionConfiguration: .ephemeral,
            startPathMonitor: false
        )
        let mobileSegmentUploader = MobileSegmentUploader(
            transport: observerUploader,
            store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("mobile", isDirectory: true)),
            clock: MockObserverClock()
        )
        let importQueue = ImportQueue(
            cacheRootURL: self.tempDirectory.appendingPathComponent("import", isDirectory: true),
            sessionConfiguration: .ephemeral,
            mode: .enqueueOnly,
            startPathMonitor: false
        )
        return (observerUploader, mobileSegmentUploader, importQueue)
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
