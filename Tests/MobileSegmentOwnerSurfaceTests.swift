// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentOwnerSurfaceTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        MobileSegmentOwnerHealthURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentOwnerSurfaceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        MobileSegmentOwnerHealthURLProtocol.reset()
        super.tearDown()
    }

    func testOwnerSurfacesCountMixedBundleOnceWhileRenderingThreeFacets() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeMixedBundle(store: harness.store, segmentID: segmentID, lifecycle: .pending)
        await harness.mobileSegmentUploader.resumeFromDisk()

        let snapshot = await OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: harness.importQueue,
            mobileSegmentUploader: harness.mobileSegmentUploader,
            transferEngine: harness.transferEngine
        )
        let transferSnapshots = await harness.transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let transferSnapshot = try XCTUnwrap(
            transferSnapshots.first { $0.manifest.observerIngest?.segmentID == segmentID }
        )
        let facets = snapshot.items.filter {
            $0.dropGroupID == OnThisPhoneItemID.mobileSegmentTransferDropGroupID(itemID: transferSnapshot.itemID)
        }
        XCTAssertEqual(facets.count, 3)
        XCTAssertEqual(Set(facets.map(\.sourceKind)), [.audio, .location, .screencast])
        XCTAssertEqual(harness.mobileSegmentUploader.pendingCount, 0)
        try await transferTestWaitFor("mobile holder queued") {
            await MainActor.run { harness.mobileSegmentHolder.pendingCount == 1 }
        }
        XCTAssertEqual(harness.mobileSegmentHolder.summary(for: .audio).pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentHolder.summary(for: .location).pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentHolder.summary(for: .screencast).pendingCount, 1)

        let totals = uploadTotals(
            mobileSegment: harness.mobileSegmentHolder,
            omi: harness.omiHolder,
            watch: harness.watchHolder,
            importQueue: harness.importQueue
        )
        XCTAssertEqual(totals.pending, 1)

        let registration = self.registration()
        let beacon = ObserverHealthBeacon(
            registration: registration,
            uploader: harness.mobileSegmentHolder,
            isJournalConfigured: { true },
            session: self.healthSession(),
            clock: self.clock,
            interval: .seconds(300)
        )
        MobileSegmentOwnerHealthURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        beacon.start()
        try await self.waitFor("health payload") {
            MobileSegmentOwnerHealthURLProtocol.callCount == 1
        }
        beacon.stop()
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(MobileSegmentOwnerHealthURLProtocol.capturedBodies.first)) as? [String: Any])
        XCTAssertEqual(payload["pending_queue_depth"] as? Int, 1)
    }

    func testMixedBundleDropAndRetryMoveTheWholeBundle() async throws {
        let harness = self.makeHarness()
        let pendingSegmentID = UUID()
        try self.writeMixedBundle(store: harness.store, segmentID: pendingSegmentID, lifecycle: .pending)
        harness.mobileSegmentUploader.refreshCounts()

        let failedSegmentID = UUID()
        try self.writeMixedBundle(store: harness.store, segmentID: failedSegmentID, lifecycle: .failed)
        harness.mobileSegmentUploader.refreshCounts()

        let item = try XCTUnwrap(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .audio).loadedItems.first)
        let commit = try XCTUnwrap(makeDropCommit(
            for: item,
            importQueue: harness.importQueue,
            transferEngine: harness.transferEngine,
            mobileSegmentUploader: harness.mobileSegmentUploader
        ))
        commit()

        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: pendingSegmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: failedSegmentID).path))
        XCTAssertTrue(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .audio).loadedItems.isEmpty)
        XCTAssertTrue(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .location).loadedItems.isEmpty)
        XCTAssertTrue(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .screencast).loadedItems.isEmpty)
        XCTAssertEqual(harness.mobileSegmentUploader.pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentUploader.failedCount, 0)
    }

    func testScreencastRedactionPreservesRemainingFacetsAndTombstonesScreencastOnlyBundle() async throws {
        let harness = self.makeHarness()
        let mixedSegmentID = UUID()
        try self.writeMixedBundle(store: harness.store, segmentID: mixedSegmentID, lifecycle: .pending)

        await harness.mobileSegmentUploader.redactScreencastFacet(segmentID: mixedSegmentID)

        let mixedDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: mixedSegmentID)
        let mixedSnapshots = await harness.transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let mixedSnapshot = try XCTUnwrap(
            mixedSnapshots.first { $0.manifest.observerIngest?.segmentID == mixedSegmentID }
        )
        XCTAssertEqual(Set(mixedSnapshot.manifest.payloadParts.map(\.partID)), ["audio", "location"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: mixedDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.screenURL(in: mixedDirectory).path))

        let screenOnlySegmentID = UUID()
        try self.writeScreencastBundle(store: harness.store, segmentID: screenOnlySegmentID, lifecycle: .pending)
        await harness.mobileSegmentUploader.redactScreencastFacet(segmentID: screenOnlySegmentID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: screenOnlySegmentID).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: harness.store.tombstoneDirectory(kind: "empty")
                .appendingPathComponent("\(screenOnlySegmentID.uuidString).json", isDirectory: false)
                .path
        ))
    }

    func testLocationRedactionPreservesFinalizedScreencastAndRebuildsUpload() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeMixedBundle(store: harness.store, segmentID: segmentID, lifecycle: .pending)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)

        await harness.mobileSegmentUploader.redactLocationFacet(segmentID: segmentID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
        XCTAssertEqual(harness.mobileSegmentUploader.pendingCount, 0)
        XCTAssertEqual(harness.mobileSegmentUploader.failedCount, 0)

        let snapshots = await harness.transferEngine.itemSnapshots(sourceKey: ObserverAudioTransferSource.mobileSegment)
        let snapshot = try XCTUnwrap(
            snapshots.first { $0.manifest.observerIngest?.segmentID == segmentID }
        )
        XCTAssertEqual(Set(snapshot.manifest.payloadParts.map(\.partID)), ["audio", "screencast"])
        XCTAssertEqual(snapshot.manifest.observerIngest?.sources.sorted(), ["audio", "screencast"])
    }
}

