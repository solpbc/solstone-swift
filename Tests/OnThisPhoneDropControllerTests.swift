// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OnThisPhoneDropControllerTests: XCTestCase {
    func testRequestDropCommitsOnceAfterTimerFires() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("one")
        }
        await sleeper.waitForPending(1)

        XCTAssertEqual(probe.count, 0)
        XCTAssertEqual(controller.pendingIDs, Set(["one"]))
        XCTAssertEqual(controller.surfaced?.id, "one")

        sleeper.fireNext()
        await probe.waitForCount(1)

        XCTAssertEqual(probe.ids, ["one"])
        XCTAssertEqual(controller.pendingIDs, [])
        XCTAssertNil(controller.surfaced)

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 1)
    }

    func testUndoBeforeTimerFiresNeverCommits() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("one")
        }
        await sleeper.waitForPending(1)

        controller.undo(itemID: "one")
        XCTAssertEqual(controller.pendingIDs, [])
        XCTAssertNil(controller.surfaced)

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 0)
    }

    func testUndoNewestResurfacesPreviousWithoutResettingTimer() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "first", descriptor: "first") {
            probe.record("first")
        }
        await sleeper.waitForPending(1)

        controller.requestDrop(itemID: "second", descriptor: "second") {
            probe.record("second")
        }
        await sleeper.waitForPending(2)
        XCTAssertEqual(controller.surfaced?.id, "second")

        controller.undo(itemID: "second")
        XCTAssertEqual(controller.surfaced?.id, "first")
        XCTAssertEqual(controller.pendingIDs, Set(["first"]))

        sleeper.fire(at: 0)
        await probe.waitForCount(1)
        XCTAssertEqual(probe.ids, ["first"])

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 1)
    }

    func testNonSurfacedEntryCommitsAndClearsWithoutResurfacing() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "first", descriptor: "first") {
            probe.record("first")
        }
        controller.requestDrop(itemID: "second", descriptor: "second") {
            probe.record("second")
        }
        await sleeper.waitForPending(2)
        XCTAssertEqual(controller.surfaced?.id, "second")

        sleeper.fire(at: 0)
        await probe.waitForCount(1)
        XCTAssertEqual(probe.ids, ["first"])
        XCTAssertEqual(controller.pendingIDs, Set(["second"]))
        XCTAssertEqual(controller.surfaced?.id, "second")

        sleeper.fireNext()
        await probe.waitForCount(2)
        XCTAssertEqual(probe.ids, ["first", "second"])
        XCTAssertEqual(controller.pendingIDs, [])
    }

    func testDuplicateUnfinishedIDIsIgnored() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("first")
        }
        await sleeper.waitForPending(1)

        controller.requestDrop(itemID: "one", descriptor: "second") {
            probe.record("second")
        }
        await Task.yield()
        XCTAssertEqual(sleeper.pendingCount, 1)
        XCTAssertEqual(controller.surfaced?.descriptor, "first")

        sleeper.fireNext()
        await probe.waitForCount(1)
        XCTAssertEqual(probe.ids, ["first"])
        XCTAssertEqual(probe.count, 1)
    }

    func testCancelAllClearsPendingAndCancelsTimers() async {
        let sleeper = TestSleeper()
        let probe = CommitProbe()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })

        controller.requestDrop(itemID: "one", descriptor: "first") {
            probe.record("one")
        }
        await sleeper.waitForPending(1)

        controller.cancelAll()
        XCTAssertEqual(controller.pendingIDs, [])
        XCTAssertNil(controller.surfaced)

        sleeper.fireNext()
        await Task.yield()
        XCTAssertEqual(probe.count, 0)
    }

    func testMakeDropCommitReturnsClosureForValidIDsAndNilForInvalidIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneDropControllerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let shareHolder = Self.shareHolder(root: root, transferEngine: transferHarness.engine, mirror: transferHarness.mirror)
        let transferID = UUID()
        let shareID = UUID()
        let segmentID = UUID()

        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: shareID.uuidString, sourceKind: .share),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferID, source: .omi),
                sourceKind: .audio
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferID, source: .watch),
                sourceKind: .audio
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "mobile-segment:\(segmentID.uuidString):location", sourceKind: .location),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(
                id: OnThisPhoneItemID.mobileSegmentTransferIDString(itemID: transferID, facet: .screencast),
                sourceKind: .screencast
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNil(makeDropCommit(
            for: Self.item(id: "audio:not-a-uuid:chunk", sourceKind: .audio),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
    }

    func testMakeRetryCommitReturnsClosureForValidIDsAndNilForInvalidIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneRetryControllerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let shareHolder = Self.shareHolder(root: root, transferEngine: transferHarness.engine, mirror: transferHarness.mirror)
        let transferID = UUID()
        let shareID = UUID()
        let segmentID = UUID()

        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(id: shareID.uuidString, sourceKind: .share),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferID, source: .omi),
                sourceKind: .audio
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferID, source: .watch),
                sourceKind: .audio
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(id: "mobile-segment:\(segmentID.uuidString):location", sourceKind: .location),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(
                id: OnThisPhoneItemID.mobileSegmentTransferIDString(itemID: transferID, facet: .location),
                sourceKind: .location
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNil(makeRetryCommit(
            for: Self.item(id: "audio:not-a-uuid:chunk", sourceKind: .audio),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
    }

    func testMobileTransferDropCommitRoutesThroughEngine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneMobileTransferDropTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let shareHolder = Self.shareHolder(root: root, transferEngine: transferHarness.engine, mirror: transferHarness.mirror)
        let transferItemID = try await transferHarness.engine.enqueue(
            manifest: Self.mobileTransferManifest(itemID: UUID(), segmentID: UUID()),
            payloads: ["audio": Data("audio".utf8)]
        )

        let commit = try XCTUnwrap(makeDropCommit(
            for: Self.item(
                id: OnThisPhoneItemID.mobileSegmentTransferIDString(itemID: transferItemID, facet: .audio),
                sourceKind: .audio
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        commit()
        try await Task.sleep(for: .milliseconds(50))

        let snapshot = await transferHarness.engine.itemSnapshot(itemID: transferItemID)
        XCTAssertNil(snapshot)
    }

    func testShareDropControllerDropsInFlightShareItem() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }
        let gate = DispatchSemaphore(value: 0)
        TransferURLProtocol.handler = { request, _ in
            _ = gate.wait(timeout: .now() + .seconds(5))
            return (
                transferTestResponse(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/share","timestamp":"2026-07-09T00:00:00Z"}"#.utf8)
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneShareDropInFlightTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            gate.signal()
            try? FileManager.default.removeItem(at: root)
        }
        let transferHarness = makeTransferCutoverHarness(
            rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        let shareHolder = Self.shareHolder(root: root, transferEngine: transferHarness.engine, mirror: transferHarness.mirror)
        try await transferHarness.engine.start()
        let itemID = try await transferHarness.engine.enqueue(
            manifest: TransferCutoverDispatchTests.shareManifest(itemID: UUID(), index: 1),
            payloads: ["text": Data("share drop".utf8)]
        )
        try await transferTestWaitFor("share in flight") {
            await transferHarness.engine.snapshot().counters.inFlightCount == 1
        }
        let sleeper = TestSleeper()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })
        let commit = try XCTUnwrap(makeDropCommit(
            for: Self.item(id: itemID.uuidString.lowercased(), sourceKind: .share),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: Self.mobileSegmentUploader(root: root)
        ))

        controller.requestDrop(itemID: itemID.uuidString.lowercased(), descriptor: "share") {
            commit()
        }
        await sleeper.waitForPending(1)
        sleeper.fireNext()

        try await transferTestWaitFor("share dropped") {
            await transferHarness.engine.itemSnapshot(itemID: itemID) == nil
        }
        let snapshot = await transferHarness.engine.snapshot()
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(snapshot.counters.deliveredCount, 0)
        XCTAssertEqual(snapshot.counters.attentionCount, 0)
    }

    func testShareDropControllerIgnoresLateCompletionAfterDrop() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }
        let gate = DispatchSemaphore(value: 0)
        TransferURLProtocol.handler = { request, _ in
            _ = gate.wait(timeout: .now() + .seconds(5))
            return (
                transferTestResponse(for: request, statusCode: 200),
                Data(#"{"recommended_action":"do_not_start","path":"/imports/share","timestamp":"2026-07-09T00:00:00Z"}"#.utf8)
            )
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneShareLateCompletionDropTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            gate.signal()
            try? FileManager.default.removeItem(at: root)
        }
        let transferHarness = makeTransferCutoverHarness(
            rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!))),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        let shareHolder = Self.shareHolder(root: root, transferEngine: transferHarness.engine, mirror: transferHarness.mirror)
        try await transferHarness.engine.start()
        let itemID = try await transferHarness.engine.enqueue(
            manifest: TransferCutoverDispatchTests.shareManifest(itemID: UUID(), index: 2),
            payloads: ["text": Data("share late".utf8)]
        )
        try await transferTestWaitFor("share in flight") {
            await transferHarness.engine.snapshot().counters.inFlightCount == 1
        }
        let sleeper = TestSleeper()
        let controller = OnThisPhoneDropController(window: .seconds(5), sleep: { duration in
            try await sleeper.sleep(for: duration)
        })
        let commit = try XCTUnwrap(makeDropCommit(
            for: Self.item(id: itemID.uuidString.lowercased(), sourceKind: .share),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: Self.mobileSegmentUploader(root: root)
        ))

        controller.requestDrop(itemID: itemID.uuidString.lowercased(), descriptor: "share") {
            commit()
        }
        await sleeper.waitForPending(1)
        sleeper.fireNext()
        try await transferTestWaitFor("share removed before late completion") {
            await transferHarness.engine.itemSnapshot(itemID: itemID) == nil
        }
        gate.signal()
        try await Task.sleep(for: .milliseconds(100))
        await shareHolder.dropShare(itemID: itemID)

        let snapshot = await transferHarness.engine.snapshot()
        let lateSnapshot = await transferHarness.engine.itemSnapshot(itemID: itemID)
        XCTAssertNil(lateSnapshot)
        XCTAssertEqual(snapshot.counters.queuedCount, 0)
        XCTAssertEqual(snapshot.counters.inFlightCount, 0)
        XCTAssertEqual(snapshot.counters.deliveredCount, 0)
        XCTAssertEqual(snapshot.counters.attentionCount, 0)
        XCTAssertEqual(snapshot.sources[ObserverAudioTransferSource.share]?.deliveredCount ?? 0, 0)
    }

    func testMobileSegmentStoreDropCommitRemovesFailedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneMobileStoreDropTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let shareHolder = Self.shareHolder(root: root, transferEngine: transferHarness.engine, mirror: transferHarness.mirror)
        let segmentID = UUID()
        let failedDirectory = try Self.writeFailedMobileSegment(uploader: mobileSegmentUploader, segmentID: segmentID)

        let commit = try XCTUnwrap(makeDropCommit(
            for: Self.item(id: "mobile-segment:\(segmentID.uuidString):location", sourceKind: .location),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
    }

    func testMobileTransferRetryCommitRoutesThroughEngine() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneMobileTransferRetryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferSpool = TransferSpool(rootURL: root.appendingPathComponent("RetryTransfer", isDirectory: true))
        let transferItemID = UUID()
        let transferManifest = Self.mobileTransferManifest(itemID: transferItemID, segmentID: UUID())
        let staged = try transferSpool.stage(manifest: transferManifest, payloads: ["audio": Data("audio".utf8)])
        let queued = try transferSpool.commitStagedItem(itemID: staged.item.manifest.itemID)
        _ = try transferSpool.moveQueuedItemToAttention(
            queued,
            reason: "needs_attention",
            detail: "held",
            now: Date(timeIntervalSince1970: 1_780_480_800)
        )
        let retryEngine = TransferEngine(
            spool: transferSpool,
            transport: TransferTransport(authProvider: { _ in "test-transfer-key" }),
            endpointResolver: TransferCutoverEndpointResolver()
        )
        try await retryEngine.start()
        let shareHolder = Self.shareHolder(root: root, transferEngine: retryEngine, mirror: TransferStatusMirror())

        let omiCommit = try XCTUnwrap(makeRetryCommit(
            for: Self.item(
                id: OnThisPhoneItemID.mobileSegmentTransferIDString(itemID: transferItemID, facet: .audio),
                sourceKind: .audio
            ),
            share: shareHolder,
            transferEngine: retryEngine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        await omiCommit()

        let retriedSnapshot = await retryEngine.itemSnapshot(itemID: transferItemID)
        XCTAssertEqual(retriedSnapshot?.state, .queued)
    }

    func testWatchAudioDropAlsoRemovesStagingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneWatchDropTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let shareHolder = Self.shareHolder(root: root, transferEngine: transferHarness.engine, mirror: transferHarness.mirror)
        let sessionID = UUID()
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let stagedDirectory = try Self.writeStagedWatchSegment(stagingRoot: stagingRoot, id: sessionID)
        let watchManifest = try Self.loadWatchManifest(in: stagedDirectory)
        let transferItemID = try await transferHarness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeWatchManifest(
                watchManifest: watchManifest,
                hasAudio: true,
                hasLocation: false
            ),
            payloads: ["audio": Data("audio".utf8)]
        )
        let ledgerURL = root.appendingPathComponent("ledger.json", isDirectory: false)
        let pipeline = makeWatchPhonePipeline(
            transferEngine: transferHarness.engine,
            transferStatusMirror: transferHarness.mirror,
            transferEnqueuer: transferHarness.enqueuer,
            watchConnectivitySession: MockWatchConnectivitySession(),
            watchSourceFacts: Self.watchSourceFacts(),
            ledgerFileURL: ledgerURL,
            drainStagingRootURL: stagingRoot
        )

        let commit = try XCTUnwrap(makeDropCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferItemID, source: .watch),
                sourceKind: .audio
            ),
            share: shareHolder,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader,
            removeWatchStaging: pipeline.watchUploaderHolder.removeStaging
        ))
        commit()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedDirectory.path))
        XCTAssertEqual(pipeline.watchSegmentLedger.lifetimeReceived, 1)
        XCTAssertEqual(pipeline.watchSegmentLedger.lifetimeHanded, 0)
        XCTAssertTrue(pipeline.watchSegmentLedger.isTerminal(id: sessionID))
        pipeline.watchSegmentLedger.recordHanded(id: sessionID)
        XCTAssertEqual(pipeline.watchSegmentLedger.lifetimeHanded, 0)
        XCTAssertNil(pipeline.watchSegmentLedger.lastHandedAt)
        var store = try Self.loadLedgerStore(ledgerURL)
        var droppedEntry = try XCTUnwrap(store.entries[sessionID.uuidString])
        XCTAssertNotNil(droppedEntry.droppedAt)
        XCTAssertNil(droppedEntry.handedAt)

        let handThenDropID = UUID()
        let handThenDropDirectory = try Self.writeStagedWatchSegment(stagingRoot: stagingRoot, id: handThenDropID)
        pipeline.watchSegmentLedger.recordHanded(id: handThenDropID)
        pipeline.watchUploaderHolder.removeStaging?(handThenDropID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: handThenDropDirectory.path))
        XCTAssertEqual(pipeline.watchSegmentLedger.lifetimeHanded, 1)
        XCTAssertNotNil(pipeline.watchSegmentLedger.lastHandedAt)
        store = try Self.loadLedgerStore(ledgerURL)
        droppedEntry = try XCTUnwrap(store.entries[handThenDropID.uuidString])
        XCTAssertNotNil(droppedEntry.handedAt)
        XCTAssertNil(droppedEntry.droppedAt)
    }

    private static func item(id: String, sourceKind: OnThisPhoneSourceKind) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: id,
            sourceKind: sourceKind,
            sendState: .savedOnThisPhone,
            contentType: "application/octet-stream",
            filename: "item.bin",
            bytes: nil,
            originApp: nil,
            basis: nil,
            itemTime: Date(timeIntervalSince1970: 1_780_480_800),
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: nil
        )
    }

    @MainActor
    private static func mobileSegmentUploader(root: URL) -> MobileSegmentUploader {
        MobileSegmentUploader(
            store: MobileSegmentStore(rootURL: root.appendingPathComponent("MobileSegment", isDirectory: true)),
            clock: MockObserverClock()
        )
    }

    @MainActor
    private static func shareHolder(
        root: URL,
        transferEngine: TransferEngine,
        mirror: TransferStatusMirror
    ) -> ShareTransferHolder {
        ShareTransferHolder(
            transferEngine: transferEngine,
            mirror: mirror,
            store: ShareImportStore(cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true))
        )
    }

    @MainActor
    private static func watchSourceFacts() -> WatchSourceFacts {
        let suite = "OnThisPhoneDropControllerTests-WatchFacts-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return WatchSourceFacts(defaults: defaults)
    }

    @MainActor
    private static func writeFailedMobileSegment(uploader: MobileSegmentUploader, segmentID: UUID) throws -> URL {
        let store = uploader.storeForTransferMigration
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        let directory = store.segmentDirectoryURL(.failed, segmentID: segmentID)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.location],
            activeSourceSetVersion: 1
        )
        manifest.location = MobileSegmentSourceResolution(
            state: .failedToFinalize,
            reason: "test",
            stage: "source-finalize",
            lastAttemptAt: startedAt
        )
        manifest.upload = .failed
        try store.writeManifest(manifest, in: directory)
        try store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "test",
                httpStatus: nil,
                transportError: nil,
                attemptCount: 1,
                stage: "source-finalize",
                lastAttemptAt: startedAt
            ),
            in: directory
        )
        uploader.refreshCounts()
        return directory
    }

    private static func mobileTransferManifest(itemID: UUID, segmentID: UUID) -> TransferManifest {
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        manifest.audio = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: 5,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(60),
            durationS: 60,
            mode: .meeting
        )
        manifest.endedAt = startedAt.addingTimeInterval(60)
        manifest.durationS = 60
        manifest.upload = .pending
        return ObserverAudioTransferEnqueuer.makeMobileSegmentManifest(
            itemID: itemID,
            manifest: manifest,
            now: startedAt.addingTimeInterval(60),
            sources: [.audio],
            payloadParts: [ObserverAudioTransferEnqueuer.audioPart()]
        )
    }

    private static func loadLedgerStore(_ fileURL: URL) throws -> WatchSegmentLedgerStore {
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WatchSegmentLedgerStore.self, from: data)
    }

    private static func loadWatchManifest(in directory: URL) throws -> WatchSegmentManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent(WatchSegmentBundleCodec.manifestFilename))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WatchSegmentManifest.self, from: data)
    }

    @MainActor
    private static func writeStagedWatchSegment(stagingRoot: URL, id: UUID) throws -> URL {
        let directory = stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = WatchSegmentManifest(
            id: id,
            day: "20260603",
            segment: "120000_300",
            startedAt: Date(timeIntervalSince1970: 1_780_444_800),
            duration: 300,
            sensors: [.audio],
            partial: false,
            lost: false,
            gap: false,
            fixCount: 0,
            state: .finalized,
            failureReason: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(WatchSegmentBundleCodec.manifestFilename, isDirectory: false),
            options: .atomic
        )
        try Data("audio".utf8).write(
            to: directory.appendingPathComponent(WatchSegmentBundleCodec.audioFilename, isDirectory: false),
            options: .atomic
        )
        return directory
    }

    @MainActor
    private static func watchRegistration() -> ObserverRegistration {
        ObserverRegistration(
            resolveDescriptor: {
                DeviceRegistrationDescriptor(
                    hostname: "test-phone",
                    displayName: "test phone",
                    vendorIdentifier: "test-idfv"
                )
            },
            version: "0.1.0",
            streamType: "watch",
            loadKey: { "watch-handle-xyz" },
            saveKey: { _ in },
            deleteKey: {},
            loadPrefix: { nil },
            savePrefix: { _ in },
            deletePrefix: {}
        )
    }
}

@MainActor
private final class TestSleeper: @unchecked Sendable {
    private var continuations: [CheckedContinuation<Void, Error>] = []

    var pendingCount: Int {
        self.continuations.count
    }

    func sleep(for duration: Duration) async throws {
        _ = duration
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { continuation in
            self.continuations.append(continuation)
        }
        try Task.checkCancellation()
    }

    func waitForPending(_ count: Int) async {
        while self.continuations.count < count {
            await Task.yield()
        }
    }

    func fireNext() {
        self.fire(at: 0)
    }

    func fire(at index: Int) {
        guard self.continuations.indices.contains(index) else { return }
        let continuation = self.continuations.remove(at: index)
        continuation.resume()
    }
}

@MainActor
private final class CommitProbe {
    private(set) var ids: [String] = []

    var count: Int {
        self.ids.count
    }

    func record(_ id: String) {
        self.ids.append(id)
    }

    func waitForCount(_ count: Int) async {
        while self.ids.count < count {
            await Task.yield()
        }
    }
}
