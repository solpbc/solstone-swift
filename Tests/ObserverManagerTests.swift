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
    @MainActor private lazy var mobileSegmentUploader = MobileSegmentUploader(
        store: MobileSegmentStore(rootURL: self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)),
        clock: self.clock
    )
    @MainActor private lazy var mobileSegmentEngine = MobileSegmentEngine(
        uploader: self.mobileSegmentUploader,
        clock: self.clock
    )
    @MainActor private lazy var manager = ObserverManager(
        recorder: self.recorder,
        mobileSegmentEngine: self.mobileSegmentEngine,
        clock: self.clock,
        liveActivity: self.liveActivity
    )

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.tempDirectory)
        ObserverManagerURLProtocol.handler = nil
        super.tearDown()
    }

    @MainActor
    func testSegmentStringUsesLocalTimeAndRoundedPositiveDuration() throws {
        let date = try self.fixedLocalDate(hour: 10, minute: 43, second: 55)

        let segments = [
            ObserverManager.segmentString(for: date, durationSeconds: 300.0),
            ObserverManager.segmentString(for: date, durationSeconds: 0.4),
            ObserverManager.segmentString(for: date, durationSeconds: 47.6),
        ]

        XCTAssertEqual(segments[0], "104355_300")
        XCTAssertEqual(segments[1], "104355_1")
        XCTAssertEqual(segments[2], "104355_48")
        for segment in segments {
            XCTAssertTrue(segment.range(of: #"^\d{6}_\d+$"#, options: .regularExpression) != nil)
        }
    }

    @MainActor
    func testStartSessionTransitionsToActive() async {
        let outcome = await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(outcome, .started)
        guard case .active(let session) = self.manager.state else {
            return XCTFail("Expected active state")
        }
        XCTAssertEqual(session.mode, .meeting)
        XCTAssertEqual(session.currentChunkIndex, 0)
        XCTAssertEqual(self.recorder.startCallCount, 1)
    }

    @MainActor
    func testCaptureAdapterTreatsStartedAndAlreadyRunningAsSuccess() async {
        let started = await self.manager.startCaptureSession(mode: .meeting)
        let alreadyRunning = await self.manager.startCaptureSession(mode: .meeting)

        XCTAssertTrue(started)
        XCTAssertTrue(alreadyRunning)
    }

    @MainActor
    func testCaptureAdapterTreatsStartRefusalAsFailure() async {
        self.recorder.permissionGranted = false

        let refused = await self.manager.startCaptureSession(mode: .meeting)

        XCTAssertFalse(refused)
    }

    @MainActor
    func testCaptureAdapterTreatsStoppedAndAlreadyStoppedAsSuccess() async {
        let started = await self.manager.startCaptureSession(mode: .meeting)
        let stopped = await self.manager.stopCaptureSession()
        let alreadyStopped = await self.manager.stopCaptureSession()

        XCTAssertTrue(started)
        XCTAssertTrue(stopped)
        XCTAssertTrue(alreadyStopped)
    }

    @MainActor
    func testCaptureAdapterTreatsStopRefusalAsFailure() async {
        let started = await self.manager.startCaptureSession(mode: .meeting)
        self.recorder.stopError = ObserverManagerTestError.stopFailed
        let refused = await self.manager.stopCaptureSession()

        XCTAssertTrue(started)
        XCTAssertFalse(refused)
    }

    @MainActor
    func testStopSessionWithNoLocalPortLeavesChunkPending() async throws {
        let mobileRoot = self.tempDirectory.appendingPathComponent("NoPortMobileSegment", isDirectory: true)
        let manager = ObserverManager(
            recorder: self.recorder,
            mobileSegmentEngine: MobileSegmentEngine(
                uploader: MobileSegmentUploader(
                    store: MobileSegmentStore(rootURL: mobileRoot),
                    clock: self.clock
                ),
                clock: self.clock
            ),
            clock: self.clock,
            liveActivity: self.liveActivity
        )

        await manager.startSession(mode: .meeting)
        await manager.stopSession()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertEqual(try self.mobileSegmentFileCount(root: mobileRoot, pathExtension: "m4a", lifecycle: "pending"), 1)
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
        XCTAssertEqual(self.mobileSegmentUploader.pendingCount, 0)
    }

    @MainActor
    func testEmptyChunkOnStopSessionIsSkippedAndCleanedUp() async throws {
        await self.manager.startSession(mode: .meeting)
        let inProgressDirectory = try XCTUnwrap(self.recorder.lastStartURL?.deletingLastPathComponent())
        self.recorder.nextChunkDuration = 0

        await self.manager.stopSession()

        XCTAssertEqual(self.mobileSegmentUploader.pendingCount, 0)
        XCTAssertEqual(try self.pendingFileCount(pathExtension: "m4a"), 0)
        XCTAssertTrue(try self.m4aFiles(in: inProgressDirectory).isEmpty)
    }

    @MainActor
    func testStopSessionEndsLiveActivityWhenRecorderStopThrows() async {
        await self.manager.startSession(mode: .meeting)
        self.recorder.stopError = ObserverManagerTestError.stopFailed

        let outcome = await self.manager.stopSession()

        XCTAssertEqual(outcome, .refused(.error(.unavailable(reason: "stopFailed"))))
        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.mobileSegmentUploader.pendingCount, 0)
    }

    @MainActor
    func testPermissionDeniedTransitionsToError() async {
        self.recorder.permissionGranted = false

        let outcome = await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(outcome, .refused(.error(.permissionDenied)))
        XCTAssertEqual(self.manager.state, .error(.permissionDenied))
    }

    @MainActor
    func testClockDrivenSegmentationRotatesChunk() async {
        await self.manager.startSession(mode: .meeting)
        try? await Task.sleep(for: .milliseconds(20))

        self.clock.advance(by: 300)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.recorder.rotateCallCount, 1)
        if case .active(let session) = self.manager.state {
            XCTAssertEqual(session.currentChunkIndex, 0)
        } else {
            XCTFail("Expected active state")
        }
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
        XCTAssertEqual(self.mobileSegmentUploader.pendingCount, 0)
        XCTAssertEqual(try self.pendingFileCount(pathExtension: "m4a"), 0)

        await self.manager.stopSession()
        XCTAssertTrue(try self.m4aFiles(in: inProgressDirectory).isEmpty)
    }

    @MainActor
    func testAboveThresholdChunkIsEnqueued() async throws {
        let mobileRoot = self.tempDirectory.appendingPathComponent("AboveThresholdMobileSegment", isDirectory: true)
        let manager = ObserverManager(
            recorder: self.recorder,
            mobileSegmentEngine: MobileSegmentEngine(
                uploader: MobileSegmentUploader(
                    store: MobileSegmentStore(rootURL: mobileRoot),
                    clock: self.clock
                ),
                clock: self.clock
            ),
            clock: self.clock,
            liveActivity: self.liveActivity
        )
        self.recorder.nextChunkDuration = 5

        await manager.startSession(mode: .meeting)
        await manager.stopSession()

        XCTAssertEqual(try self.mobileSegmentFileCount(root: mobileRoot, pathExtension: "m4a", lifecycle: "pending"), 1)
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
    func testConfigurationChangeRestartsOncePerFaultAndStaysActive() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()

        XCTAssertEqual(self.recorder.restartCallCount, 1)
        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }

        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()

        XCTAssertEqual(self.recorder.restartCallCount, 2)
        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }
    }

    @MainActor
    func testConfigurationChangeRestartFailureStopsAndDoesNotRetry() async {
        await self.manager.startSession(mode: .meeting)
        self.recorder.restartError = ObserverManagerTestError.restartFailed

        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()

        XCTAssertEqual(self.recorder.restartCallCount, 1)
        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)

        self.clock.advance(by: 30)
        await self.drainManagerTasks()

        XCTAssertEqual(self.recorder.restartCallCount, 1)
    }

    @MainActor
    func testMediaServicesResetStopsWithConflictError() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitEngineFault(.mediaServicesReset)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
    }

    @MainActor
    func testEngineFaultsAreInertWhileIdle() async {
        XCTAssertEqual(self.manager.state, .idle)

        self.recorder.emitEngineFault(.mediaServicesReset)
        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.recorder.restartCallCount, 0)
    }

    @MainActor
    func testConfigurationChangeDuringInterruptionRebuildsOnEndedPath() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        await self.drainManagerTasks()
        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()

        XCTAssertEqual(self.recorder.restartCallCount, 0)
        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }

        self.clock.advance(by: 5)
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        XCTAssertEqual(self.recorder.restartCallCount, 1)
        XCTAssertEqual(self.recorder.resumeCallCount, 0)
        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }
    }

    @MainActor
    func testResumeFailureAfterInterruptionStopsWithConflictError() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        await self.drainManagerTasks()
        self.recorder.resumeError = ObserverManagerTestError.resumeFailed
        self.clock.advance(by: 5)
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
    }

    @MainActor
    func testMissingInterruptionEndedDeadlineStopsAndLateEndedIsNoOp() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        await self.drainManagerTasks()
        self.clock.advance(by: 61)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.recorder.resumeCallCount, 0)

        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.recorder.resumeCallCount, 0)
    }

    @MainActor
    func testInterruptionEndedBeforeDeadlineCancelsDeadline() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        await self.drainManagerTasks()
        self.clock.advance(by: 30)
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        XCTAssertEqual(self.recorder.resumeCallCount, 1)
        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }

        self.clock.advance(by: 60)
        await self.drainManagerTasks()

        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }
    }

    @MainActor
    func testWatchdogStallStopsMeetingModeWithConflictError() async {
        await self.manager.startSession(mode: .meeting)
        await self.drainManagerTasks()

        // AC8: meeting is the non-voiceMemo mode; watchdog liveness is mode-independent.
        self.clock.advance(by: 11)
        await self.drainManagerTasks()
        self.clock.advance(by: 11)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
    }

    @MainActor
    func testWatchdogDoesNotFireWhileInterrupted() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        await self.drainManagerTasks()
        self.clock.advance(by: 11)
        await self.drainManagerTasks()
        self.clock.advance(by: 11)
        await self.drainManagerTasks()

        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }
    }

    @MainActor
    func testWatchdogRearmsAfterSuccessfulResume() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began)
        await self.drainManagerTasks()
        self.clock.advance(by: 30)
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }

        self.clock.advance(by: 11)
        await self.drainManagerTasks()
        self.clock.advance(by: 11)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
    }

    @MainActor
    func testWatchdogPendingTickRechecksStateAfterStop() async {
        await self.manager.startSession(mode: .meeting)
        await self.drainManagerTasks()

        self.clock.advance(by: 11)
        await self.drainManagerTasks()
        await self.manager.stopSession()
        self.clock.advance(by: 11)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .idle)
    }

    @MainActor
    func testTapToCancelDuringStarting() async {
        self.recorder.permissionDelay = .milliseconds(100)
        let task = Task {
            await self.manager.startSession(mode: .meeting)
        }

        try? await Task.sleep(for: .milliseconds(20))
        let stopOutcome = await self.manager.stopSession()
        let startOutcome = await task.value

        XCTAssertEqual(stopOutcome, .stopped)
        XCTAssertEqual(startOutcome, .refused(.cancelled))
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
        let outcome = await self.manager.stopSession()

        XCTAssertEqual(outcome, .alreadyStopped)
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
        let firstOutcome = await self.manager.startSession(mode: .meeting)
        let secondOutcome = await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(firstOutcome, .started)
        XCTAssertEqual(secondOutcome, .alreadyRunning)
        XCTAssertEqual(self.recorder.startCallCount, 1)
    }

    @MainActor
    func testStartingAttemptSupersededByStopAndNewStartDoesNotActivateTwice() async {
        self.recorder.permissionDelay = .seconds(1)
        let firstStart = Task { @MainActor [manager = self.manager] in
            await manager.startSession(mode: .meeting)
        }

        for _ in 0..<100 {
            if case .starting = self.manager.state {
                break
            }
            await Task.yield()
        }
        guard case .starting = self.manager.state else {
            return XCTFail("Expected first start to wait for permission")
        }

        let stopOutcome = await self.manager.stopSession()
        self.recorder.permissionDelay = nil
        let secondStartOutcome = await self.manager.startSession(mode: .meeting)
        let firstStartOutcome = await firstStart.value

        XCTAssertEqual(stopOutcome, .stopped)
        XCTAssertEqual(secondStartOutcome, .started)
        XCTAssertEqual(firstStartOutcome, .refused(.cancelled))
        XCTAssertEqual(self.recorder.startCallCount, 1)
        XCTAssertEqual(self.liveActivity.startCalls.count, 1, "Each active state transition starts the live activity")

        _ = await self.manager.stopSession()
    }

    @MainActor
    func testStopDuringLiveActivityStartDoesNotRearmBackgroundTasks() async {
        self.liveActivity.startDelay = .seconds(1)
        let start = Task { @MainActor [manager = self.manager] in
            await manager.startSession(mode: .meeting)
        }

        for _ in 0..<100 {
            if case .active = self.manager.state, self.liveActivity.startCalls.count == 1 {
                break
            }
            await Task.yield()
        }
        guard case .active = self.manager.state, self.liveActivity.startCalls.count == 1 else {
            return XCTFail("Expected start to suspend during live activity activation")
        }

        let stopOutcome = await self.manager.stopSession()
        self.liveActivity.startDelay = nil
        let startOutcome = await start.value
        await Task.yield()

        XCTAssertEqual(stopOutcome, .stopped)
        XCTAssertEqual(startOutcome, .refused(.cancelled))
        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.recorder.startCallCount, 1)
        XCTAssertEqual(self.recorder.stopCallCount, 1)
        XCTAssertEqual(self.liveActivity.startCalls.count, 1)
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
    }
}

private enum ObserverManagerTestError: Error {
    case startFailed
    case stopFailed
    case resumeFailed
    case restartFailed
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
    func drainManagerTasks() async {
        try? await Task.sleep(for: .milliseconds(40))
    }

    func fixedLocalDate(hour: Int, minute: Int, second: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: 2026,
            month: 4,
            day: 20,
            hour: hour,
            minute: minute,
            second: second
        )
        return try XCTUnwrap(calendar.date(from: components))
    }

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

    func mobileSegmentFileCount(
        root: URL? = nil,
        pathExtension: String,
        lifecycle: String
    ) throws -> Int {
        let root = root ?? self.tempDirectory.appendingPathComponent("MobileSegment", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent(lifecycle, isDirectory: true),
            includingPropertiesForKeys: nil
        ) else {
            return 0
        }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == pathExtension {
            count += 1
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
