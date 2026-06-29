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

    func testResumeReconcilesUnresolvedScreencastWithScreenFileToPendingBundle() async throws {
        let harness = self.makeHarness(connected: false)
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .screen)

        await harness.uploader.resumeFromDisk()

        let pendingDirectory = harness.store.segmentDirectoryURL(.pending, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: pendingDirectory)
        XCTAssertEqual(manifest.screencast.state, .finalizedArtifact)
        XCTAssertEqual(manifest.screencast.artifactFilename, "screen.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenURL(in: pendingDirectory).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testResumeReconcilesScreencastPartOnlyToFinalizeFailureWithoutUpload() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)

        await harness.uploader.resumeFromDisk()

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: failedDirectory)
        XCTAssertEqual(manifest.screencast.state, .failedToFinalize)
        XCTAssertEqual(manifest.screencast.reason, "screencast_partial_artifact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testFreshLiveScreencastPartIsNotFailed() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.resumeFromDisk()

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.screencast.state, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenPartURL(in: activeDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testStaleScreencastPartFails() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-11)
        )

        await harness.uploader.resumeFromDisk()

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: failedDirectory)
        XCTAssertEqual(manifest.screencast.state, .failedToFinalize)
        XCTAssertEqual(manifest.screencast.reason, "screencast_partial_artifact")
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testFinalizeActiveSegmentDefersFreshLiveScreencastPart() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.screencast.state, .unresolved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.store.screenPartURL(in: activeDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: segmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
    }

    func testFinalizeActiveSegmentFailsStaleScreencastPart() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(
            segmentID: segmentID,
            store: harness.store,
            lastSeenAt: self.clock.now().addingTimeInterval(-11)
        )

        await harness.uploader.finalizeActiveSegment(segmentID: segmentID, endedAt: self.clock.now())

        let failedDirectory = harness.store.segmentDirectoryURL(.failed, segmentID: segmentID)
        let manifest = try harness.store.readManifest(in: failedDirectory)
        XCTAssertEqual(manifest.screencast.state, .failedToFinalize)
        XCTAssertEqual(manifest.screencast.reason, "screencast_partial_artifact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.active, segmentID: segmentID).path))
    }

    func testDeclaredScreencastDoesNotUploadUntilTerminal() async throws {
        let harness = self.makeHarness(connected: true)
        let segmentID = UUID()
        try self.writeActiveScreencast(segmentID: segmentID, store: harness.store, artifact: .part)
        try self.writeScreencastLiveness(segmentID: segmentID, store: harness.store, lastSeenAt: self.clock.now())

        await harness.uploader.resumeFromDisk()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: segmentID)
        XCTAssertEqual(try harness.store.readManifest(in: activeDirectory).screencast.state, .unresolved)
    }

    func testResumeDefersValidLeasedNextScreencastSegment() async throws {
        let harness = self.makeHarness(connected: true)
        let fromSegmentID = UUID()
        let nextSegmentID = UUID()
        try self.writeActiveScreencast(segmentID: nextSegmentID, store: harness.store, artifact: .none)
        try self.writeContinuationLease(
            fromSegmentID: fromSegmentID,
            nextSegmentID: nextSegmentID,
            store: harness.store,
            expiresAt: self.clock.now().addingTimeInterval(30)
        )

        await harness.uploader.resumeFromDisk()

        let activeDirectory = harness.store.segmentDirectoryURL(.active, segmentID: nextSegmentID)
        let manifest = try harness.store.readManifest(in: activeDirectory)
        XCTAssertEqual(manifest.screencast.state, .unresolved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: nextSegmentID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.failed, segmentID: nextSegmentID).path))
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
    }

    func testResumeIgnoresUndeclaredStrayScreenFileAndReportsDiagnostic() async throws {
        let harness = self.makeHarness()
        let segmentID = UUID()
        var manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: self.clock.now().addingTimeInterval(-60),
            openedWithSources: [],
            activeSourceSetVersion: 1
        )
        let directory = try harness.store.createActive(manifest: manifest)
        try Data("stray-screen".utf8).write(to: harness.store.screenURL(in: directory), options: .atomic)
        manifest = try harness.store.readManifest(in: directory)
        XCTAssertEqual(manifest.screencast.state, .notDeclared)

        await harness.uploader.resumeFromDisk()

        XCTAssertEqual(harness.uploader.lastError, "ignored undeclared screencast artifact segment=\(segmentID.uuidString) source=screencast")
        XCTAssertEqual(MobileSegmentReconcileURLProtocol.callCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.store.segmentDirectoryURL(.pending, segmentID: segmentID).path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: harness.store.tombstoneDirectory(kind: "empty")
                .appendingPathComponent("\(segmentID.uuidString).json", isDirectory: false)
                .path
        ))
    }
}

