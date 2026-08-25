// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

private final class AppGroupMirrorDateSource: @unchecked Sendable {
    var value: Date

    init(_ value: Date) {
        self.value = value
    }
}

@MainActor
private final class AppGroupMirrorTimelineReloader: AppGroupTimelineReloading {
    private(set) var kinds: [String] = []

    func reloadTimelines(ofKind kind: String) {
        self.kinds.append(kind)
    }
}

nonisolated final class AppGroupMirrorTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppGroupMirrorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    @MainActor
    func testContainerUnavailableReturnsUnknownSnapshot() {
        let mirror = AppGroupMirror(rootURLProvider: {
            throw AppGroupContainerError.unavailable(identifier: "test")
        })

        XCTAssertNil(mirror.snapshot())
        guard case .failure(.containerUnavailable) = mirror.writePairing(journalName: "sol") else {
            return XCTFail("expected unavailable container failure")
        }
    }

    @MainActor
    func testPairingWriteAndClearRemainEndToEnd() {
        let mirror = self.makeMirror()

        self.assertSuccess(mirror.writePairing(journalName: "sol"))
        XCTAssertEqual(
            mirror.snapshot()?.pairing,
            AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true)
        )

        self.assertSuccess(mirror.clearPairing())
        XCTAssertEqual(
            mirror.snapshot()?.pairing,
            AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false)
        )
    }

    @MainActor
    func testSnapshotReturnsNilForAbsentMalformedAndStaleFiles() throws {
        let now = Date(timeIntervalSince1970: 1_776_144_000)
        let dateSource = AppGroupMirrorDateSource(now)
        let mirror = self.makeMirror(dateSource: dateSource)
        let snapshotURL = self.snapshotURL

        XCTAssertNil(mirror.snapshot())

        try Data("not json".utf8).write(to: snapshotURL)
        XCTAssertNil(mirror.snapshot())

        let stale = self.snapshot(writtenAt: now.addingTimeInterval(-61))
        try JSONEncoder().encode(stale).write(to: snapshotURL)
        XCTAssertNil(mirror.snapshot())
    }

    @MainActor
    func testFreshSnapshotReturnsValuesAndWritesBytesAtContainerPath() throws {
        let mirror = self.makeMirror()
        let sourceStates: [SourceKind: SourceState] = [.observer: .active, .location: .off]

        self.assertSuccess(mirror.writePairing(journalName: "sol"))
        self.assertSuccess(
            mirror.updateSessionAndSources(
                session: .live(mode: .meeting, startedAt: Date(timeIntervalSince1970: 1_776_144_000)),
                sourceStates: sourceStates,
                backlogCount: 9
            )
        )

        let data = try Data(contentsOf: self.snapshotURL)
        let stored = try JSONDecoder().decode(AppGroupMirror.Snapshot.self, from: data)
        XCTAssertEqual(stored, mirror.snapshot())
        XCTAssertEqual(stored.schemaVersion, AppGroupMirror.Snapshot.currentSchemaVersion)
        XCTAssertEqual(stored.pairing, AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true))
        XCTAssertEqual(stored.sourceStates, sourceStates)
        XCTAssertEqual(stored.backlogCount, 9)
    }

    @MainActor
    func testWritesAdvanceWrittenAtForPairingAndSessionChanges() throws {
        let dateSource = AppGroupMirrorDateSource(Date(timeIntervalSince1970: 1_776_144_000))
        let mirror = self.makeMirror(dateSource: dateSource)

        self.assertSuccess(mirror.writePairing(journalName: "sol"))
        let pairingWrite = try XCTUnwrap(mirror.snapshot())

        dateSource.value = pairingWrite.writtenAt.addingTimeInterval(1)
        self.assertSuccess(mirror.updateSessionAndSources(session: .notLive, sourceStates: [.observer: .off], backlogCount: 0))
        let sessionWrite = try XCTUnwrap(mirror.snapshot())

        XCTAssertGreaterThan(sessionWrite.writtenAt, pairingWrite.writtenAt)
    }

    @MainActor
    func testSessionWriteReloadsTheSharedWidgetKind() {
        let reloader = AppGroupMirrorTimelineReloader()
        let mirror = self.makeMirror(timelineReloader: reloader)

        self.assertSuccess(mirror.updateSessionAndSources(session: .notLive, sourceStates: [:], backlogCount: 0))

        XCTAssertEqual(reloader.kinds, [AppGroupMirror.Snapshot.widgetKind])
    }

    @MainActor
    func testUnchangedSessionWritesOnlyAtTheHeartbeatInterval() throws {
        let dateSource = AppGroupMirrorDateSource(Date(timeIntervalSince1970: 1_776_144_000))
        let reloader = AppGroupMirrorTimelineReloader()
        let mirror = self.makeMirror(dateSource: dateSource, timelineReloader: reloader)

        self.assertSuccess(mirror.updateSessionAndSources(session: .notLive, sourceStates: [.observer: .off], backlogCount: 0))
        let firstWrite = try XCTUnwrap(mirror.snapshot())

        dateSource.value = firstWrite.writtenAt.addingTimeInterval(29)
        self.assertSuccess(mirror.updateSessionAndSources(session: .notLive, sourceStates: [.observer: .off], backlogCount: 0))
        XCTAssertEqual(mirror.snapshot()?.writtenAt, firstWrite.writtenAt)
        XCTAssertEqual(reloader.kinds, [AppGroupMirror.Snapshot.widgetKind])

        dateSource.value = firstWrite.writtenAt.addingTimeInterval(31)
        self.assertSuccess(mirror.updateSessionAndSources(session: .notLive, sourceStates: [.observer: .off], backlogCount: 0))
        XCTAssertEqual(mirror.snapshot()?.writtenAt, dateSource.value)
        XCTAssertEqual(reloader.kinds, [AppGroupMirror.Snapshot.widgetKind, AppGroupMirror.Snapshot.widgetKind])
    }

    @MainActor
    func testBacklogIsWrittenFromTransferTotalsUntilTheNextWrite() throws {
        let transferRoot = self.rootURL.appendingPathComponent("Transfers", isDirectory: true)
        let transfer = makeTransferCutoverHarness(rootURL: transferRoot)
        let mobileUploader = MobileSegmentUploader(
            transferEngine: transfer.engine,
            store: MobileSegmentStore(rootURL: self.rootURL.appendingPathComponent("MobileSegment", isDirectory: true)),
            clock: MockObserverClock()
        )
        let mobile = MobileSegmentTransferHolder(
            transferEngine: transfer.engine,
            mirror: transfer.mirror,
            uploader: mobileUploader
        )
        let share = ShareTransferHolder(
            transferEngine: transfer.engine,
            mirror: transfer.mirror,
            store: ShareImportStore(cacheRootURL: self.rootURL.appendingPathComponent("Share", isDirectory: true))
        )
        transfer.mirror.apply(snapshot: self.transferSnapshot(
            mobile: self.sourceStatus(queued: 2, attention: 1),
            omi: self.sourceStatus(queued: 3, attention: 4),
            watch: self.sourceStatus(queued: 5, attention: 6),
            share: self.sourceStatus(queued: 7, attention: 8)
        ))
        let totals = uploadTotals(mobileSegment: mobile, omi: transfer.omi, watch: transfer.watch, share: share)
        let mirror = self.makeMirror()

        self.assertSuccess(
            mirror.updateSessionAndSources(
                session: .notLive,
                sourceStates: [.observer: .off],
                backlogCount: totals.pending + totals.failed
            )
        )
        XCTAssertEqual(mirror.snapshot()?.backlogCount, 36)

        transfer.mirror.apply(snapshot: self.transferSnapshot(
            mobile: self.sourceStatus(queued: 0, attention: 0),
            omi: self.sourceStatus(queued: 0, attention: 0),
            watch: self.sourceStatus(queued: 0, attention: 0),
            share: self.sourceStatus(queued: 0, attention: 0)
        ))

        XCTAssertEqual(mirror.snapshot()?.backlogCount, 36)
    }
}

