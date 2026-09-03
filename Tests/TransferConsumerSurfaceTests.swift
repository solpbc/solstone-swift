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
    }

    override func tearDown() {
        TransferURLProtocol.reset()
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testLastCaptureSyncedAtExcludesRecentShareDelivery() {
        let zeroSurfaces = self.makeZeroUploadSurfaces()
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("capture-only-transfer", isDirectory: true)
        )
        let shareDelivery = Date(timeIntervalSince1970: 1_780_480_800)
        zeroSurfaces.shareHolder.store.lastDeliveredAt = shareDelivery

        XCTAssertNil(lastCaptureSyncedAt(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch
        ))
        XCTAssertEqual(lastSyncedAt(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: zeroSurfaces.shareHolder
        ), shareDelivery)
    }

    func testAC8RealEngineStateFeedsAllOmiAndWatchConsumerSurfaces() async throws {
        let clock = FakeTransferClock(wall: Date(timeIntervalSince1970: 1_780_480_800))
        let responses = OSAllocatedUnfairLock<[UUID: RoutedTransferResponse]>(initialState: [:])
        TransferURLProtocol.handler = { request, _ in
            guard let itemID = transferTestBoundaryItemID(from: request) else {
                return (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
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
        responses.withLock { $0[deliveredID] = .status(200, Data(#"{"status":"ok"}"#.utf8)) }
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

        var aggregate = await OnThisPhoneSnapshotAggregator.snapshot(
            share: zeroSurfaces.shareHolder,
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
            share: zeroSurfaces.shareHolder
        )
        XCTAssertEqual(totals.pending, 3)
        XCTAssertEqual(totals.failed, 2)
        XCTAssertEqual(uploadInFlight(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: zeroSurfaces.shareHolder
        ), 1)
        XCTAssertEqual(lastSyncedAt(
            mobileSegment: zeroSurfaces.mobileSegmentHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: zeroSurfaces.shareHolder
        ), clock.wallNow())

        let syncModel = ConnectionSyncModel(clock: MockObserverClock()) {
            let totals = uploadTotals(
                mobileSegment: zeroSurfaces.mobileSegmentHolder,
                omi: harness.omi,
                watch: harness.watch,
                share: zeroSurfaces.shareHolder
            )
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 7071, via: .lan),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: confirmedTransferCount(
                    mobileSegment: zeroSurfaces.mobileSegmentHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    share: zeroSurfaces.shareHolder
                ),
                recentBytesPerSecond: recentBytesTotal(
                    mobileSegment: zeroSurfaces.mobileSegmentHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    share: zeroSurfaces.shareHolder
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
            share: zeroSurfaces.shareHolder,
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
            share: zeroSurfaces.shareHolder
        )
        XCTAssertEqual(totals.pending, 2)
        try await harness.engine.retryAttention(itemID: watchAttentionIDs[0])
        try await transferTestWaitFor("single watch item retried") {
            await MainActor.run {
                harness.watch.pendingCount == 1 && harness.watch.failedCount == 1
            }
        }
        aggregate = await OnThisPhoneSnapshotAggregator.snapshot(
            share: zeroSurfaces.shareHolder,
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
                return (transferTestResponse(for: request, statusCode: 200), Data(#"{"status":"ok"}"#.utf8))
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
        let shareHolder = ShareTransferHolder(
            transferEngine: harness.engine,
            mirror: harness.mirror,
            store: ShareImportStore(cacheRootURL: self.tempDirectory.appendingPathComponent("mobile-import-zero", isDirectory: true))
        )

        let deliveredID = Self.uuid(100)
        responses.withLock { $0[deliveredID] = .status(200, Data(#"{"status":"ok"}"#.utf8)) }
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
            share: shareHolder
        )
        XCTAssertEqual(totals.pending, 1)
        XCTAssertEqual(totals.failed, 1)
        XCTAssertEqual(uploadFailedTotal(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: shareHolder
        ), 1)
        XCTAssertEqual(uploadInFlight(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: shareHolder
        ), 1)
        XCTAssertEqual(lastSyncedAt(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: shareHolder
        ), clock.wallNow())
        XCTAssertEqual(confirmedTransferCount(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: shareHolder
        ), 1)
        XCTAssertGreaterThan(recentBytesTotal(
            mobileSegment: mobileHolder,
            omi: harness.omi,
            watch: harness.watch,
            share: shareHolder
        ), 0)

        let syncModel = ConnectionSyncModel(clock: MockObserverClock()) {
            let totals = uploadTotals(
                mobileSegment: mobileHolder,
                omi: harness.omi,
                watch: harness.watch,
                share: shareHolder
            )
            return ConnectionSyncInputs(
                tunnelState: .connected(localPort: 7071, via: .lan),
                reconnectCountdown: nil,
                isNetworkSatisfied: true,
                confirmedTransferCount: confirmedTransferCount(
                    mobileSegment: mobileHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    share: shareHolder
                ),
                recentBytesPerSecond: recentBytesTotal(
                    mobileSegment: mobileHolder,
                    omi: harness.omi,
                    watch: harness.watch,
                    share: shareHolder
                ),
                backlogPending: totals.pending,
                backlogFailed: totals.failed
            )
        }
        XCTAssertEqual(syncModel.status, .connectedTransferring)
    }

    func testBodyBuildFailuresPersistOwnerSafeDetailsToConsumerSurfaces() async throws {
        let clock = FakeTransferClock(wall: Date(timeIntervalSince1970: 1_780_480_800))
        let harness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent("body-build-transfer", isDirectory: true),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            clock: clock,
            maxConcurrent: 1
        )
        try await harness.engine.start()
        await harness.engine.pause()
        let mobileUploader = MobileSegmentUploader(
            transferEngine: harness.engine,
            store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("body-build-mobile-store", isDirectory: true)),
            clock: MockObserverClock()
        )
        let shareHolder = ShareTransferHolder(
            transferEngine: harness.engine,
            mirror: harness.mirror,
            store: ShareImportStore(cacheRootURL: self.tempDirectory.appendingPathComponent("body-build-import-zero", isDirectory: true))
        )

        let missingMetadataID = Self.uuid(200)
        var missingMetadataManifest = Self.mobileManifest(
            itemID: missingMetadataID,
            segmentID: Self.uuid(201),
            startedAt: clock.wallNow()
        )
        missingMetadataManifest.observerIngest = nil
        _ = try await harness.engine.enqueue(
            manifest: missingMetadataManifest,
            payloads: ["audio": Data("missing-metadata".utf8)]
        )

        let missingArtifactID = Self.uuid(202)
        var missingArtifactManifest = Self.mobileManifest(
            itemID: missingArtifactID,
            segmentID: Self.uuid(203),
            startedAt: clock.wallNow().addingTimeInterval(1)
        )
        missingArtifactManifest.payloadParts[0].requiredForDispatch = false
        _ = try await harness.engine.enqueue(
            manifest: missingArtifactManifest,
            payloads: ["audio": Data("missing-artifact".utf8)]
        )
        let optionalPayloadURLCandidate = await harness.engine.payloadFileURL(itemID: missingArtifactID, partID: "audio")
        let optionalPayloadURL = try XCTUnwrap(optionalPayloadURLCandidate)
        try FileManager.default.removeItem(at: optionalPayloadURL)

        await harness.engine.resume()
        try await transferTestWaitFor("body build failures reach attention") {
            await harness.engine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.attentionCount == 2
        }

        let transferSnapshots = await harness.engine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let metadataSnapshot = try XCTUnwrap(transferSnapshots.first { $0.itemID == missingMetadataID })
        let artifactSnapshot = try XCTUnwrap(transferSnapshots.first { $0.itemID == missingArtifactID })
        XCTAssertEqual(metadataSnapshot.manifest.attention?.reason, "malformed_manifest")
        XCTAssertEqual(metadataSnapshot.manifest.attention?.shortDetail, "missing source details")
        XCTAssertEqual(artifactSnapshot.manifest.attention?.reason, "missing_payload")
        XCTAssertEqual(artifactSnapshot.manifest.attention?.shortDetail, "source file")

        let persistedValues = [
            metadataSnapshot.manifest.attention?.reason,
            metadataSnapshot.manifest.attention?.shortDetail,
            artifactSnapshot.manifest.attention?.reason,
            artifactSnapshot.manifest.attention?.shortDetail,
        ].compactMap { $0 }
        XCTAssertFalse(persistedValues.contains { $0.contains("missing observer metadata") })
        XCTAssertFalse(persistedValues.contains { $0.contains("observer artifact") })

        let aggregate = await OnThisPhoneSnapshotAggregator.snapshot(
            share: shareHolder,
            mobileSegmentUploader: mobileUploader,
            transferEngine: harness.engine
        )
        let metadataItem = try XCTUnwrap(aggregate.items.first {
            $0.id == OnThisPhoneItemID.mobileSegmentTransferIDString(itemID: missingMetadataID, facet: .audio)
        })
        let artifactItem = try XCTUnwrap(aggregate.items.first {
            $0.id == OnThisPhoneItemID.mobileSegmentTransferIDString(itemID: missingArtifactID, facet: .audio)
        })
        XCTAssertEqual(metadataItem.failureReason, "malformed_manifest: missing source details")
        XCTAssertEqual(artifactItem.failureReason, "missing_payload: source file")
        let visibleValues = [
            metadataItem.failureReason,
            artifactItem.failureReason,
        ].compactMap { $0 }
        XCTAssertFalse(visibleValues.contains { $0.contains("missing observer metadata") })
        XCTAssertFalse(visibleValues.contains { $0.contains("observer artifact") })
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
        shareHolder: ShareTransferHolder
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
        let shareHolder = ShareTransferHolder(
            transferEngine: transferHarness.engine,
            mirror: transferHarness.mirror,
            store: ShareImportStore(cacheRootURL: self.tempDirectory.appendingPathComponent("import", isDirectory: true))
        )
        return (mobileSegmentUploader, mobileSegmentHolder, shareHolder)
    }

}
