// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ObserverManagerTests: XCTestCase {
    @MainActor private lazy var recorder = MockObserverRecorder()
    @MainActor private lazy var clock = MockObserverClock()
    @MainActor private lazy var liveActivity = MockObserverLiveActivity()
    private lazy var tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverManagerTests-\(UUID().uuidString)", isDirectory: true)
    @MainActor private lazy var uploader: ObserverUploader = {
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverManagerURLProtocol.self]
        ObserverManagerURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        return ObserverUploader(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            localPortProvider: { 7071 },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
    }()
    @MainActor private lazy var manager = ObserverManager(
        recorder: self.recorder,
        uploader: self.uploader,
        clock: self.clock,
        liveActivity: self.liveActivity
    )

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        ObserverManagerURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testStartSessionTransitionsToActive() async {
        await self.manager.startSession(mode: .meeting)

        guard case .active(let session) = self.manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(session.mode, .meeting)
        XCTAssertEqual(session.currentChunkIndex, 0)
        XCTAssertEqual(self.recorder.startCallCount, 1)
    }

    @MainActor
    func testStopSessionWithNoLocalPortLeavesChunkPending() async throws {
        let registrationCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverManagerURLProtocol.self]
        let uploader = ObserverUploader(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: configuration,
            ensureRegistered: {
                registrationCalls.withLock { $0 += 1 }
                throw ObserverUploaderError.registrationUnavailable
            },
            isJournalConfigured: { true },
            localPortProvider: { nil },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
        let manager = ObserverManager(
            recorder: self.recorder,
            uploader: uploader,
            clock: self.clock,
            liveActivity: self.liveActivity
        )

        await manager.startSession(mode: .meeting)
        await manager.stopSession()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(registrationCalls.withLock { $0 }, 0)
        XCTAssertEqual(try self.pendingFileCount(pathExtension: "m4a"), 1)
        XCTAssertEqual(try self.pendingFileCount(pathExtension: "json"), 1)
    }

    @MainActor
    func testStopSessionEndsLiveActivityWhenChunkFinalizes() async {
        await self.manager.startSession(mode: .meeting)
        self.clock.advance(by: 42)

        await self.manager.stopSession()

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.liveActivity.endCalls.first?.0, .meeting)
        XCTAssertEqual(self.liveActivity.endCalls.first?.1 ?? 0, 42, accuracy: 0.001)
    }

    @MainActor
    func testStopSessionEndsLiveActivityWhenNoChunkFinalizes() async {
        await self.manager.startSession(mode: .meeting)
        self.recorder.currentURL = nil

        await self.manager.stopSession()

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.uploader.pendingCount, 0)
    }

    @MainActor
    func testEmptyChunkOnStopSessionIsSkippedAndCleanedUp() async throws {
        await self.manager.startSession(mode: .meeting)
        let inProgressDirectory = try XCTUnwrap(self.recorder.lastStartURL?.deletingLastPathComponent())
        self.recorder.nextChunkDuration = 0

        await self.manager.stopSession()

        XCTAssertEqual(self.uploader.pendingCount, 0)
        XCTAssertEqual(try self.pendingFileCount(pathExtension: "m4a"), 0)
        XCTAssertTrue(try self.m4aFiles(in: inProgressDirectory).isEmpty)
    }

    @MainActor
    func testStopSessionEndsLiveActivityWhenRecorderStopThrows() async {
        await self.manager.startSession(mode: .meeting)
        self.recorder.stopError = ObserverManagerTestError.stopFailed

        await self.manager.stopSession()

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.uploader.pendingCount, 0)
    }

    @MainActor
    func testPermissionDeniedTransitionsToError() async {
        self.recorder.permissionGranted = false

        await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(self.manager.state, .error(.permissionDenied))
    }

    @MainActor
    func testClockDrivenSegmentationRotatesChunk() async {
        await self.manager.startSession(mode: .meeting)
        try? await Task.sleep(for: .milliseconds(20))

        self.clock.advance(by: 300)
        try? await Task.sleep(for: .milliseconds(40))

        guard case .active(let session) = self.manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(session.currentChunkIndex, 1)
        XCTAssertEqual(self.recorder.rotateCallCount, 1)
    }

    @MainActor
    func testEmptyChunkOnRotationIsSkippedAndCleanedUp() async throws {
        await self.manager.startSession(mode: .meeting)
        let inProgressDirectory = try XCTUnwrap(self.recorder.lastStartURL?.deletingLastPathComponent())
        self.recorder.nextChunkDuration = 0
        try? await Task.sleep(for: .milliseconds(20))

        self.clock.advance(by: 300)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.recorder.rotateCallCount, 1)
        XCTAssertEqual(self.uploader.pendingCount, 0)
        XCTAssertEqual(try self.pendingFileCount(pathExtension: "m4a"), 0)

        await self.manager.stopSession()
        XCTAssertTrue(try self.m4aFiles(in: inProgressDirectory).isEmpty)
    }

    @MainActor
    func testAboveThresholdChunkIsEnqueued() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ObserverManagerURLProtocol.self]
        let uploader = ObserverUploader(
            cacheRootURL: self.tempDirectory,
            sessionConfiguration: configuration,
            ensureRegistered: { "test-observer-key-abc" },
            isJournalConfigured: { true },
            localPortProvider: { nil },
            retryDelays: [0],
            sleep: { _ in },
            startPathMonitor: false
        )
        let manager = ObserverManager(
            recorder: self.recorder,
            uploader: uploader,
            clock: self.clock,
            liveActivity: self.liveActivity
        )
        self.recorder.nextChunkDuration = 5

        await manager.startSession(mode: .meeting)
        await manager.stopSession()

        XCTAssertEqual(uploader.pendingCount, 1)
        XCTAssertEqual(try self.pendingFileCount(pathExtension: "m4a"), 1)
    }

    @MainActor
    func testVoiceMemoSilenceStopsSession() async {
        await self.manager.startSession(mode: .voiceMemo)

        self.recorder.emitMeter(level: -55, duration: 0.5)
        self.recorder.emitMeter(level: -55, duration: 3.6)
        try? await Task.sleep(for: .milliseconds(20))

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.recorder.stopCallCount, 1)
    }

    @MainActor
    func testMeetingModeIgnoresSilence() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitMeter(level: -55, duration: 4)
        try? await Task.sleep(for: .milliseconds(20))

        if case .active = self.manager.state {
        } else {
            XCTFail("Expected active state")
        }
    }

    @MainActor
    func testShortInterruptionResumes() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        try? await Task.sleep(for: .milliseconds(20))
        self.clock.advance(by: 30)
        self.recorder.emitInterruption(.ended)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.recorder.pauseCallCount, 1)
        XCTAssertEqual(self.recorder.resumeCallCount, 1)
        if case .active = self.manager.state {
        } else {
            XCTFail("Expected active state")
        }
    }

    @MainActor
    func testLongInterruptionStopsWithConflictError() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        try? await Task.sleep(for: .milliseconds(20))
        self.clock.advance(by: 61)
        self.recorder.emitInterruption(.ended)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
    }

    @MainActor
    func testTapToCancelDuringStarting() async {
        self.recorder.permissionDelay = .milliseconds(100)
        let task = Task {
            await self.manager.startSession(mode: .meeting)
        }

        try? await Task.sleep(for: .milliseconds(20))
        await self.manager.stopSession()
        await task.value

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertTrue(self.liveActivity.endCalls.isEmpty)
        XCTAssertEqual(self.liveActivity.endAllCallCount, 0)
    }

    @MainActor
    func testEndStaleObserverActivitiesEndsAllObserverActivities() async {
        // Structural location safety is in the implementation: endAll enumerates only ObserverActivityAttributes.
        await self.manager.endStaleObserverActivities()

        XCTAssertEqual(self.liveActivity.endAllCallCount, 1)
    }

    @MainActor
    func testStopSessionWhileIdleEndsStaleObserverActivities() async {
        await self.manager.stopSession()

        XCTAssertEqual(self.liveActivity.endAllCallCount, 1)
        XCTAssertTrue(self.liveActivity.endCalls.isEmpty)
    }

    @MainActor
    func testPersistEnrolledIfActiveWritesAudioEnrollment() async {
        let (defaults, suiteName) = self.makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await self.manager.startSession(mode: .meeting)
        self.manager.persistEnrolledIfActive(into: defaults)

        XCTAssertEqual(defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
    }

    @MainActor
    func testPersistEnrolledIfActiveDoesNotWriteForUnavailableOrPermissionDenied() async {
        let (defaults, suiteName) = self.makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        self.recorder.permissionGranted = false
        await self.manager.startSession(mode: .meeting)
        XCTAssertEqual(self.manager.state, .error(.permissionDenied))
        self.manager.persistEnrolledIfActive(into: defaults)
        XCTAssertNil(defaults.object(forKey: AudioStorageKey.enrolled))

        self.recorder.permissionGranted = true
        self.recorder.startError = ObserverManagerTestError.startFailed
        await self.manager.startSession(mode: .meeting)
        guard case .error(.unavailable) = self.manager.state else {
            return XCTFail("Expected unavailable error")
        }
        self.manager.persistEnrolledIfActive(into: defaults)
        XCTAssertNil(defaults.object(forKey: AudioStorageKey.enrolled))
    }

    @MainActor
    func testStartSessionPreservesThrownObserverError() async {
        self.recorder.startError = ObserverError.unavailable(reason: "audio input unavailable")

        await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(self.manager.state, .error(.unavailable(reason: "audio input unavailable")))
    }

    @MainActor
    func testAudioEnrollmentStateIgnoresLiveActivityOutcome() async {
        let (defaults, suiteName) = self.makeEphemeralDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        await self.manager.startSession(mode: .meeting)
        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }

        // MockObserverLiveActivity does no real ActivityKit work; manager state never depends on live-activity results.
        self.manager.persistEnrolledIfActive(into: defaults)
        await self.manager.stopSession()

        XCTAssertEqual(defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
        XCTAssertEqual(self.manager.state, .idle)
    }

    @MainActor
    func testStartSessionIsIdempotentWhenAlreadyActive() async {
        await self.manager.startSession(mode: .meeting)
        await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(self.recorder.startCallCount, 1)
    }
}

private enum ObserverManagerTestError: Error {
    case startFailed
    case stopFailed
}

private final class ObserverManagerURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let handlerBox = OSAllocatedUnfairLock<Handler?>(initialState: nil)
    static var handler: Handler? {
        get { self.handlerBox.withLock { $0 } }
        set { self.handlerBox.withLock { $0 = newValue } }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            XCTFail("ObserverManagerURLProtocol handler not set")
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

private extension ObserverManagerTests {
    func makeEphemeralDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "ObserverManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    func pendingFileCount(pathExtension: String) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(at: self.tempDirectory, includingPropertiesForKeys: nil) else {
            return 0
        }

        var count = 0
        for case let url as URL in enumerator {
            if url.pathExtension == pathExtension,
               url.deletingLastPathComponent().lastPathComponent == "pending"
            {
                count += 1
            }
        }
        return count
    }

    func m4aFiles(in directory: URL?) throws -> [URL] {
        guard let directory,
              FileManager.default.fileExists(atPath: directory.path)
        else {
            return []
        }

        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "m4a" }
    }
}
