// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class BackgroundDrainCoordinatorTests: XCTestCase {
    @MainActor
    func testAC8DriveUploadDrainEnqueuesMobilePendingSegmentAndKicksEngine() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }
        TransferURLProtocol.handler = { request, _ in
            (transferTestResponse(for: request, statusCode: 204), Data())
        }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundDrainCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let transfer = makeTransferCutoverHarness(
            rootURL: tempDirectory.appendingPathComponent("Transfers", isDirectory: true),
            sessionConfiguration: makeTransferTestURLSessionConfiguration(),
            endpointResolver: TransferEndpointResolverStub(.available(TransferResolvedEndpoint(baseURL: URL(string: "http://127.0.0.1:7071")!)))
        )
        try await transfer.engine.start()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
        let store = MobileSegmentStore(rootURL: tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        let uploader = MobileSegmentUploader(transferEngine: transfer.engine, store: store, clock: clock)
        let segmentID = try Self.seedMobileSegment(store: store, clock: clock)
        let shareImportStore = ShareImportStore(
            cacheRootURL: tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        )
        let shareTransferHolder = ShareTransferHolder(
            transferEngine: transfer.engine,
            mirror: transfer.mirror,
            store: shareImportStore
        )

        await driveUploadDrain(
            mobileSegment: uploader,
            transferEngine: transfer.engine,
            shareImportStore: shareImportStore,
            shareTransferHolder: shareTransferHolder,
            diagnosticLog: nil,
            watchDrain: nil
        )

        try await transferTestWaitFor("mobile drain delivered", timeout: .seconds(4)) {
            await transfer.engine.snapshot().sources[ObserverAudioTransferSource.mobileSegment]?.deliveredCount == 1
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.segmentDirectoryURL(.pending, segmentID: segmentID).path
        ))
    }

    @MainActor
    func testDriveUploadDrainAdoptsStagedShareImportWithoutExtensionEngineCall() async throws {
        TransferURLProtocol.reset()
        defer { TransferURLProtocol.reset() }
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundDrainShareAdoptionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000040001")!
        let shareImportStore = ShareImportStore(
            cacheRootURL: tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true)
        )
        _ = try ShareImportLegacyTestSupport.writeLegacyItem(
            root: shareImportStore.cacheRootURL,
            itemID: itemID,
            source: "quick",
            raw: Data("share drain".utf8),
            contentType: "text/plain",
            requestFilename: "text.txt",
            originalFilename: "note.txt"
        )
        let transfer = makeTransferCutoverHarness(
            rootURL: tempDirectory.appendingPathComponent("Transfers", isDirectory: true),
            endpointResolver: TransferEndpointResolverStub(.unavailable("waiting")),
            bodyBuilder: TransferCutoverDispatchTests.shareBodyBuilder
        )
        try await transfer.engine.start()
        let mobileUploader = MobileSegmentUploader(
            transferEngine: transfer.engine,
            store: MobileSegmentStore(rootURL: tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)),
            clock: MockObserverClock()
        )
        let shareTransferHolder = ShareTransferHolder(
            transferEngine: transfer.engine,
            mirror: transfer.mirror,
            store: shareImportStore
        )

        await driveUploadDrain(
            mobileSegment: mobileUploader,
            transferEngine: transfer.engine,
            shareImportStore: shareImportStore,
            shareTransferHolder: shareTransferHolder,
            diagnosticLog: nil,
            watchDrain: nil
        )

        let snapshot = await transfer.engine.itemSnapshot(itemID: itemID)
        XCTAssertEqual(snapshot?.sourceKey, ObserverAudioTransferSource.share)
        XCTAssertEqual(snapshot?.state, .queued)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ShareImportLegacyTestSupport.itemDirectory(
            root: shareImportStore.cacheRootURL,
            status: "pending",
            itemID: itemID
        ).path))
    }

    @MainActor
    func testDrainedTerminalRunsDriveOnceAndDisconnects() async {
        let totals = TotalsBox(failed: 1, pending: 1)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                totals.failed = 0
                totals.pending = 0
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testGenuineNoProgressGivesOneGraceRedriveThenDisconnects() async {
        let totals = TotalsBox(failed: 0, pending: 2)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let clock = MockObserverClock()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.run()
        }
        await self.drain(until: {
            counters.driveCount == 1 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)

        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 2)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testBackoffOnLiveEndpointKeepsDrainingInsteadOfDisconnecting() async {
        let totals = TotalsBox(failed: 0, pending: 2)
        let backoff = BackoffBox(backoffPendingCount: 1, endpointHeld: false)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let clock = MockObserverClock()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { backoff.snapshot },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.run()
        }
        await self.drain(until: {
            counters.driveCount == 1 && clock.pendingSleeperCount == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)

        clock.advance(by: 1)
        await self.drain(until: {
            counters.driveCount == 2 && clock.pendingSleeperCount == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)

        totals.pending = 0
        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 3)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testInFlightNoProgressHoldsUntilTotalsDrain() async {
        let totals = TotalsBox(failed: 0, pending: 2)
        let inFlight = InFlightBox(1)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let clock = MockObserverClock()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { inFlight.value },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.run()
        }
        await self.drain(until: {
            counters.driveCount == 1 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)

        clock.advance(by: 1)
        await self.drain(until: {
            counters.driveCount == 2 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.disconnectCount, 0)

        inFlight.value = 0
        totals.pending = 0
        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 3)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testMultiCycleProgressThenDrainedUsesClockSettle() async {
        let totals = TotalsBox(failed: 4, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let clock = MockObserverClock()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                if counters.driveCount == 1 {
                    totals.failed = 3
                } else {
                    totals.failed = 0
                }
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: clock,
            settleInterval: .milliseconds(1)
        )

        let runTask = Task {
            await coordinator.run()
        }
        await self.drain(until: {
            counters.driveCount == 1 && self.pendingSleeperCount(in: clock) == 1
        })
        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(self.pendingSleeperCount(in: clock), 1)

        clock.advance(by: 1)
        await runTask.value

        XCTAssertEqual(counters.driveCount, 2)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testExpirationTerminalDisconnectsAndEndsOnce() async {
        let totals = TotalsBox(failed: 1, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                asserter.fireExpiration()
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    func testSustainDoesNotBeginDriveOrDisconnect() async {
        let totals = TotalsBox(failed: 1, pending: 1)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { true },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 0)
        XCTAssertEqual(asserter.beginCount, 0)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testEmptyBacklogDisconnectsWithoutBeginningOrDriving() async {
        let totals = TotalsBox(failed: 0, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 0)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testNotConnectedBacklogDisconnectsWithoutBeginning() async {
        let totals = TotalsBox(failed: 2, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { false },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 0)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testInvalidBackgroundAssertionDisconnectsWithoutDriving() async {
        let totals = TotalsBox(failed: 1, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        asserter.beginReturn = false
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 0)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 0)
    }

    @MainActor
    func testEndIsIdempotentWhenExpirationAndCompletionBothRun() async {
        let totals = TotalsBox(failed: 1, pending: 0)
        let asserter = SpyBackgroundTaskAsserter()
        let counters = CountersBox()
        let coordinator = BackgroundDrainCoordinator(
            totals: { totals.snapshot },
            inFlight: { 0 },
            backoff: { TransferBackoffStatus(backoffPendingCount: 0, endpointHeld: false) },
            isSustaining: { false },
            isConnected: { true },
            drive: {
                counters.driveCount += 1
                asserter.fireExpiration()
                totals.failed = 0
            },
            disconnect: {
                counters.disconnectCount += 1
            },
            asserter: asserter,
            clock: MockObserverClock()
        )

        await coordinator.run()

        XCTAssertEqual(counters.driveCount, 1)
        XCTAssertEqual(counters.disconnectCount, 1)
        XCTAssertEqual(asserter.beginCount, 1)
        XCTAssertEqual(asserter.endCount, 1)
    }

    @MainActor
    private func drain(until condition: () -> Bool, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
    }

    @MainActor
    private func pendingSleeperCount(in clock: MockObserverClock) -> Int {
        guard let sleepers = Mirror(reflecting: clock).children.first(where: { $0.label == "sleepers" }) else {
            return 0
        }
        return Mirror(reflecting: sleepers.value).children.count
    }
}

private extension BackgroundDrainCoordinatorTests {
    @MainActor
    static func seedMobileSegment(store: MobileSegmentStore, clock: MockObserverClock) throws -> UUID {
        let startedAt = clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        let segmentID = UUID()
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending
        let directory = try store.createActive(manifest: manifest)
        let audioURL = store.audioURL(in: directory)
        try Data("audio".utf8).write(to: audioURL, options: .atomic)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: audioURL.lastPathComponent,
                bytes: store.fileSize(at: audioURL),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60,
                mode: .meeting
            ),
            source: .audio,
            manifest: &manifest,
            in: directory,
            now: endedAt
        )
        manifest.upload = .pending
        try store.writeManifest(manifest, in: directory)
        _ = try store.move(segmentID: segmentID, from: .active, to: .pending)
        return segmentID
    }
}

@MainActor
private final class TotalsBox {
    var failed: Int
    var pending: Int

    init(failed: Int, pending: Int) {
        self.failed = failed
        self.pending = pending
    }

    var snapshot: (failed: Int, pending: Int) {
        (failed: self.failed, pending: self.pending)
    }
}

@MainActor
private final class CountersBox {
    var driveCount = 0
    var disconnectCount = 0
}

@MainActor
private final class InFlightBox {
    var value: Int

    init(_ value: Int) {
        self.value = value
    }
}

@MainActor
private final class BackoffBox {
    var backoffPendingCount: Int
    var endpointHeld: Bool

    init(backoffPendingCount: Int, endpointHeld: Bool) {
        self.backoffPendingCount = backoffPendingCount
        self.endpointHeld = endpointHeld
    }

    var snapshot: TransferBackoffStatus {
        TransferBackoffStatus(
            backoffPendingCount: self.backoffPendingCount,
            endpointHeld: self.endpointHeld
        )
    }
}

@MainActor
private final class SpyBackgroundTaskAsserter: BackgroundTaskAsserting {
    var beginReturn = true
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var handler: (@MainActor () -> Void)?

    func begin(expirationHandler: @escaping @MainActor () -> Void) -> Bool {
        self.beginCount += 1
        self.handler = expirationHandler
        return self.beginReturn
    }

    func end() {
        self.endCount += 1
    }

    func fireExpiration() {
        self.handler?()
    }
}