private extension MobileSegmentOwnerSurfaceTests {
    struct Harness {
        let mobileSegmentUploader: MobileSegmentUploader
        let mobileSegmentHolder: MobileSegmentTransferHolder
        let store: MobileSegmentStore
        let importQueue: ImportQueue
        let transferEngine: TransferEngine
        let omiHolder: OmiUploaderHolder
        let watchHolder: WatchUploaderHolder
    }

    func makeHarness() -> Harness {
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        let transferHarness = makeTransferCutoverHarness(
            rootURL: self.tempDirectory.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        )
        let mobileSegmentUploader = MobileSegmentUploader(
            transferEngine: transferHarness.engine,
            store: store,
            clock: self.clock
        )
        let mobileSegmentHolder = MobileSegmentTransferHolder(
            transferEngine: transferHarness.engine,
            mirror: transferHarness.mirror,
            uploader: mobileSegmentUploader
        )
        return Harness(
            mobileSegmentUploader: mobileSegmentUploader,
            mobileSegmentHolder: mobileSegmentHolder,
            store: store,
            importQueue: ImportQueue(
                cacheRootURL: self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true),
                startPathMonitor: false
            ),
            transferEngine: transferHarness.engine,
            omiHolder: transferHarness.omi,
            watchHolder: transferHarness.watch
        )
    }

    func writeMixedBundle(store: MobileSegmentStore, segmentID: UUID, lifecycle: MobileSegmentLifecycle) throws {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio, .location, .screencast],
            activeSourceSetVersion: 1
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try store.createActive(manifest: manifest)
        try Data("audio".utf8).write(to: store.audioURL(in: directory), options: .atomic)
        try Data(#"{"schema":"solstone.location.segment/1","fix_count":1}"#.utf8).write(to: store.locationURL(in: directory), options: .atomic)
        try Data("screen".utf8).write(to: store.screenURL(in: directory), options: .atomic)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "audio.m4a",
                bytes: store.fileSize(at: store.audioURL(in: directory)),
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
        manifest = try store.readManifest(in: directory)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "location.jsonl",
                bytes: store.fileSize(at: store.locationURL(in: directory)),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60,
                fixCount: 1
            ),
            source: .location,
            manifest: &manifest,
            in: directory,
            now: endedAt
        )
        manifest = try store.readManifest(in: directory)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "screen.mp4",
                bytes: store.fileSize(at: store.screenURL(in: directory)),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60
            ),
            source: .screencast,
            manifest: &manifest,
            in: directory,
            now: endedAt
        )
        if lifecycle == .failed {
            try store.writeFailure(
                MobileSegmentFailureSidecar(
                    reason: "test failure",
                    httpStatus: nil,
                    transportError: nil,
                    attemptCount: 1,
                    stage: "source-finalize",
                    lastAttemptAt: endedAt
                ),
                in: directory
            )
        }
        _ = try store.move(segmentID: segmentID, from: .active, to: lifecycle)
    }

    func writeScreencastBundle(store: MobileSegmentStore, segmentID: UUID, lifecycle: MobileSegmentLifecycle) throws {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        manifest.day = "20260628"
        manifest.segment = "090000_60"
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try store.createActive(manifest: manifest)
        try Data("screen".utf8).write(to: store.screenURL(in: directory), options: .atomic)
        try store.writeOutcome(
            MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "screen.mp4",
                bytes: store.fileSize(at: store.screenURL(in: directory)),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60
            ),
            source: .screencast,
            manifest: &manifest,
            in: directory,
            now: endedAt
        )
        _ = try store.move(segmentID: segmentID, from: .active, to: lifecycle)
    }

    func createPublicFinalizedLocationScreencastSegment(
        uploader: MobileSegmentUploader
    ) async throws -> UUID {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        let segmentID = try uploader.openSegment(sources: [.location, .screencast], startedAt: startedAt, sourceSetVersion: 1)

        let fix = LocationFix(
            t: startedAt,
            lat: 0,
            lon: 0,
            hAcc: 1,
            alt: nil,
            vAcc: nil,
            speed: nil,
            course: nil,
            stationary: false
        )
        try uploader.recordLocationFinalized(
            segmentID: segmentID,
            batch: LocationSegmentBatch(
                tier: .balanced,
                accuracy: .full,
                segmentStart: startedAt,
                coveredSeconds: 60,
                fixes: [fix],
                visits: [],
                gap: false
            ),
            endedAt: endedAt,
            reason: nil
        )

        let screenURL = uploader.activeScreencastURL(segmentID: segmentID)
        try Data("fake-screen".utf8).write(to: screenURL, options: .atomic)
        try uploader.recordScreencastFinalized(
            segmentID: segmentID,
            artifactURL: screenURL,
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60
        )

        await uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: endedAt)
        return segmentID
    }

    func registration() -> ObserverRegistration {
        let registration = ObserverRegistration(
            hostname: "test-device",
            version: "0.1.0",
            streamType: "mobile",
            session: URLSession(configuration: .ephemeral),
            loadKey: { "test-observer-key-abc" },
            saveKey: { _ in },
            deleteKey: {},
            loadPrefix: { "obs_mobile_" },
            savePrefix: { _ in },
            deletePrefix: {}
        )
        registration.activeLocalPort = 7071
        return registration
    }

    func healthSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentOwnerHealthURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    func waitFor(_ label: String, timeout: Duration = .seconds(2), condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private extension OnThisPhoneSourceResult {
    var loadedItems: [OnThisPhoneItem] {
        if case .loaded(let items) = self {
            return items
        }
        return []
    }
}

private final class MobileSegmentOwnerHealthURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)
    private static let bodiesBox = OSAllocatedUnfairLock<[Data]>(initialState: [])

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var callCount: Int {
        self.callCountBox.withLock { $0 }
    }

    static var capturedBodies: [Data] {
        self.bodiesBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.callCountBox.withLock { $0 = 0 }
        self.bodiesBox.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        guard let handler = Self.handler else {
            XCTFail("MobileSegmentOwnerHealthURLProtocol handler not set")
            return
        }
        do {
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
