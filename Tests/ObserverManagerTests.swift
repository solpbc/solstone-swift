// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import os
import XCTest

nonisolated final class ObserverManagerTests: XCTestCase {
    @MainActor private lazy var recorder = MockObserverRecorder()
    @MainActor private lazy var clock = MockObserverClock()
    @MainActor private lazy var liveActivity = MockObserverLiveActivity()
    private lazy var tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverManagerTests-\(UUID().uuidString)", isDirectory: true)
    private lazy var suiteName = "ObserverManagerTests.\(UUID().uuidString)"
    private lazy var defaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: self.suiteName)!
        defaults.removePersistentDomain(forName: self.suiteName)
        return defaults
    }()
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
        journalEvents: self.mobileSegmentUploader.journalEvents,
        clock: self.clock,
        liveActivity: self.liveActivity,
        defaults: self.defaults
    )

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
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
        let uploader = MobileSegmentUploader(
            store: MobileSegmentStore(rootURL: mobileRoot),
            clock: self.clock
        )
        let manager = ObserverManager(
            recorder: self.recorder,
            mobileSegmentEngine: MobileSegmentEngine(
                uploader: uploader,
                clock: self.clock
            ),
            journalEvents: uploader.journalEvents,
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
        XCTAssertEqual(self.liveActivity.endCalls.first?.sessionID, self.liveActivity.startCalls.first?.1)
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .owner)
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
        let uploader = MobileSegmentUploader(
            store: MobileSegmentStore(rootURL: mobileRoot),
            clock: self.clock
        )
        let manager = ObserverManager(
            recorder: self.recorder,
            mobileSegmentEngine: MobileSegmentEngine(
                uploader: uploader,
                clock: self.clock
            ),
            journalEvents: uploader.journalEvents,
            clock: self.clock,
            liveActivity: self.liveActivity
        )
        self.recorder.nextChunkDuration = 5

        await manager.startSession(mode: .meeting)
        await manager.stopSession()

        XCTAssertEqual(try self.mobileSegmentFileCount(root: mobileRoot, pathExtension: "m4a", lifecycle: "pending"), 1)
    }

    @MainActor
    func testVoiceMemoIgnoresSilence() async {
        await self.manager.startSession(mode: .voiceMemo)

        self.recorder.emitMeter(level: -55, duration: 0.5)
        self.recorder.emitMeter(level: -90, duration: 30)
        try? await Task.sleep(for: .milliseconds(20))

        guard case .active(let session) = self.manager.state else {
            return XCTFail("expected the voice memo to stay active")
        }
        XCTAssertEqual(session.mode, .voiceMemo)
        XCTAssertEqual(self.recorder.stopCallCount, 0)
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

        self.recorder.emitInterruption(.began(.default))
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
    func testLongInterruptionStopsWithMicrophoneTakenPause() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began(.default))
        try? await Task.sleep(for: .milliseconds(20))
        self.clock.advance(by: 61)
        self.recorder.emitInterruption(.ended)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)
    }

    @MainActor
    func testLongInterruptionWithNonHoldingReasonStopsWithConflictError() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began(.other(raw: AVAudioSession.InterruptionReason.builtInMicMuted.rawValue)))
        try? await Task.sleep(for: .milliseconds(20))
        self.clock.advance(by: 61)
        self.recorder.emitInterruption(.ended)
        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)
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
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)

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
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)
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

        self.recorder.emitInterruption(.began(.default))
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

        self.recorder.emitInterruption(.began(.default))
        await self.drainManagerTasks()
        self.recorder.resumeError = ObserverManagerTestError.resumeFailed
        self.clock.advance(by: 5)
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)
    }

    @MainActor
    func testMissingInterruptionEndedDeadlineStopsAndLateEndedIsNoOp() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began(.default))
        await self.drainManagerTasks()
        self.clock.advance(by: 61)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)
        XCTAssertEqual(self.recorder.resumeCallCount, 0)

        let starts = self.recorder.startCallCount
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertEqual(self.recorder.resumeCallCount, 0)
        XCTAssertEqual(self.recorder.startCallCount, starts)
    }

    @MainActor
    func testMissingInterruptionEndedDeadlineWithNonHoldingReasonStopsWithConflictError() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began(.other(raw: AVAudioSession.InterruptionReason.builtInMicMuted.rawValue)))
        await self.drainManagerTasks()
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertEqual(self.audioPresentation().sourceState, .active)

        self.clock.advance(by: 61)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.count, 1)
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)
        XCTAssertEqual(self.recorder.resumeCallCount, 0)

        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.recorder.resumeCallCount, 0)
    }

    @MainActor
    func testInterruptionEndedBeforeDeadlineCancelsDeadline() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began(.default))
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
        XCTAssertEqual(self.liveActivity.endCalls.first?.reason, .system)
    }

    @MainActor
    func testWatchdogDoesNotFireWhileInterrupted() async {
        await self.manager.startSession(mode: .meeting)

        self.recorder.emitInterruption(.began(.default))
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

        self.recorder.emitInterruption(.began(.default))
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
        XCTAssertNil(self.defaults.object(forKey: AudioStorageKey.enrolled))
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
    func testRearmLiveActivityStartsFreshActivityForActiveSession() async {
        await self.manager.startSession(mode: .meeting)
        guard let original = self.liveActivity.startCalls.first else {
            return XCTFail("Expected initial live activity start")
        }

        await self.manager.rearmLiveActivity()

        XCTAssertEqual(self.liveActivity.startCalls.count, 2)
        XCTAssertEqual(self.liveActivity.startCalls.last?.0, .meeting)
        XCTAssertEqual(self.liveActivity.startCalls.last?.1, original.1)
        XCTAssertEqual(self.liveActivity.startCalls.last?.2, original.2)
    }

    @MainActor
    func testRearmLiveActivityIsNoOpOutsideAnActiveSession() async {
        await self.manager.rearmLiveActivity()
        XCTAssertTrue(self.liveActivity.startCalls.isEmpty)

        self.recorder.permissionGranted = false
        await self.manager.startSession(mode: .meeting)
        await self.manager.rearmLiveActivity()

        XCTAssertTrue(self.liveActivity.startCalls.isEmpty)
    }

    @MainActor
    func testStartSessionWritesAudioEnrollment() async {
        await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
    }

    @MainActor
    func testStartCaptureSessionWritesAudioEnrollment() async {
        let outcome = await self.manager.startCaptureSession(mode: .meeting)

        XCTAssertTrue(outcome)
        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
    }

    @MainActor
    func testStartSessionDoesNotWriteAudioEnrollmentForUnavailableOrPermissionDenied() async {
        self.recorder.permissionGranted = false
        await self.manager.startSession(mode: .meeting)
        XCTAssertEqual(self.manager.state, .error(.permissionDenied))
        XCTAssertNil(self.defaults.object(forKey: AudioStorageKey.enrolled))

        self.recorder.permissionGranted = true
        self.recorder.startError = ObserverManagerTestError.startFailed
        await self.manager.startSession(mode: .meeting)
        guard case .error(.unavailable) = self.manager.state else {
            return XCTFail("Expected unavailable error")
        }
        XCTAssertNil(self.defaults.object(forKey: AudioStorageKey.enrolled))
    }

    @MainActor
    func testFailedAudioStartReleasesItsSegmentSoARetryRecordsSomewhereFresh() async throws {
        // A start that throws never installed the tap, so the writer holds no frames.
        self.recorder.nextChunkDuration = 0
        self.recorder.startError = ObserverManagerTestError.startFailed

        await self.manager.startSession(mode: .meeting)

        guard case .error = self.manager.state else {
            return XCTFail("Expected error state after a failed start")
        }
        let failedURL = try XCTUnwrap(self.recorder.lastStartURL)

        self.recorder.startError = nil
        await self.manager.startSession(mode: .meeting)

        let retryURL = try XCTUnwrap(self.recorder.lastStartURL)
        XCTAssertNotEqual(
            failedURL.deletingLastPathComponent(),
            retryURL.deletingLastPathComponent(),
            "A retry must record into a fresh segment, not the failed start's"
        )
    }

    @MainActor
    func testFailedAudioStartLeavesNoSegmentBehind() async throws {
        self.recorder.nextChunkDuration = 0
        self.recorder.startError = ObserverManagerTestError.startFailed

        await self.manager.startSession(mode: .meeting)

        let store = self.mobileSegmentUploader.storeForTransferMigration
        XCTAssertEqual(try store.list(.active).count, 0, "The failed start's segment must not be left open")
        XCTAssertEqual(try store.list(.pending).count, 0)
        XCTAssertEqual(try store.list(.failed).count, 0)
    }

    @MainActor
    func testStartSessionPreservesThrownObserverError() async {
        self.recorder.startError = ObserverError.unavailable(reason: "audio input unavailable")

        await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(self.manager.state, .error(.unavailable(reason: "audio input unavailable")))
    }

    @MainActor
    func testAudioEnrollmentStateIgnoresLiveActivityOutcome() async {
        await self.manager.startSession(mode: .meeting)
        guard case .active = self.manager.state else {
            return XCTFail("Expected active state")
        }

        // MockObserverLiveActivity does no real ActivityKit work; manager state never depends on live-activity results.
        await self.manager.stopSession()

        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
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
        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
    }

    @MainActor
    func testActiveWriterFaultAddsADiagnosticLine() async throws {
        let log = DiagnosticLog()
        let manager = ObserverManager(
            recorder: self.recorder,
            mobileSegmentEngine: self.mobileSegmentEngine,
            journalEvents: self.mobileSegmentUploader.journalEvents,
            diagnosticLog: log,
            clock: self.clock,
            liveActivity: self.liveActivity,
            defaults: self.defaults
        )
        let outcome = await manager.startSession(mode: .meeting)
        XCTAssertEqual(outcome, .started)
        let segmentID = try XCTUnwrap(self.recorder.lastStartSegmentID)
        let sessionID = try XCTUnwrap(self.recorder.lastStartSessionID)
        self.recorder.emitPhoneAudioFault(
            PhoneAudioWriterFault(segmentID: segmentID, sessionID: sessionID, reason: "audio_writer_failed")
        )
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(log.events.contains { $0.message == "audio_writer_failed" })
    }

    @MainActor
    func testStaleWriterFaultAddsNoDiagnosticLine() async {
        let log = DiagnosticLog()
        let manager = ObserverManager(
            recorder: self.recorder,
            mobileSegmentEngine: self.mobileSegmentEngine,
            journalEvents: self.mobileSegmentUploader.journalEvents,
            diagnosticLog: log,
            clock: self.clock,
            liveActivity: self.liveActivity,
            defaults: self.defaults
        )
        let outcome = await manager.startSession(mode: .meeting)
        XCTAssertEqual(outcome, .started)
        self.recorder.emitPhoneAudioFault(
            PhoneAudioWriterFault(segmentID: UUID(), sessionID: UUID(), reason: "audio_writer_failed")
        )
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(log.events.contains { $0.message == "audio_writer_failed" })
        guard case .active = manager.state else {
            return XCTFail("stale fault stopped the session")
        }
    }

    @MainActor
    func testInterruptionEndResumesWhileTheStoreWriteIsBlocked() async throws {
        await self.manager.startSession(mode: .meeting)
        let id = JournalEventStore.diagnosticID(
            segmentID: nil,
            source: .audio,
            reason: "observer_interruption_ended",
            writerFault: false
        )
        let directory = self.mobileSegmentUploader.journalEvents.rootURL
            .appendingPathComponent("diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appendingPathComponent("\(JournalEventStore.fileName(for: id)).json")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        defer {
            let descriptor = open(fifo.path, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { close(descriptor) }
            try? FileManager.default.removeItem(at: fifo)
        }
        self.recorder.emitInterruption(.began(.absent))
        try? await Task.sleep(for: .milliseconds(20))
        self.clock.advance(by: 30)
        self.recorder.emitInterruption(.ended)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(self.recorder.resumeCallCount, 1)
    }

    @MainActor
    func testFirstBufferFaultWhileStartingRefusesStart() async {
        self.recorder.onStartCall = { [weak self] segmentID, sessionID in
            self?.recorder.emitPhoneAudioFault(PhoneAudioWriterFault(
                segmentID: segmentID,
                sessionID: sessionID,
                reason: "audio_writer_failed"
            ))
            await self?.drainManagerTasks()
        }

        let outcome = await self.manager.startSession(mode: .meeting)

        XCTAssertEqual(outcome, .refused(.error(.unavailable(reason: "audio input unavailable"))))
        guard case .error(let err) = self.manager.state else {
            return XCTFail("expected error state")
        }
        XCTAssertEqual(err, .unavailable(reason: "audio input unavailable"))
    }

    @MainActor
    func testDelayedFaultFromOldSessionAfterReplacementDoesNotStopNewSession() async throws {
        let outcome1 = await self.manager.startSession(mode: .meeting)
        XCTAssertEqual(outcome1, .started)
        let oldSegmentID = try XCTUnwrap(self.recorder.lastStartSegmentID)
        let oldSessionID = try XCTUnwrap(self.recorder.lastStartSessionID)

        let stopOutcome = await self.manager.stopSession()
        XCTAssertEqual(stopOutcome, .stopped)

        let outcome2 = await self.manager.startSession(mode: .meeting)
        XCTAssertEqual(outcome2, .started)
        let newSessionID = try XCTUnwrap(self.recorder.lastStartSessionID)
        XCTAssertNotEqual(oldSessionID, newSessionID)

        // Delayed fault from old session
        self.recorder.emitPhoneAudioFault(PhoneAudioWriterFault(
            segmentID: oldSegmentID,
            sessionID: oldSessionID,
            reason: "audio_writer_failed"
        ))

        await self.drainManagerTasks()

        // New session must still be active
        guard case .active(let session) = self.manager.state else {
            return XCTFail("expected new session to stay active")
        }
        XCTAssertEqual(session.sessionID, newSessionID)
    }

    @MainActor
    func testDelayedSuccessFromOldSessionAfterReplacementDoesNotMutateNewSession() async {
        let outcome1 = await self.manager.startSession(mode: .voiceMemo)
        XCTAssertEqual(outcome1, .started)

        let stopOutcome = await self.manager.stopSession()
        XCTAssertEqual(stopOutcome, .stopped)

        let outcome2 = await self.manager.startSession(mode: .meeting)
        XCTAssertEqual(outcome2, .started)

        // Delayed meter callback simulating silence from old voiceMemo session
        self.recorder.emitMeter(level: -60, duration: 4.0)

        await self.drainManagerTasks()

        // Meeting mode session does not terminate on silence
        guard case .active(let session) = self.manager.state else {
            return XCTFail("expected session to remain active")
        }
        XCTAssertEqual(session.mode, .meeting)
    }

    @MainActor
    func testHoldingBeganPresentsPausedAndOwnerStopEndsTheActivity() async {
        let reasons: [ObserverInterruptionBeganReason] = [.absent, .default]
        for reason in reasons {
            await self.manager.startSession(mode: .meeting)
            let starts = self.recorder.startCallCount
            self.recorder.emitInterruption(.began(reason))
            await self.drainManagerTasks()

            guard case .active = self.manager.state else {
                return XCTFail("hold keeps the session active")
            }
            XCTAssertEqual(self.manager.microphoneTakenPause, .holdingSession)
            let presentation = self.audioPresentation()
            XCTAssertEqual(presentation.sourceState, .paused)
            XCTAssertEqual(presentation.tileLine, SourceVocabulary.microphoneTakenSubtextCompact)
            XCTAssertEqual(presentation.detailLine, SourceVocabulary.microphoneTakenSubtextCompact)
            XCTAssertFalse(presentation.pauseEnabled)
            XCTAssertFalse(presentation.showsLiveElapsed)
            if case .error = self.manager.state {
                XCTFail("a hold is not a fault")
            }

            let outcome = await self.manager.startSession(mode: .meeting)
            XCTAssertEqual(outcome, .alreadyRunning)
            XCTAssertEqual(self.recorder.startCallCount, starts)

            let ends = self.liveActivity.endCalls.count
            let stopped = await self.manager.stopSession()
            XCTAssertEqual(stopped, .stopped)
            XCTAssertEqual(self.manager.state, .idle)
            XCTAssertEqual(self.liveActivity.endCalls.count, ends + 1)
            XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .owner)
            XCTAssertNil(self.manager.microphoneTakenPause)
        }
    }

    @MainActor
    func testMeterDuringHoldReturnsToOnAndDeadlineStillPauses() async {
        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(.absent))
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.microphoneTakenPause, .holdingSession)

        self.recorder.emitMeter(level: 0.2, duration: 1)
        await self.drainManagerTasks()
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertEqual(self.audioPresentation().sourceState, .active)

        self.clock.advance(by: 15)
        await self.drainManagerTasks()
        XCTAssertNil(self.manager.microphoneTakenPause)
        guard case .active = self.manager.state else {
            return XCTFail("quiet after a frame does not restore the hold")
        }

        self.clock.advance(by: 50)
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertEqual(self.manager.microphoneTakenPause, .stopped)
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
        XCTAssertEqual(self.audioPresentation().detailLine, SourceVocabulary.microphoneTakenSubtext)
        XCTAssertEqual(self.audioPresentation().tileLine, SourceVocabulary.microphoneTakenSubtextCompact)
        if case .error = self.manager.state {
            XCTFail("deadline of a holding reason is the pause")
        }
    }

    @MainActor
    func testClassifiedResumeAndRebuildRefusalsEnterThePause() async {
        let reasons: [ObserverInterruptionBeganReason] = [.absent, .default]
        let domains = ["com.apple.coreaudio.avfaudio", NSOSStatusErrorDomain]
        let codes: [AVAudioSession.ErrorCode] = [
            .insufficientPriority, .cannotInterruptOthers, .cannotStartRecording,
        ]
        for reason in reasons {
            for domain in domains {
                for code in codes {
                    let label = "resume \(reason) \(domain) \(code.rawValue)"
                    await self.enterHoldingPause(reason: reason, label: label)
                    self.recorder.resumeError = self.microphoneRefusal(code, domain: domain)
                    let ends = self.liveActivity.endCalls.count
                    self.recorder.emitInterruption(.ended)
                    await self.drainManagerTasks()
                    self.assertMicrophoneTakenPause(label)
                    XCTAssertEqual(self.liveActivity.endCalls.count, ends + 1, label)
                    XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system, label)
                    self.recorder.resumeError = nil
                    _ = await self.manager.stopSession()
                }
            }
        }
        for reason in reasons {
            for domain in domains {
                for code in codes {
                    let label = "rebuild \(reason) \(domain) \(code.rawValue)"
                    await self.enterHoldingPause(reason: reason, label: label)
                    self.recorder.emitEngineFault(.configurationChange)
                    await self.drainManagerTasks()
                    self.recorder.restartError = self.microphoneRefusal(code, domain: domain)
                    let ends = self.liveActivity.endCalls.count
                    let restarts = self.recorder.restartCallCount
                    self.recorder.emitInterruption(.ended)
                    await self.drainManagerTasks()
                    XCTAssertEqual(self.recorder.restartCallCount, restarts + 1, label)
                    self.assertMicrophoneTakenPause(label)
                    XCTAssertEqual(self.liveActivity.endCalls.count, ends + 1, label)
                    XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system, label)
                    self.recorder.restartError = nil
                    _ = await self.manager.stopSession()
                }
            }
        }
    }

    @MainActor
    func testUnclassifiedResumeAndRebuildStayNeedsAttention() async {
        let other = NSError(domain: NSOSStatusErrorDomain, code: 1)
        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(.default))
        await self.drainManagerTasks()
        self.recorder.resumeError = other
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
        self.recorder.resumeError = nil

        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(.absent))
        await self.drainManagerTasks()
        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()
        self.recorder.restartError = other
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
        self.recorder.restartError = nil
    }

    @MainActor
    func testClassifiedRefusalForOtherBeganReasonStaysNeedsAttention() async {
        let error = self.microphoneRefusal(.insufficientPriority, domain: "com.apple.coreaudio.avfaudio")
        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(.other(raw: AVAudioSession.InterruptionReason.builtInMicMuted.rawValue)))
        await self.drainManagerTasks()
        self.recorder.resumeError = error
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
        self.recorder.resumeError = nil

        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(.other(raw: AVAudioSession.InterruptionReason.builtInMicMuted.rawValue)))
        await self.drainManagerTasks()
        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()
        self.recorder.restartError = error
        self.recorder.emitInterruption(.ended)
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
    }

    @MainActor
    func testRotationRefusalStaysNeedsAttentionAndEndsSystem() async {
        let codes: [AVAudioSession.ErrorCode] = [
            .insufficientPriority, .cannotInterruptOthers, .cannotStartRecording,
        ]
        for code in codes {
            await self.manager.startSession(mode: .meeting)
            try? await Task.sleep(for: .milliseconds(20))
            self.recorder.rotateError = self.microphoneRefusal(code, domain: NSOSStatusErrorDomain)
            let ends = self.liveActivity.endCalls.count
            self.clock.advance(by: 300)
            try? await Task.sleep(for: .milliseconds(40))

            XCTAssertEqual(
                self.manager.state,
                .error(.unavailable(reason: "audio input unavailable")),
                "rotation \(code.rawValue)"
            )
            XCTAssertNotEqual(self.manager.microphoneTakenPause, .stopped)
            XCTAssertEqual(self.liveActivity.endCalls.count, ends + 1)
            XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
            self.recorder.rotateError = nil
        }
    }

    @MainActor
    func testInsufficientPriorityStartEntersPauseAndReleasesTheSegment() async throws {
        self.recorder.nextChunkDuration = 0
        self.recorder.startError = self.microphoneRefusal(.insufficientPriority, domain: NSOSStatusErrorDomain)
        let outcome = await self.manager.startSession(mode: .meeting)

        guard case .refused = outcome else {
            return XCTFail("expected a refused start")
        }
        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertNil(self.defaults.object(forKey: AudioStorageKey.enrolled))
        let presentation = self.audioPresentation()
        XCTAssertEqual(presentation.sourceState, .readyToSetUp)
        XCTAssertEqual(presentation.firstUseLine, SourceVocabulary.microphoneTakenSubtextCompact)
        XCTAssertEqual(
            AudioEnrollmentPresentation.current(isJournalPaired: true).turnOnAudio,
            SourceVocabulary.turnOnAudio
        )
        let store = self.mobileSegmentUploader.storeForTransferMigration
        XCTAssertEqual(try store.list(.active).count, 0)
        let failedURL = try XCTUnwrap(self.recorder.lastStartURL)

        self.recorder.startError = nil
        self.recorder.nextChunkDuration = 5
        await self.manager.startSession(mode: .meeting)
        let retryURL = try XCTUnwrap(self.recorder.lastStartURL)
        XCTAssertNotEqual(failedURL.deletingLastPathComponent(), retryURL.deletingLastPathComponent())
        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
    }

    @MainActor
    func testStartCaptureSessionInsufficientPriorityEntersPause() async {
        self.recorder.startError = self.microphoneRefusal(
            .insufficientPriority,
            domain: "com.apple.coreaudio.avfaudio"
        )
        let started = await self.manager.startCaptureSession(mode: .meeting)

        XCTAssertFalse(started)
        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertNil(self.defaults.object(forKey: AudioStorageKey.enrolled))
        XCTAssertEqual(self.audioPresentation().sourceState, .readyToSetUp)
        XCTAssertTrue(self.liveActivity.startCalls.isEmpty)
    }

    @MainActor
    func testOtherStartErrorStaysNeedsAttention() async {
        self.recorder.startError = self.microphoneRefusal(.cannotStartRecording, domain: NSOSStatusErrorDomain)
        let outcome = await self.manager.startSession(mode: .meeting)

        guard case .refused(.error(_)) = outcome else {
            return XCTFail("expected an error refusal")
        }
        guard case .error = self.manager.state else {
            return XCTFail("expected needs attention, got \(self.manager.state)")
        }
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertNil(self.defaults.object(forKey: AudioStorageKey.enrolled))
    }

    @MainActor
    func testLeavingTheMicrophoneTakenPause() async {
        await self.manager.startSession(mode: .meeting)
        _ = await self.manager.stopSession()
        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)

        self.recorder.startError = self.microphoneRefusal(.insufficientPriority, domain: NSOSStatusErrorDomain)
        let refused = await self.manager.startSession(mode: .meeting)
        guard case .refused = refused else {
            return XCTFail("expected the pause")
        }
        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertEqual(self.audioPresentation().sourceState, .paused)
        XCTAssertEqual(self.audioPresentation().detailLine, SourceVocabulary.microphoneTakenSubtext)
        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)
        let activities = self.liveActivity.startCalls.count

        let refusedAgain = await self.manager.startSession(mode: .meeting)
        guard case .refused = refusedAgain else {
            return XCTFail("a second refusal stays in the pause")
        }
        XCTAssertEqual(self.manager.state, .microphoneTaken)
        XCTAssertEqual(self.liveActivity.startCalls.count, activities)
        XCTAssertEqual(self.defaults.object(forKey: AudioStorageKey.enrolled) as? Bool, true)

        self.recorder.startError = nil
        let started = await self.manager.startSession(mode: .meeting)
        XCTAssertEqual(started, .started)
        guard case .active = self.manager.state else {
            return XCTFail("a successful start leaves the pause")
        }
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertEqual(self.liveActivity.startCalls.count, activities + 1)
        XCTAssertEqual(self.audioPresentation().sourceState, .active)

        let stopped = await self.manager.stopCaptureSession()
        XCTAssertTrue(stopped)
        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.audioPresentation().sourceState, .off)
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .owner)
    }

    @MainActor
    func testMediaServicesResetAndWriterFaultNeverEnterThePause() async throws {
        await self.manager.startSession(mode: .meeting)
        self.recorder.emitEngineFault(.mediaServicesReset)
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)

        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(.default))
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.microphoneTakenPause, .holdingSession)
        self.recorder.emitEngineFault(.mediaServicesReset)
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)

        await self.manager.startSession(mode: .meeting)
        let segmentID = try XCTUnwrap(self.recorder.lastStartSegmentID)
        let sessionID = try XCTUnwrap(self.recorder.lastStartSessionID)
        self.recorder.emitPhoneAudioFault(
            PhoneAudioWriterFault(segmentID: segmentID, sessionID: sessionID, reason: "audio_writer_failed")
        )
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.unavailable(reason: "audio input unavailable")))
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)

        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(.default))
        await self.drainManagerTasks()
        let heldSegment = try XCTUnwrap(self.recorder.lastStartSegmentID)
        let heldSession = try XCTUnwrap(self.recorder.lastStartSessionID)
        self.recorder.emitPhoneAudioFault(
            PhoneAudioWriterFault(segmentID: heldSegment, sessionID: heldSession, reason: "audio_writer_failed")
        )
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.state, .error(.unavailable(reason: "audio input unavailable")))
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
    }

    @MainActor
    func testImmediateConfigurationRestartWithNamedCodeStaysNeedsAttention() async {
        await self.manager.startSession(mode: .meeting)
        self.recorder.restartError = self.microphoneRefusal(
            .insufficientPriority,
            domain: "com.apple.coreaudio.avfaudio"
        )
        self.recorder.emitEngineFault(.configurationChange)
        await self.drainManagerTasks()

        XCTAssertEqual(self.manager.state, .error(.audioSessionConflict))
        XCTAssertNil(self.manager.microphoneTakenPause)
        XCTAssertEqual(self.recorder.restartCallCount, 1)
        XCTAssertEqual(self.liveActivity.endCalls.last?.reason, .system)
    }

    @MainActor
    func testOwnerStopThenCancellationDoesNotRestartCapture() async {
        let outcome = await self.manager.startSession(mode: .meeting)
        XCTAssertEqual(outcome, .started)

        let stopOutcome = await self.manager.stopSession()
        XCTAssertEqual(stopOutcome, .stopped)
        XCTAssertEqual(self.manager.state, .idle)

        // Attempting to cancel or trigger another stop does not restart capture
        let repeatStop = await self.manager.stopSession()
        XCTAssertEqual(repeatStop, .alreadyStopped)
        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.recorder.startCallCount, 1)
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

    @MainActor
    func audioPresentation(ownerPaused: Bool = false) -> AudioOwnerPresentation {
        audioOwnerPresentation(
            observerState: self.manager.state,
            ownerPaused: ownerPaused,
            enrolled: self.manager.isEnrolled,
            microphoneTaken: self.manager.microphoneTakenPause
        )
    }

    @MainActor
    func microphoneRefusal(_ code: AVAudioSession.ErrorCode, domain: String) -> NSError {
        NSError(domain: domain, code: code.rawValue)
    }

    @MainActor
    func enterHoldingPause(reason: ObserverInterruptionBeganReason, label: String) async {
        await self.manager.startSession(mode: .meeting)
        self.recorder.emitInterruption(.began(reason))
        await self.drainManagerTasks()
        XCTAssertEqual(self.manager.microphoneTakenPause, .holdingSession, label)
    }

    @MainActor
    func assertMicrophoneTakenPause(_ label: String) {
        XCTAssertEqual(self.manager.state, .microphoneTaken, label)
        XCTAssertEqual(self.manager.microphoneTakenPause, .stopped, label)
        let presentation = self.audioPresentation()
        XCTAssertEqual(presentation.sourceState, .paused, label)
        XCTAssertEqual(presentation.tileLine, SourceVocabulary.microphoneTakenSubtextCompact, label)
        XCTAssertEqual(presentation.detailLine, SourceVocabulary.microphoneTakenSubtext, label)
        if case .error = self.manager.state {
            XCTFail("pause is not a fault \(label)")
        }
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
