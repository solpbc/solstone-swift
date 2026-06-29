// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentUploaderTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        MobileSegmentUploaderURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentUploaderTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        MobileSegmentUploaderURLProtocol.reset()
        super.tearDown()
    }

    func testMixedSegmentUploadsOneMultipartWithAudioAndLocationFiles() async throws {
        let harness = self.makeHarness(connected: true)
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio, .location])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("mixed multipart upload") {
            MobileSegmentUploaderURLProtocol.callCount == 1
        }

        let body = try XCTUnwrap(MobileSegmentUploaderURLProtocol.capturedBodies.first)
        XCTAssertEqual(self.multipartValue(named: "platform", in: body), "ios")
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#"name="files"; filename="audio.m4a""#))
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains(#"name="files"; filename="location.jsonl""#))
        XCTAssertEqual((try self.multipartMeta(in: body)["sources"] as? [String])?.sorted(), ["audio", "location"])
    }

    func testSingleSourceSegmentsUploadOnlyTheirOwnArtifact() async throws {
        let harness = self.makeHarness(connected: true)
        let audioSegmentID = UUID()
        let locationSegmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: audioSegmentID, store: harness.store, sources: [.audio])
        _ = try self.createFinalizedActiveSegment(segmentID: locationSegmentID, store: harness.store, sources: [.location])
        _ = try harness.store.move(segmentID: audioSegmentID, from: .active, to: .pending)
        _ = try harness.store.move(segmentID: locationSegmentID, from: .active, to: .pending)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("single-source multipart uploads") {
            MobileSegmentUploaderURLProtocol.callCount == 2
        }

        let bodies = MobileSegmentUploaderURLProtocol.capturedBodies.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(bodies.filter { $0.contains(#"filename="audio.m4a""#) && !$0.contains(#"filename="location.jsonl""#) }.count, 1)
        XCTAssertEqual(bodies.filter { !$0.contains(#"filename="audio.m4a""#) && $0.contains(#"filename="location.jsonl""#) }.count, 1)
    }

    func testFailedMixedUploadKeepsArtifactsAndRetryResendsBothParts() async throws {
        let harness = self.makeHarness(connected: true, maxAttempts: 2)
        let segmentID = UUID()
        _ = try self.createFinalizedActiveSegment(segmentID: segmentID, store: harness.store, sources: [.audio, .location])
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)
        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                Data("try later".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("mixed upload exhaustion") {
            harness.uploader.failedCount == 1 && MobileSegmentUploaderURLProtocol.callCount == 2
        }

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: failedDirectory).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.locationURL(in: failedDirectory).path))
        XCTAssertNotNil(harness.store.loadFailure(in: failedDirectory))
        _ = try harness.store.readManifest(in: failedDirectory)

        MobileSegmentUploaderURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        await harness.uploader.retryFailed()
        try await self.waitFor("mixed retry upload") {
            MobileSegmentUploaderURLProtocol.callCount == 3
        }

        let retryBody = String(decoding: try XCTUnwrap(MobileSegmentUploaderURLProtocol.capturedBodies.last), as: UTF8.self)
        XCTAssertTrue(retryBody.contains(#"filename="audio.m4a""#))
        XCTAssertTrue(retryBody.contains(#"filename="location.jsonl""#))
    }

    func testResumeFailsPendingBundleWithUnresolvedDeclaredSourceBeforeUpload() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        let activeDirectory = try self.createMixedActiveSegment(
            segmentID: segmentID,
            store: harness.store,
            locationResolution: nil
        )
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .pending)

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pendingDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedDirectory.path))

        let manifest = try harness.store.readManifest(in: failedDirectory)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.state, .failedToFinalize)
        XCTAssertEqual(manifest.location.reason, "missing terminal outcome marker")
        XCTAssertEqual(harness.uploader.failedCount, 1)

        let requestBodyURL = harness.transportRoot
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestBodyURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: activeDirectory.path))
    }

    func testDeleteLocationLocalStateRedactsFailedLocationAndPreservesAudioUpload() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        _ = try self.createMixedActiveSegment(
            segmentID: segmentID,
            store: harness.store,
            locationResolution: MobileSegmentSourceResolution(
                state: .failedToFinalize,
                reason: "location finalize failed",
                stage: "source-finalize",
                lastAttemptAt: self.clock.now()
            )
        )
        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        try harness.store.writeFailure(
            MobileSegmentFailureSidecar(
                reason: "source artifact failed to finalize",
                httpStatus: nil,
                transportError: nil,
                attemptCount: 0,
                stage: "source-finalize",
                lastAttemptAt: self.clock.now()
            ),
            in: activeDirectory
        )
        _ = try harness.store.move(segmentID: segmentID, from: .active, to: .failed)

        await harness.uploader.deleteLocationLocalState()

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingDirectory.path))

        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.audio.state, .finalizedArtifact)
        XCTAssertEqual(manifest.location.state, .removed)
        XCTAssertEqual(manifest.location.reason, "location_removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.audioURL(in: pendingDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.locationURL(in: pendingDirectory).path))

        let requestBodyURL = harness.transportRoot
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
            .appendingPathComponent("\(segmentID.uuidString).upload", isDirectory: false)
        let requestBody = try String(contentsOf: requestBodyURL, encoding: .utf8)
        XCTAssertTrue(requestBody.contains("filename=\"audio.m4a\""))
        XCTAssertFalse(requestBody.contains("filename=\"location.jsonl\""))
    }
}

