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
        harness.mobileSegmentUploader.refreshCounts()

        let snapshot = OnThisPhoneSnapshotAggregator.snapshot(
            importQueue: harness.importQueue,
            mobileSegmentUploader: harness.mobileSegmentUploader,
            omiUploader: harness.omiUploader,
            watchUploader: harness.watchUploader
        )
        let facets = snapshot.items.filter { $0.dropGroupID == "mobile-segment:\(segmentID.uuidString)" }
        XCTAssertEqual(facets.count, 3)
        XCTAssertEqual(Set(facets.map(\.sourceKind)), [.audio, .location, .screencast])
        XCTAssertEqual(harness.mobileSegmentUploader.pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentUploader.summary(for: .audio).pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentUploader.summary(for: .location).pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentUploader.summary(for: .screencast).pendingCount, 1)

        let totals = uploadTotals(
            mobileSegment: harness.mobileSegmentUploader,
            omi: OmiUploaderHolder(harness.omiUploader),
            watch: WatchUploaderHolder(harness.watchUploader),
            importQueue: harness.importQueue
        )
        XCTAssertEqual(totals.pending, 1)

        let registration = self.registration()
        let beacon = ObserverHealthBeacon(
            registration: registration,
            uploader: harness.mobileSegmentUploader,
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

        let item = try XCTUnwrap(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .audio).loadedItems.first)
        let commit = try XCTUnwrap(makeDropCommit(
            for: item,
            importQueue: harness.importQueue,
            observerUploader: harness.observerUploader,
            omiUploader: harness.omiUploader,
            watchUploader: harness.watchUploader,
            mobileSegmentUploader: harness.mobileSegmentUploader
        ))
        commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: pendingSegmentID).path))
        XCTAssertTrue(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .audio).loadedItems.isEmpty)
        XCTAssertTrue(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .location).loadedItems.isEmpty)
        XCTAssertTrue(harness.mobileSegmentUploader.onThisPhoneSnapshot(for: .screencast).loadedItems.isEmpty)

        let failedSegmentID = UUID()
        try self.writeMixedBundle(store: harness.store, segmentID: failedSegmentID, lifecycle: .failed)
        harness.mobileSegmentUploader.refreshCounts()
        await harness.mobileSegmentUploader.retryFailed()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: failedSegmentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: pendingDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenURL(in: pendingDirectory).path))
        XCTAssertEqual(harness.mobileSegmentUploader.pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentUploader.failedCount, 0)
    }

    func testScreencastRedactionPreservesRemainingFacetsAndTombstonesScreencastOnlyBundle() async throws {
        let harness = self.makeHarness()
        let mixedSegmentID = UUID()
        try self.writeMixedBundle(store: harness.store, segmentID: mixedSegmentID, lifecycle: .pending)

        await harness.mobileSegmentUploader.redactScreencastFacet(segmentID: mixedSegmentID)

        let mixedDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: mixedSegmentID)
        let mixedManifest = try harness.store.readManifest(in: mixedDirectory)
        XCTAssertEqual(mixedManifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(mixedManifest.location.state, .finalizedArtifact)
        XCTAssertEqual(mixedManifest.screencast.state, .removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.screenURL(in: mixedDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: mixedDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: mixedDirectory).path))

        let requestBodyURL = self.tempDirectory
            .appendingPathComponent("observer", isDirectory: true)
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(mixedSegmentID.uuidString).upload", isDirectory: false)
        let requestBody = try String(contentsOf: requestBodyURL, encoding: .utf8)
        XCTAssertTrue(requestBody.contains("filename=\"audio.m4a\""))
        XCTAssertTrue(requestBody.contains("filename=\"location.jsonl\""))
        XCTAssertFalse(requestBody.contains("filename=\"screen.mp4\""))

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
        let segmentID = try await self.createPublicFinalizedLocationScreencastSegment(
            uploader: harness.mobileSegmentUploader
        )
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)

        await harness.mobileSegmentUploader.redactLocationFacet(segmentID: segmentID)
        await harness.mobileSegmentUploader.resumeFromDisk()

        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
        XCTAssertEqual(harness.mobileSegmentUploader.pendingCount, 1)
        XCTAssertEqual(harness.mobileSegmentUploader.failedCount, 0)

        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .notDeclared)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertEqual(manifest.screencast.state, .finalizedArtifact)

        let requestBody = try Data(contentsOf: self.requestBodyURL(for: segmentID))
        let requestBodyString = String(decoding: requestBody, as: UTF8.self)
        XCTAssertTrue(requestBodyString.contains(#"filename="screen.mp4""#))
        XCTAssertFalse(requestBodyString.contains(#"filename="location.jsonl""#))
        XCTAssertEqual((try self.multipartMeta(in: requestBody)["sources"] as? [String])?.sorted(), ["screencast"])
    }
}

private extension MobileSegmentOwnerSurfaceTests {
    struct Harness {
        let observerUploader: ObserverUploader
        let mobileSegmentUploader: MobileSegmentUploader
        let store: MobileSegmentStore
        let importQueue: ImportQueue
        let omiUploader: ObserverUploader
        let watchUploader: ObserverUploader
    }

    func makeHarness() -> Harness {
        let observerUploader = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("observer", isDirectory: true),
            isJournalConfigured: { false },
            localPortProvider: { nil },
            startPathMonitor: false
        )
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        return Harness(
            observerUploader: observerUploader,
            mobileSegmentUploader: MobileSegmentUploader(transport: observerUploader, store: store, clock: self.clock),
            store: store,
            importQueue: ImportQueue(
                cacheRootURL: self.tempDirectory.appendingPathComponent("ImportQueue", isDirectory: true),
                startPathMonitor: false
            ),
            omiUploader: ObserverUploader(
                cacheRootURL: self.tempDirectory.appendingPathComponent("OmiObserver", isDirectory: true),
                sourceType: "omi-audio",
                startPathMonitor: false
            ),
            watchUploader: ObserverUploader(
                cacheRootURL: self.tempDirectory.appendingPathComponent("WatchObserver", isDirectory: true),
                sourceType: "watch-audio",
                startPathMonitor: false
            )
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
                    stage: "test",
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
            endedAt: endedAt
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

    func requestBodyURL(for segmentID: UUID) -> URL {
        self.tempDirectory
            .appendingPathComponent("observer", isDirectory: true)
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
    }

    func multipartValue(named name: String, in body: Data) -> String? {
        let string = String(decoding: body, as: UTF8.self)
        guard let headerRange = string.range(of: #"Content-Disposition: form-data; name="\#(name)""#),
              let separator = string[headerRange.upperBound...].range(of: "\r\n\r\n")
        else { return nil }
        let valueStart = separator.upperBound
        guard let valueEnd = string[valueStart...].range(of: "\r\n--")?.lowerBound else { return nil }
        return String(string[valueStart..<valueEnd])
    }

    func multipartMeta(in body: Data) throws -> [String: Any] {
        let meta = try XCTUnwrap(self.multipartValue(named: "meta", in: body))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any])
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
