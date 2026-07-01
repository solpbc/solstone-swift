// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentFinalizeResolverTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        MobileSegmentFinalizeResolverURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentFinalizeResolverTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        MobileSegmentFinalizeResolverURLProtocol.reset()
        super.tearDown()
    }

    func testFailedAudioSurvivorDeadLocationRequeuesAudioOnly() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertEqual(manifest.location.reason, "location_no_local_data")
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("audio survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }

        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }

    func testUnrecoverableLocationOnlyWritesLostDataEmptyTombstone() throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        let tombstone = try self.emptyTombstone(segmentID: segmentID, store: harness.store)
        XCTAssertEqual(tombstone.reason, "unrecoverable_lost_data")
        XCTAssertNotEqual(tombstone.reason, "no_artifacts")
    }

    func testFailedLiveLocationPartRecoversBeforeDiscarding() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location],
            startedAt: startedAt
        ) { directory, manifest, startedAt, endedAt in
            try self.liveLocation.writeLocationPart(
                segmentID: segmentID,
                store: harness.store,
                directory: directory,
                startedAt: startedAt,
                fixes: [self.liveLocation.locationFix(at: startedAt.addingTimeInterval(60))]
            )
            try self.liveLocation.writeLocationLiveness(
                segmentID: segmentID,
                store: harness.store,
                directory: directory,
                lastSeenAt: endedAt
            )
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationPartURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationLivenessURL(in: pendingDirectory).path))

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("recovered location delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["location"]))
    }

    func testScheduleUploadResolvesPendingFinalizeFailureInPlaceWithoutRecursing() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let pendingDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .pending,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        self.stubDelivered()

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("pending finalize-failure delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }

        XCTAssertEqual(MobileSegmentFinalizeResolverURLProtocol.callCount, 1)
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }

    func testFinalizeFailureResolverIsIdempotentAcrossRepeatedPilePasses() async throws {
        let harness = self.makeHarness()
        let survivorID = UUID()
        let retiredID = UUID()
        _ = try self.writeBundle(
            segmentID: survivorID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: retiredID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        self.stubDelivered()

        await harness.uploader.resolveFinalizeFailurePile()
        try await self.waitFor("first idempotence pass") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: survivorID).path)
        }
        XCTAssertNotNil(try self.emptyTombstone(segmentID: retiredID, store: harness.store))

        await harness.uploader.resolveFinalizeFailurePile()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(MobileSegmentFinalizeResolverURLProtocol.callCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: retiredID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: survivorID).path))
        XCTAssertEqual(try self.emptyTombstoneCount(store: harness.store), 1)
    }

    func testFinalizeFailurePileKeepsPoisonFailedAndStillDrainsRecoverableSegment() async throws {
        let harness = self.makeHarness()
        let poisonID = UUID()
        let recoverableID = UUID()
        let poisonDirectory = try self.writeBundle(
            segmentID: poisonID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try FileManager.default.createDirectory(at: harness.store.locationPartURL(in: directory), withIntermediateDirectories: true)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: recoverableID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        self.stubDelivered()

        await harness.uploader.retryFailed()
        try await self.waitFor("batch isolation survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: recoverableID).path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: poisonDirectory.path))
        let poisonManifest = try harness.store.readManifest(in: poisonDirectory)
        XCTAssertEqual(poisonManifest.location.state, .failedToFinalize)
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }

    func testRetryFailedStrictlyDecreasesRecoverableFinalizeFailurePile() async throws {
        let harness = self.makeHarness()
        let audioSurvivorID = UUID()
        let recoveredLocationID = UUID()
        let locationSurvivorID = UUID()
        _ = try self.writeBundle(
            segmentID: audioSurvivorID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: recoveredLocationID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.location]
        ) { directory, manifest, startedAt, endedAt in
            try self.liveLocation.writeLocationPart(
                segmentID: recoveredLocationID,
                store: harness.store,
                directory: directory,
                startedAt: startedAt,
                fixes: [self.liveLocation.locationFix(at: startedAt.addingTimeInterval(30))]
            )
            try self.writeFailedOutcome(source: .location, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        _ = try self.writeBundle(
            segmentID: locationSurvivorID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFinalizedLocation(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }
        let beforeCount = try harness.store.list(.failed).count
        self.stubDelivered()

        await harness.uploader.retryFailed()
        try await self.waitFor("strict count decrease deliveries") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 3
                && ((try? harness.store.list(.failed).count) ?? beforeCount) < beforeCount
        }

        let sourceSets = try MobileSegmentFinalizeResolverURLProtocol.receivedBodies.map { try self.sources(in: $0).sorted() }
        XCTAssertEqual(sourceSets.filter { $0 == ["audio"] }.count, 1)
        XCTAssertEqual(sourceSets.filter { $0 == ["location"] }.count, 2)
        XCTAssertEqual(try harness.store.list(.failed).count, 0)
    }

    func testFailedLocationSurvivorDeadAudioRequeuesLocationOnly() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .location]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFailedOutcome(source: .audio, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFinalizedLocation(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .removed)
        XCTAssertEqual(manifest.audio.reason, "audio_no_local_data")
        XCTAssertEqual(manifest.location.state, .finalizedArtifact)

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("location survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["location"]))
    }

    func testDeadScreencastFacetIsRemovedWithoutTombstoneWhileSurvivorRemains() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let failedDirectory = try self.writeBundle(
            segmentID: segmentID,
            store: harness.store,
            lifecycle: .failed,
            sources: [.audio, .screencast]
        ) { directory, manifest, startedAt, endedAt in
            try self.writeFinalizedAudio(store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
            try self.writeFailedOutcome(source: .screencast, store: harness.store, directory: directory, manifest: &manifest, startedAt: startedAt, endedAt: endedAt)
        }

        let result = try harness.uploader.resolveFinalizeFailure(segmentID: segmentID, directory: failedDirectory, lifecycle: .failed)

        XCTAssertEqual(result, .repend)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.screencast.state, .removed)
        XCTAssertEqual(manifest.screencast.reason, "screencast_removed")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: harness.store.tombstoneDirectory(kind: "empty")
                .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
                .path
        ))

        self.stubDelivered()
        await harness.uploader.resumeFromDisk()
        try await self.waitFor("screencast survivor delivery") {
            MobileSegmentFinalizeResolverURLProtocol.callCount == 1
                && !FileManager.default.fileExists(atPath: pendingDirectory.path)
        }
        XCTAssertEqual(try self.sources(in: try XCTUnwrap(MobileSegmentFinalizeResolverURLProtocol.receivedBodies.first)), Set(["audio"]))
    }
}

private extension MobileSegmentFinalizeResolverTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
        let transportRoot: URL
    }

    var liveLocation: MobileSegmentLiveLocationTestSupport {
        MobileSegmentLiveLocationTestSupport(clock: self.clock)
    }

    func makeHarness(connected: Bool = true, maxAttempts: Int = 1) -> Harness {
        let transportRoot = self.tempDirectory.appendingPathComponent("transport", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentFinalizeResolverURLProtocol.self]
        let transport = ObserverUploader(
            cacheRootURL: transportRoot,
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            isJournalConfigured: { connected },
            localPortProvider: { connected ? 7071 : nil },
            retryDelays: [0],
            maxAttempts: maxAttempts,
            sleep: { _ in },
            startPathMonitor: false
        )
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        return Harness(
            uploader: MobileSegmentUploader(transport: transport, store: store, clock: self.clock),
            store: store,
            transportRoot: transportRoot
        )
    }

    func writeBundle(
        segmentID: UUID,
        store: MobileSegmentStore,
        lifecycle: MobileSegmentLifecycle,
        sources: Set<MobileSegmentSource>,
        startedAt: Date? = nil,
        configure: (URL, inout MobileSegmentManifest, Date, Date) throws -> Void
    ) throws -> URL {
        let startedAt = startedAt ?? self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: sources,
            activeSourceSetVersion: 1
        )
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = lifecycle == .failed ? .failed : .pending
        let directory = try store.createActive(manifest: manifest)
        try configure(directory, &manifest, startedAt, endedAt)

        manifest = try store.readManifest(in: directory)
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = lifecycle == .failed ? .failed : .pending
        try store.writeManifest(manifest, in: directory)
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
        guard lifecycle != .active else { return directory }
        return try store.move(segmentID: segmentID, from: .active, to: lifecycle)
    }

    func writeFinalizedAudio(
        store: MobileSegmentStore,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let audioURL = store.audioURL(in: directory)
        try Data("audio-\(manifest.segmentID.uuidString)".utf8).write(to: audioURL, options: .atomic)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: store.fileSize(at: audioURL),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            mode: .meeting
        )
        try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
    }

    func writeFinalizedLocation(
        store: MobileSegmentStore,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let locationURL = store.locationURL(in: directory)
        try Data(#"{"fix_count":1,"kind":"location","schema":"solstone.location.segment/1"}"#.utf8)
            .write(to: locationURL, options: .atomic)
        let resolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "location.jsonl",
            bytes: store.fileSize(at: locationURL),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            fixCount: 1
        )
        try store.writeOutcome(resolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
    }

    func writeFailedOutcome(
        source: MobileSegmentSource,
        store: MobileSegmentStore,
        directory: URL,
        manifest: inout MobileSegmentManifest,
        startedAt: Date,
        endedAt: Date
    ) throws {
        let resolution = MobileSegmentSourceResolution(
            state: .failedToFinalize,
            startedAt: startedAt,
            endedAt: endedAt,
            reason: "\(source.rawValue)_finalize_failed",
            stage: "test",
            lastAttemptAt: endedAt
        )
        try store.writeOutcome(resolution, source: source, manifest: &manifest, in: directory, now: endedAt)
    }

    func stubDelivered() {
        MobileSegmentFinalizeResolverURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
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

    func sources(in body: Data) throws -> Set<String> {
        let meta = try XCTUnwrap(self.multipartMeta(in: body))
        let sources = try XCTUnwrap(meta["sources"] as? [String])
        return Set(sources)
    }

    func multipartMeta(in body: Data) throws -> [String: Any]? {
        guard let meta = self.multipartValue(named: "meta", in: body) else { return nil }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(meta.utf8)) as? [String: Any])
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

    func emptyTombstone(segmentID: UUID, store: MobileSegmentStore) throws -> MobileSegmentTombstone {
        let tombstoneURL = store.tombstoneDirectory(kind: "empty")
            .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileSegmentTombstone.self, from: Data(contentsOf: tombstoneURL))
    }

    func emptyTombstoneCount(store: MobileSegmentStore) throws -> Int {
        let directory = store.tombstoneDirectory(kind: "empty")
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.filter { $0.pathExtension == "json" }.count
    }

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

private final class MobileSegmentFinalizeResolverURLProtocol: URLProtocol, @unchecked Sendable {
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

    static var receivedBodies: [Data] {
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
        XCTAssertEqual(self.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-observer-key-abc")
        Self.callCountBox.withLock { $0 += 1 }
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        guard let handler = Self.handler else {
            XCTFail("MobileSegmentFinalizeResolverURLProtocol handler not set")
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
