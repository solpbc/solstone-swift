// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

@MainActor
final class MobileSegmentReconcileTests: XCTestCase {
    private var tempDirectory: URL!
    private var clock: MockObserverClock!

    override func setUp() {
        super.setUp()
        MobileSegmentReconcileURLProtocol.reset()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSegmentReconcileTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        self.clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_780_480_800))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        self.clock = nil
        MobileSegmentReconcileURLProtocol.reset()
        super.tearDown()
    }

    func testResumeReconcilesActiveDirectoriesDeterministicallyWithoutDuplicateUpload() async throws {
        let harness = self.makeHarness()
        let finalizedWithFile = UUID()
        let finalizedMissingFile = UUID()
        let noArtifact = UUID()
        let unresolvedNoMarker = UUID()
        let uncleanAudio = UUID()

        try self.writeActiveAudio(segmentID: finalizedWithFile, store: harness.store, state: .finalizedArtifact, includeFile: true)
        try self.writeActiveAudio(segmentID: finalizedMissingFile, store: harness.store, state: .finalizedArtifact, includeFile: false)
        try self.writeActiveAudio(segmentID: noArtifact, store: harness.store, state: .noArtifact, includeFile: false)
        try self.writeActiveAudio(segmentID: unresolvedNoMarker, store: harness.store, state: .unresolved, includeFile: false)
        try self.writeActiveAudio(segmentID: uncleanAudio, store: harness.store, state: .unresolved, includeFile: true)
        MobileSegmentReconcileURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }

        await harness.uploader.resumeFromDisk()
        try await self.waitFor("first reconcile uploads") {
            MobileSegmentReconcileURLProtocol.callCount == 2
        }
        await harness.uploader.resumeFromDisk()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: finalizedWithFile).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: uncleanAudio).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: finalizedMissingFile).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: unresolvedNoMarker).path))
        XCTAssertEqual(try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.failed, segmentID: unresolvedNoMarker)).audio.state, .failedToFinalize)
        XCTAssertEqual(try harness.store.readManifest(in: harness.store.segmentDirectoryURL(.failed, segmentID: finalizedMissingFile)).audio.state, .finalizedArtifact)
        XCTAssertEqual(try harness.store.list(.active).count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.tombstoneDirectory(kind: "empty").appendingPathComponent("\(noArtifact.uuidString).json").path))
    }
}

private extension MobileSegmentReconcileTests {
    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
    }

    func makeHarness() -> Harness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentReconcileURLProtocol.self]
        let transport = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("transport", isDirectory: true),
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            isJournalConfigured: { true },
            localPortProvider: { 7071 },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
        let store = MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true))
        return Harness(
            uploader: MobileSegmentUploader(transport: transport, store: store, clock: self.clock),
            store: store
        )
    }

    func writeActiveAudio(segmentID: UUID, store: MobileSegmentStore, state: MobileSegmentResolutionState, includeFile: Bool) throws {
        let startedAt = self.clock.now().addingTimeInterval(-300)
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.audio],
            activeSourceSetVersion: 1
        )
        let directory = try store.createActive(manifest: manifest)
        if includeFile {
            try Data("audio-\(segmentID.uuidString)".utf8).write(to: store.audioURL(in: directory), options: .atomic)
        }
        switch state {
        case .finalizedArtifact:
            let resolution = MobileSegmentSourceResolution(
                state: .finalizedArtifact,
                artifactFilename: "audio.m4a",
                bytes: includeFile ? store.fileSize(at: store.audioURL(in: directory)) : 12,
                startedAt: startedAt,
                endedAt: self.clock.now(),
                durationS: 300,
                mode: .meeting
            )
            try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: self.clock.now())
        case .noArtifact:
            let resolution = MobileSegmentSourceResolution(
                state: .noArtifact,
                startedAt: startedAt,
                endedAt: self.clock.now(),
                durationS: 300,
                reason: "test_no_artifact",
                mode: .meeting
            )
            try store.writeOutcome(resolution, source: .audio, manifest: &manifest, in: directory, now: self.clock.now())
        case .unresolved:
            break
        case .notDeclared, .failedToFinalize, .removed:
            XCTFail("Unsupported reconcile fixture state")
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
}

private final class MobileSegmentReconcileURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    private static let callCountBox = OSAllocatedUnfairLock<Int>(initialState: 0)

    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    static var callCount: Int {
        self.callCountBox.withLock { $0 }
    }

    static func reset() {
        self.handler = nil
        self.callCountBox.withLock { $0 = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.callCountBox.withLock { $0 += 1 }
        guard let handler = Self.handler else {
            XCTFail("MobileSegmentReconcileURLProtocol handler not set")
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
}