private extension MobileSegmentUploaderTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
        let transportRoot: URL
    }

    func makeHarness(connected: Bool = false, maxAttempts: Int = 5) -> Harness {
        let transportRoot = self.tempDirectory.appendingPathComponent("transport", isDirectory: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentUploaderURLProtocol.self]
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

    func createMixedActiveSegment(
        segmentID: UUID,
        store: MobileSegmentStore,
        locationResolution: MobileSegmentSourceResolution?
    ) throws -> URL {
        let startedAt = self.clock.now()
        let endedAt = startedAt.addingTimeInterval(60)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio, .location],
            activeSourceSetVersion: 1
        )
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending

        let directory = try store.createActive(manifest: manifest)
        try Data("fake-audio".utf8).write(to: store.audioURL(in: directory), options: .atomic)
        let audioResolution = MobileSegmentSourceResolution(
            state: .finalizedArtifact,
            artifactFilename: "audio.m4a",
            bytes: store.fileSize(at: store.audioURL(in: directory)),
            startedAt: startedAt,
            endedAt: endedAt,
            durationS: 60,
            mode: .meeting
        )
        try store.writeOutcome(audioResolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
        manifest = try store.readManifest(in: directory)

        if let locationResolution {
            try store.writeOutcome(locationResolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
        }

        manifest = try store.readManifest(in: directory)
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending
        try store.writeManifest(manifest, in: directory)
        return directory
    }

    func createFinalizedActiveSegment(
        segmentID: UUID,
        store: MobileSegmentStore,
        sources: Set<MobileSegmentSource>
    ) throws -> URL {
        let startedAt = self.clock.now()
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
        manifest.upload = .pending
        let directory = try store.createActive(manifest: manifest)

        if sources.contains(.audio) {
            let audioURL = store.audioURL(in: directory)
            try Data("fake-audio".utf8).write(to: audioURL, options: .atomic)
            let audioResolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "audio.m4a",
                bytes: store.fileSize(at: audioURL),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60,
                mode: .meeting
            )
            try store.writeOutcome(audioResolution, source: .audio, manifest: &manifest, in: directory, now: endedAt)
            manifest = try store.readManifest(in: directory)
        }

        if sources.contains(.location) {
            let locationURL = store.locationURL(in: directory)
            try Data(#"{"schema":"solstone.location.segment/1","fix_count":1}"#.utf8)
                .write(to: locationURL, options: .atomic)
            let locationResolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "location.jsonl",
                bytes: store.fileSize(at: locationURL),
                startedAt: startedAt,
                endedAt: endedAt,
                durationS: 60,
                fixCount: 1
            )
            try store.writeOutcome(locationResolution, source: .location, manifest: &manifest, in: directory, now: endedAt)
        }

        manifest = try store.readManifest(in: directory)
        manifest.day = Self.dayString(for: startedAt)
        manifest.segment = ChunkSidecar.segmentString(for: startedAt, durationSeconds: 60)
        manifest.endedAt = endedAt
        manifest.durationS = 60
        manifest.upload = .pending
        try store.writeManifest(manifest, in: directory)
        return directory
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

    static func dayString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }
}

private final class MobileSegmentUploaderURLProtocol: URLProtocol, @unchecked Sendable {
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
        XCTAssertEqual(self.request.value(forHTTPHeaderField: "Authorization"), "Bearer test-observer-key-abc")
        Self.callCountBox.withLock { $0 += 1 }
        Self.bodiesBox.withLock { $0.append(Self.bodyData(from: self.request)) }
        guard let handler = Self.handler else {
            XCTFail("MobileSegmentUploaderURLProtocol handler not set")
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
