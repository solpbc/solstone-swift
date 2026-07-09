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
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("Observer", isDirectory: true),
            startPathMonitor: false
        )
        let omiUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("OmiObserver", isDirectory: true),
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("WatchObserver", isDirectory: true),
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let sessionID = UUID()
        let shareID = UUID()
        let segmentID = UUID()

        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: shareID.uuidString, sourceKind: .share),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "audio:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "omi:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeDropCommit(
            for: Self.item(id: "mobile-segment:\(segmentID.uuidString):location", sourceKind: .location),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNil(makeDropCommit(
            for: Self.item(id: "audio:not-a-uuid:chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
    }

    func testMakeRetryCommitReturnsClosureForValidIDsAndNilForInvalidIDs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneRetryControllerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("Observer", isDirectory: true),
            startPathMonitor: false
        )
        let omiUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("OmiObserver", isDirectory: true),
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("WatchObserver", isDirectory: true),
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let sessionID = UUID()
        let shareID = UUID()
        let segmentID = UUID()

        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(id: shareID.uuidString, sourceKind: .share),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(id: "audio:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(id: "omi:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(id: "watch:\(sessionID.uuidString):chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNotNil(makeRetryCommit(
            for: Self.item(id: "mobile-segment:\(segmentID.uuidString):location", sourceKind: .location),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        XCTAssertNil(makeRetryCommit(
            for: Self.item(id: "audio:not-a-uuid:chunk", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
    }

    func testAudioDropCommitRoutesOnlyToOwningUploader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneDropRoutingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerRoot = root.appendingPathComponent("Observer", isDirectory: true)
        let omiRoot = root.appendingPathComponent("OmiObserver", isDirectory: true)
        let watchRoot = root.appendingPathComponent("WatchObserver", isDirectory: true)
        let observerUploader = ObserverUploader(cacheRootURL: observerRoot, startPathMonitor: false)
        let omiUploader = ObserverUploader(
            cacheRootURL: omiRoot,
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchUploader = ObserverUploader(
            cacheRootURL: watchRoot,
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let sessionID = UUID()
        let chunkID = "shared-chunk"
        let observerFailedAudio = try Self.writeFailedPair(root: observerRoot, sessionID: sessionID, chunkID: chunkID)
        let transferItemID = try await transferHarness.engine.enqueue(
            manifest: ObserverAudioTransferEnqueuer.makeOmiManifest(
                itemID: UUID(),
                sidecar: Self.sidecar(sessionID: sessionID, chunkID: chunkID)
            ),
            payloads: ["audio": Data("audio".utf8)]
        )

        let omiCommit = try XCTUnwrap(makeDropCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferItemID, source: .omi),
                sourceKind: .audio
            ),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        omiCommit()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(FileManager.default.fileExists(atPath: observerFailedAudio.path))
        let droppedSnapshot = await transferHarness.engine.itemSnapshot(itemID: transferItemID)
        XCTAssertNil(droppedSnapshot)

        let observerCommit = try XCTUnwrap(makeDropCommit(
            for: Self.item(id: "audio:\(sessionID.uuidString):\(chunkID)", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        observerCommit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: observerFailedAudio.path))
    }

    func testAudioRetryCommitRoutesOnlyToOwningUploader() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneRetryRoutingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerRoot = root.appendingPathComponent("Observer", isDirectory: true)
        let omiRoot = root.appendingPathComponent("OmiObserver", isDirectory: true)
        let watchRoot = root.appendingPathComponent("WatchObserver", isDirectory: true)
        let observerUploader = ObserverUploader(cacheRootURL: observerRoot, startPathMonitor: false)
        let omiUploader = ObserverUploader(
            cacheRootURL: omiRoot,
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchUploader = ObserverUploader(
            cacheRootURL: watchRoot,
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let sessionID = UUID()
        let chunkID = "shared-chunk"
        let observerFailedAudio = try Self.writeFailedPair(root: observerRoot, sessionID: sessionID, chunkID: chunkID)
        let transferSpool = TransferSpool(rootURL: root.appendingPathComponent("RetryTransfer", isDirectory: true))
        let transferItemID = UUID()
        let transferManifest = ObserverAudioTransferEnqueuer.makeOmiManifest(
            itemID: transferItemID,
            sidecar: Self.sidecar(sessionID: sessionID, chunkID: chunkID)
        )
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

        let omiCommit = try XCTUnwrap(makeRetryCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferItemID, source: .omi),
                sourceKind: .audio
            ),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: retryEngine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        await omiCommit()

        XCTAssertTrue(FileManager.default.fileExists(atPath: observerFailedAudio.path))
        let retriedSnapshot = await retryEngine.itemSnapshot(itemID: transferItemID)
        XCTAssertEqual(retriedSnapshot?.state, .queued)

        let observerCommit = try XCTUnwrap(makeRetryCommit(
            for: Self.item(id: "audio:\(sessionID.uuidString):\(chunkID)", sourceKind: .audio),
            importQueue: importQueue,
            observerUploader: observerUploader,
            transferEngine: transferHarness.engine,
            mobileSegmentUploader: mobileSegmentUploader
        ))
        await observerCommit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: observerFailedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.pendingAudioURL(root: observerRoot, sessionID: sessionID, chunkID: chunkID).path
        ))
    }

    func testWatchAudioDropAlsoRemovesStagingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnThisPhoneWatchDropTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let importQueue = ImportQueue(
            cacheRootURL: root.appendingPathComponent("ImportQueue", isDirectory: true),
            startPathMonitor: false
        )
        let observerUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("Observer", isDirectory: true),
            startPathMonitor: false
        )
        let omiUploader = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("OmiObserver", isDirectory: true),
            sourceType: "omi-audio",
            startPathMonitor: false
        )
        let watchRoot = root.appendingPathComponent("WatchObserver", isDirectory: true)
        let watchUploader = ObserverUploader(
            cacheRootURL: watchRoot,
            sourceType: "watch-audio",
            startPathMonitor: false
        )
        let mobileSegmentUploader = Self.mobileSegmentUploader(root: root)
        let transferHarness = makeTransferCutoverHarness(rootURL: root.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true))
        let sessionID = UUID()
        let chunkID = sessionID.uuidString
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
            ledgerFileURL: ledgerURL,
            drainStagingRootURL: stagingRoot
        )

        let commit = try XCTUnwrap(makeDropCommit(
            for: Self.item(
                id: OnThisPhoneItemID.transferIDString(itemID: transferItemID, source: .watch),
                sourceKind: .audio
            ),
            importQueue: importQueue,
            observerUploader: observerUploader,
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
        let transport = ObserverUploader(
            cacheRootURL: root.appendingPathComponent("MobileSegmentTransport", isDirectory: true),
            isJournalConfigured: { false },
            localPortProvider: { nil },
            startPathMonitor: false
        )
        return MobileSegmentUploader(
            transport: transport,
            store: MobileSegmentStore(rootURL: root.appendingPathComponent("MobileSegment", isDirectory: true)),
            clock: MockObserverClock()
        )
    }

    private static func writeFailedPair(root: URL, sessionID: UUID, chunkID: String) throws -> URL {
        let failedDirectory = root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("failed", isDirectory: true)
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        let audioURL = failedDirectory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        try Data("audio".utf8).write(to: audioURL)
        try Data("{}".utf8).write(to: failedDirectory.appendingPathComponent("\(chunkID).json", isDirectory: false))
        return audioURL
    }

    private static func sidecar(sessionID: UUID, chunkID: String) -> ChunkSidecar {
        let startedAt = Date(timeIntervalSince1970: 1_780_480_800)
        return ChunkSidecar(
            segment: chunkID,
            day: "20260603",
            chunkIndex: 0,
            startedAt: startedAt,
            durationS: 60,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
    }

    private static func pendingAudioURL(root: URL, sessionID: UUID, chunkID: String) -> URL {
        root
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(chunkID).m4a", isDirectory: false)
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
            hostname: "test-phone",
            version: "0.1.0",
            streamType: "watch",
            label: "watch",
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