@MainActor
private extension AppGroupMirrorTests {
    func makeMirror(
        dateSource: AppGroupMirrorDateSource? = nil,
        timelineReloader: any AppGroupTimelineReloading = AppGroupWidgetTimelineReloader()
    ) -> AppGroupMirror {
        let rootURL = self.rootURL!
        return AppGroupMirror(
            rootURLProvider: { rootURL },
            now: { dateSource?.value ?? Date() },
            timelineReloader: timelineReloader
        )
    }

    var snapshotURL: URL {
        self.rootURL.appendingPathComponent(AppGroupMirror.Snapshot.fileName)
    }

    func snapshot(writtenAt: Date) -> AppGroupMirror.Snapshot {
        AppGroupMirror.Snapshot(
            schemaVersion: AppGroupMirror.Snapshot.currentSchemaVersion,
            writtenAt: writtenAt,
            pairing: AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true),
            session: .live(mode: .meeting, startedAt: writtenAt),
            sourceStates: [.observer: .active, .location: .off],
            backlogCount: 4
        )
    }

    func sourceStatus(queued: Int, attention: Int) -> TransferSourceStatusSnapshot {
        TransferSourceStatusSnapshot(
            queuedCount: queued,
            attentionCount: attention,
            inFlightCount: 0,
            deliveredCount: 0,
            droppedCount: 0,
            lastDeliveredAt: nil,
            lastErrorDetail: nil,
            recentErrorCount: 0,
            bytesPerSecond: 0
        )
    }

    func transferSnapshot(
        mobile: TransferSourceStatusSnapshot,
        omi: TransferSourceStatusSnapshot,
        watch: TransferSourceStatusSnapshot,
        share: TransferSourceStatusSnapshot
    ) -> TransferStatusSnapshot {
        TransferStatusSnapshot(
            counters: .empty,
            paused: false,
            policyPaused: false,
            backoffPendingCount: 0,
            soonestNextAttemptAt: nil,
            endpointHeld: false,
            lastEventSummary: nil,
            lastUpdatedAt: Date(),
            sources: [
                ObserverAudioTransferSource.mobileSegment: mobile,
                ObserverAudioTransferSource.omi: omi,
                ObserverAudioTransferSource.watch: watch,
                ObserverAudioTransferSource.share: share,
            ],
            aggregateBytesPerSecond: 0
        )
    }

    func assertSuccess(
        _ result: Result<Void, AppGroupMirror.StorageError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("unexpected mirror write failure: \(error)", file: file, line: line)
        }
    }
}