private extension MobileSegmentReconcileTests {
    enum ScreencastArtifact {
        case screen
        case part
        case none
    }

    struct Harness {
        let uploader: MobileSegmentUploader
        let store: MobileSegmentStore
    }

    func makeHarness(connected: Bool = true) -> Harness {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MobileSegmentReconcileURLProtocol.self]
        let transport = ObserverUploader(
            cacheRootURL: self.tempDirectory.appendingPathComponent("transport", isDirectory: true),
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            isJournalConfigured: { connected },
            localPortProvider: { connected ? 7071 : nil },
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

    func writeActiveScreencast(segmentID: UUID, store: MobileSegmentStore, artifact: ScreencastArtifact) throws {
        let startedAt = self.clock.now().addingTimeInterval(-300)
        let manifest = MobileSegmentManifest(
            segmentID: segmentID,
            startedAt: startedAt,
            openedWithSources: [.screencast],
            activeSourceSetVersion: 1
        )
        let directory = try store.createActive(manifest: manifest)
        switch artifact {
        case .screen:
            try Data("screen-\(segmentID.uuidString)".utf8).write(to: store.screenURL(in: directory), options: .atomic)
        case .part:
            try Data("partial-\(segmentID.uuidString)".utf8).write(to: store.screenPartURL(in: directory), options: .atomic)
        case .none:
            break
        }
    }

    func writeScreencastLiveness(segmentID: UUID, store: MobileSegmentStore, lastSeenAt: Date) throws {
        let directory = store.segmentDirectoryURL(.active, segmentID: segmentID)
        let liveness = MobileSegmentScreencastSegmentLiveness(
            sessionID: UUID(),
            segmentID: segmentID,
            handoffRevision: 1,
            lastSeenAt: lastSeenAt,
            acceptedFrameCount: 1,
            droppedFrameCount: 0
        )
        try MobileSegmentScreencastJSONStore.write(
            liveness,
            to: MobileSegmentScreencastPaths.screenLivenessURL(inSegmentDirectory: directory)
        )
    }

    func writeContinuationLease(
        fromSegmentID: UUID,
        nextSegmentID: UUID,
        store: MobileSegmentStore,
        expiresAt: Date
    ) throws {
        let notBefore = self.clock.now().addingTimeInterval(-1)
        let lease = MobileSegmentScreencastContinuationLease(
            leaseID: UUID(),
            revision: 2,
            fromSegmentID: fromSegmentID,
            segmentID: nextSegmentID,
            sourceSetVersion: 2,
            sourceSet: [.audio, .location, .screencast],
            notBefore: notBefore,
            startsAt: notBefore,
            rolloverAfter: notBefore.addingTimeInterval(300),
            expiresAt: expiresAt,
            issuedAt: self.clock.now(),
            segmentDirectoryRelativePath: MobileSegmentScreencastPaths.activeSegmentRelativeDirectory(segmentID: nextSegmentID),
            screenPartRelativePath: MobileSegmentScreencastPaths.screenPartRelativePath(segmentID: nextSegmentID),
            screenFinalRelativePath: MobileSegmentScreencastPaths.screenRelativePath(segmentID: nextSegmentID)
        )
        try MobileSegmentScreencastJSONStore.write(
            lease,
            to: MobileSegmentScreencastPaths.url(
                root: store.rootURL.deletingLastPathComponent(),
                relativePath: MobileSegmentScreencastPaths.continuationLeaseRelativePath(fromSegmentID: fromSegmentID)
            )
        )
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
