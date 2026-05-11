// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class VoiceManagerTests: XCTestCase {
    private var mockKeyFetcher = MockEphemeralKeyFetcher()
    private var mockWebRTC = MockWebRTCConnector()
    private var mockSideband = MockSidebandNotifier()
    private var mockNavHintPoller = MockNavHintPoller()
    private var mockObserverActionPoller = MockObserverActionPoller()
    private let appliedNavHints = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let appliedObserverActions = OSAllocatedUnfairLock<[ObserverAction]>(initialState: [])
    @MainActor private lazy var manager: VoiceManager = {
        let manager = VoiceManager(
            keyFetcher: self.mockKeyFetcher,
            sidebandNotifier: self.mockSideband,
            navHintPoller: self.mockNavHintPoller,
            observerActionPoller: self.mockObserverActionPoller,
            webrtc: self.mockWebRTC,
            onNavHint: { @MainActor [appliedNavHints] hint in
                appliedNavHints.withLock { $0.append(hint) }
            }
        )
        manager.onObserverAction = { @MainActor [appliedObserverActions] action in
            appliedObserverActions.withLock { $0.append(action) }
        }
        return manager
    }()

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "verboseErrors")
        VoiceSession.clearDefaults()
        self.mockKeyFetcher = MockEphemeralKeyFetcher()
        self.mockWebRTC = MockWebRTCConnector()
        self.mockSideband = MockSidebandNotifier()
        self.mockNavHintPoller = MockNavHintPoller()
        self.mockObserverActionPoller = MockObserverActionPoller()
        self.appliedNavHints.withLock { $0 = [] }
        self.appliedObserverActions.withLock { $0 = [] }
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "verboseErrors")
        VoiceSession.clearDefaults()
    }

    @MainActor
    func testInitialState() {
        XCTAssertEqual(self.manager.state, .idle)
    }

    @MainActor
    func testVoiceErrorUserMessages() {
        UserDefaults.standard.set(false, forKey: "verboseErrors")
        XCTAssertEqual(VoiceError.microphoneDenied.userMessage, "microphone access is required for voice conversations — enable it in Settings")
        XCTAssertEqual(VoiceError.ephemeralKeyFailed("detail").userMessage, "detail")
        XCTAssertEqual(VoiceError.connectionFailed("detail").userMessage, "voice connection failed")
        XCTAssertEqual(VoiceError.sessionEnded.userMessage, "voice session ended unexpectedly")
        UserDefaults.standard.removeObject(forKey: "verboseErrors")
    }

    @MainActor
    func testStartSessionKeyFetchFails() async {
        self.mockKeyFetcher.result = .failure(NSError(domain: "VoiceManagerTests", code: 1))

        await self.manager.startSession(localPort: 7071)

        if case .error(.ephemeralKeyFailed(_)) = self.manager.state {
        } else {
            XCTFail("Expected ephemeralKeyFailed error, got \(self.manager.state)")
        }
        XCTAssertEqual(self.mockKeyFetcher.fetchCallCount, 1)
        XCTAssertEqual(self.mockWebRTC.connectCallCount, 0)
    }

    @MainActor
    func testStartSessionSuccessSetsConnectingBeforeFetchCompletes() async {
        self.mockKeyFetcher.delay = .milliseconds(200)

        let task = Task {
            await self.manager.startSession(localPort: 7071)
        }

        await Task.yield()
        XCTAssertEqual(self.manager.state, .connecting)

        for _ in 0..<10 where self.mockKeyFetcher.fetchCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(self.mockKeyFetcher.fetchCallCount, 1)

        self.manager.endSession()
        await task.value

        XCTAssertEqual(self.manager.state, .idle)
    }

    @MainActor
    func testEndSessionCleansUp() {
        self.manager.endSession()

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.mockWebRTC.disconnectCallCount, 1)
    }

    @MainActor
    func testStartSessionGuardNotIdle() async {
        self.manager.state = .connecting

        await self.manager.startSession(localPort: 7071)

        XCTAssertEqual(self.mockKeyFetcher.fetchCallCount, 0)
        XCTAssertEqual(self.manager.state, .connecting)
    }

    @MainActor
    func testStartSessionConnectsWebRTC() async {
        await self.manager.startSession(localPort: 7071)

        XCTAssertEqual(self.mockWebRTC.connectCallCount, 1)
        XCTAssertEqual(self.manager.state, .listening)
    }

    @MainActor
    func testStartSessionNotifiesSideband() async {
        await self.manager.startSession(localPort: 7071)

        for _ in 0..<10 where self.mockSideband.notifyCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(self.mockSideband.notifyCallCount, 1)
        XCTAssertEqual(self.mockSideband.lastCallId, "test-call-id")
        XCTAssertEqual(self.mockSideband.lastLocalPort, 7071)
    }

    @MainActor
    func testWebRTCConnectFails() async {
        self.mockWebRTC.connectError = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "connection refused"]
        )

        await self.manager.startSession(localPort: 7071)

        if case .error(.connectionFailed) = self.manager.state {
        } else {
            XCTFail("Expected connectionFailed error, got \(self.manager.state)")
        }
    }

    @MainActor
    func testLastSessionPopulatedAfterSession() async {
        await self.manager.startSession(localPort: 7071)
        XCTAssertNotNil(self.manager.lastSession)
        XCTAssertEqual(self.manager.lastSession?.callId, "test-call-id")
        XCTAssertNil(self.manager.lastSession?.endTime)

        self.manager.endSession()
        XCTAssertNotNil(self.manager.lastSession?.endTime)
        XCTAssertNil(self.manager.lastSession?.errorDetail)
        XCTAssertTrue(self.manager.lastSession?.endedNormally == true)
    }

    @MainActor
    func testLastSessionPopulatedOnError() async {
        self.mockKeyFetcher.result = .failure(NSError(domain: "test", code: 1))

        await self.manager.startSession(localPort: 7071)

        XCTAssertNotNil(self.manager.lastSession)
        XCTAssertNotNil(self.manager.lastSession?.endTime)
        XCTAssertNotNil(self.manager.lastSession?.errorDetail)
        XCTAssertFalse(self.manager.lastSession?.endedNormally == true)
    }

    @MainActor
    func testVerboseErrorMessages() {
        UserDefaults.standard.set(true, forKey: "verboseErrors")
        XCTAssertTrue(VoiceError.connectionFailed("timeout").userMessage.contains("timeout"))
        XCTAssertTrue(VoiceError.ephemeralKeyFailed("auth error").userMessage.contains("auth error"))

        UserDefaults.standard.set(false, forKey: "verboseErrors")
        XCTAssertFalse(VoiceError.connectionFailed("timeout").userMessage.contains("timeout"))
        XCTAssertEqual(VoiceError.ephemeralKeyFailed("auth error").userMessage, "auth error")

        UserDefaults.standard.removeObject(forKey: "verboseErrors")
    }

    @MainActor
    func testVoiceSessionPersistenceRoundTrip() {
        var session = VoiceSession(startTime: Date())
        session.endTime = Date()
        session.callId = "test-call-123"
        session.errorDetail = nil
        session.saveToDefaults()

        let loaded = VoiceSession.loadFromDefaults()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.callId, "test-call-123")
        XCTAssertNotNil(loaded?.endTime)
        XCTAssertNil(loaded?.errorDetail)
        XCTAssertTrue(loaded?.endedNormally == true)

        VoiceSession.clearDefaults()
        XCTAssertNil(VoiceSession.loadFromDefaults())
    }

    @MainActor
    func testTunnelErrorVerboseMessages() {
        UserDefaults.standard.set(true, forKey: "verboseErrors")
        XCTAssertTrue(TunnelError.unknown("socket reset").userMessage.contains("socket reset"))

        UserDefaults.standard.set(false, forKey: "verboseErrors")
        XCTAssertFalse(TunnelError.unknown("socket reset").userMessage.contains("socket reset"))

        UserDefaults.standard.removeObject(forKey: "verboseErrors")
    }

    @MainActor
    func testModelSpeakingEvents() async {
        await self.manager.startSession(localPort: 7071)
        XCTAssertEqual(self.manager.state, .listening)

        self.mockWebRTC.eventContinuation?.yield(.modelSpeakingStarted)
        for _ in 0..<20 where self.manager.state != .speaking {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(self.manager.state, .speaking)

        self.mockWebRTC.eventContinuation?.yield(.modelSpeakingStopped)
        for _ in 0..<20 where self.manager.state != .listening {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(self.manager.state, .listening)
    }

    @MainActor
    func testModelSpeakingStoppedDoesNotEndSession() async {
        await self.manager.startSession(localPort: 7071)
        XCTAssertEqual(self.manager.state, .listening)

        self.mockWebRTC.eventContinuation?.yield(.modelSpeakingStarted)
        for _ in 0..<20 where self.manager.state != .speaking {
            try? await Task.sleep(for: .milliseconds(10))
        }

        self.mockWebRTC.eventContinuation?.yield(.modelSpeakingStopped)
        for _ in 0..<20 where self.manager.state != .listening {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(self.manager.state, .listening)
        XCTAssertEqual(self.mockWebRTC.disconnectCallCount, 0)
    }

    @MainActor
    func testToolCallCompletedFetchesAndAppliesHints() async {
        self.mockNavHintPoller.hints = ["today", "ask"]

        await self.manager.startSession(localPort: 7071)
        self.mockWebRTC.eventContinuation?.yield(.toolCallCompleted)

        for _ in 0..<40 where self.mockNavHintPoller.fetchCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<60 where self.appliedNavHints.withLock({ $0.count }) != 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(self.mockNavHintPoller.fetchCallCount, 1)
        XCTAssertEqual(self.mockNavHintPoller.lastLocalPort, 7071)
        XCTAssertEqual(self.mockNavHintPoller.lastCallId, "test-call-id")
        let appliedHints = self.appliedNavHints.withLock { $0 }
        XCTAssertEqual(appliedHints, ["today", "ask"])
        XCTAssertEqual(self.mockObserverActionPoller.fetchCallCount, 1)
    }

    @MainActor
    func testToolCallCompletedDispatchesObserverActions() async {
        self.mockObserverActionPoller.actions = [.startObserver(mode: .voiceMemo)]

        await self.manager.startSession(localPort: 7071)
        self.mockWebRTC.eventContinuation?.yield(.toolCallCompleted)

        for _ in 0..<40 where self.mockObserverActionPoller.fetchCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<40 where self.appliedObserverActions.withLock({ $0.count }) != 1 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(self.mockObserverActionPoller.fetchCallCount, 1)
        XCTAssertEqual(self.mockObserverActionPoller.lastLocalPort, 7071)
        XCTAssertEqual(self.mockObserverActionPoller.lastCallId, "test-call-id")
        let appliedActions = self.appliedObserverActions.withLock { $0 }
        XCTAssertEqual(appliedActions, [.startObserver(mode: .voiceMemo)])
    }

    @MainActor
    func testToolCallCompletedSkipsFetchWhenCallIdMissing() async {
        self.mockWebRTC.callId = ""

        await self.manager.startSession(localPort: 7071)
        self.mockWebRTC.eventContinuation?.yield(.toolCallCompleted)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(self.mockNavHintPoller.fetchCallCount, 0)
        XCTAssertEqual(self.mockObserverActionPoller.fetchCallCount, 0)
        let appliedHints = self.appliedNavHints.withLock { $0 }
        XCTAssertEqual(appliedHints, [])
        let appliedActions = self.appliedObserverActions.withLock { $0 }
        XCTAssertEqual(appliedActions, [])
    }

    @MainActor
    func testIdleTimerEndsSessionWithoutEvents() async {
        let manager = VoiceManager(
            keyFetcher: self.mockKeyFetcher,
            sidebandNotifier: self.mockSideband,
            navHintPoller: self.mockNavHintPoller,
            observerActionPoller: self.mockObserverActionPoller,
            webrtc: self.mockWebRTC,
            idleTimeoutOverride: .milliseconds(50)
        )

        await manager.startSession(localPort: 7071)
        XCTAssertEqual(manager.state, .listening)

        for _ in 0..<30 where manager.state != .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testIdleTimerRearmsWhenEventsArrive() async {
        let manager = VoiceManager(
            keyFetcher: self.mockKeyFetcher,
            sidebandNotifier: self.mockSideband,
            navHintPoller: self.mockNavHintPoller,
            observerActionPoller: self.mockObserverActionPoller,
            webrtc: self.mockWebRTC,
            idleTimeoutOverride: .milliseconds(100)
        )

        await manager.startSession(localPort: 7071)
        XCTAssertEqual(manager.state, .listening)

        try? await Task.sleep(for: .milliseconds(60))
        self.mockWebRTC.eventContinuation?.yield(.userSpeechStarted)
        try? await Task.sleep(for: .milliseconds(60))
        XCTAssertNotEqual(manager.state, .idle)

        for _ in 0..<30 where manager.state != .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(manager.state, .idle)
    }

    @MainActor
    func testDisconnectedEvent() async {
        await self.manager.startSession(localPort: 7071)
        XCTAssertEqual(self.manager.state, .listening)

        self.mockWebRTC.eventContinuation?.yield(.disconnected)
        for _ in 0..<20 where self.manager.state != .idle {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.mockWebRTC.disconnectCallCount, 1)
    }

    @MainActor
    func testEndSessionStopsEventObservation() async {
        await self.manager.startSession(localPort: 7071)
        XCTAssertEqual(self.manager.state, .listening)

        self.manager.endSession()
        XCTAssertEqual(self.manager.state, .idle)

        self.mockWebRTC.eventContinuation?.yield(.modelSpeakingStarted)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(self.manager.state, .idle)
    }
}
