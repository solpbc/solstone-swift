// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class VoiceManagerTests: XCTestCase {
    private var mockKeyFetcher = MockEphemeralKeyFetcher()
    private var mockWebRTC = MockWebRTCConnector()
    private var mockSideband = MockSidebandNotifier()
    private var mockNavHintPoller = MockNavHintPoller()
    @MainActor private var appliedNavHints: [String] = []
    private var manager = VoiceManager(
        keyFetcher: MockEphemeralKeyFetcher(),
        sidebandNotifier: MockSidebandNotifier(),
        navHintPoller: MockNavHintPoller(),
        webrtc: MockWebRTCConnector()
    )

    override func setUp() {
        UserDefaults.standard.removeObject(forKey: "verboseErrors")
        VoiceSession.clearDefaults()
        self.mockKeyFetcher = MockEphemeralKeyFetcher()
        self.mockWebRTC = MockWebRTCConnector()
        self.mockSideband = MockSidebandNotifier()
        self.mockNavHintPoller = MockNavHintPoller()
        self.appliedNavHints = []
        self.manager = VoiceManager(
            keyFetcher: self.mockKeyFetcher,
            sidebandNotifier: self.mockSideband,
            navHintPoller: self.mockNavHintPoller,
            webrtc: self.mockWebRTC,
            onNavHint: { @MainActor [weak self] hint in
                self?.appliedNavHints.append(hint)
            }
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "verboseErrors")
        VoiceSession.clearDefaults()
    }

    func testInitialState() {
        XCTAssertEqual(self.manager.state, .idle)
    }

    func testVoiceErrorUserMessages() {
        UserDefaults.standard.set(false, forKey: "verboseErrors")
        XCTAssertEqual(VoiceError.microphoneDenied.userMessage, "microphone access is required for voice conversations — enable it in Settings")
        XCTAssertEqual(VoiceError.ephemeralKeyFailed("detail").userMessage, "detail")
        XCTAssertEqual(VoiceError.connectionFailed("detail").userMessage, "voice connection failed")
        XCTAssertEqual(VoiceError.sessionEnded.userMessage, "voice session ended unexpectedly")
        UserDefaults.standard.removeObject(forKey: "verboseErrors")
    }

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

    func testEndSessionCleansUp() {
        self.manager.endSession()

        XCTAssertEqual(self.manager.state, .idle)
        XCTAssertEqual(self.mockWebRTC.disconnectCallCount, 1)
    }

    func testStartSessionGuardNotIdle() async {
        self.manager.state = .connecting

        await self.manager.startSession(localPort: 7071)

        XCTAssertEqual(self.mockKeyFetcher.fetchCallCount, 0)
        XCTAssertEqual(self.manager.state, .connecting)
    }

    func testStartSessionConnectsWebRTC() async {
        await self.manager.startSession(localPort: 7071)

        XCTAssertEqual(self.mockWebRTC.connectCallCount, 1)
        XCTAssertEqual(self.manager.state, .listening)
    }

    func testStartSessionNotifiesSideband() async {
        await self.manager.startSession(localPort: 7071)

        for _ in 0..<10 where self.mockSideband.notifyCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(self.mockSideband.notifyCallCount, 1)
        XCTAssertEqual(self.mockSideband.lastCallId, "test-call-id")
        XCTAssertEqual(self.mockSideband.lastLocalPort, 7071)
    }

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

    func testLastSessionPopulatedOnError() async {
        self.mockKeyFetcher.result = .failure(NSError(domain: "test", code: 1))

        await self.manager.startSession(localPort: 7071)

        XCTAssertNotNil(self.manager.lastSession)
        XCTAssertNotNil(self.manager.lastSession?.endTime)
        XCTAssertNotNil(self.manager.lastSession?.errorDetail)
        XCTAssertFalse(self.manager.lastSession?.endedNormally == true)
    }

    func testVerboseErrorMessages() {
        UserDefaults.standard.set(true, forKey: "verboseErrors")
        XCTAssertTrue(VoiceError.connectionFailed("timeout").userMessage.contains("timeout"))
        XCTAssertTrue(VoiceError.ephemeralKeyFailed("auth error").userMessage.contains("auth error"))

        UserDefaults.standard.set(false, forKey: "verboseErrors")
        XCTAssertFalse(VoiceError.connectionFailed("timeout").userMessage.contains("timeout"))
        XCTAssertEqual(VoiceError.ephemeralKeyFailed("auth error").userMessage, "auth error")

        UserDefaults.standard.removeObject(forKey: "verboseErrors")
    }

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

    func testTunnelErrorVerboseMessages() {
        UserDefaults.standard.set(true, forKey: "verboseErrors")
        XCTAssertTrue(TunnelError.unknown("socket reset").userMessage.contains("socket reset"))

        UserDefaults.standard.set(false, forKey: "verboseErrors")
        XCTAssertFalse(TunnelError.unknown("socket reset").userMessage.contains("socket reset"))

        UserDefaults.standard.removeObject(forKey: "verboseErrors")
    }

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

    func testToolCallCompletedFetchesAndAppliesHints() async {
        self.mockNavHintPoller.hints = ["today", "ask"]

        await self.manager.startSession(localPort: 7071)
        self.mockWebRTC.eventContinuation?.yield(.toolCallCompleted)

        for _ in 0..<40 where self.mockNavHintPoller.fetchCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<60 where await MainActor.run(body: { self.appliedNavHints.count }) != 2 {
            try? await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(self.mockNavHintPoller.fetchCallCount, 1)
        XCTAssertEqual(self.mockNavHintPoller.lastLocalPort, 7071)
        XCTAssertEqual(self.mockNavHintPoller.lastCallId, "test-call-id")
        let appliedHints = await MainActor.run { self.appliedNavHints }
        XCTAssertEqual(appliedHints, ["today", "ask"])
    }

    func testToolCallCompletedSkipsFetchWhenCallIdMissing() async {
        self.mockWebRTC.callId = ""

        await self.manager.startSession(localPort: 7071)
        self.mockWebRTC.eventContinuation?.yield(.toolCallCompleted)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(self.mockNavHintPoller.fetchCallCount, 0)
        let appliedHints = await MainActor.run { self.appliedNavHints }
        XCTAssertEqual(appliedHints, [])
    }

    func testIdleTimerEndsSessionWithoutEvents() async {
        let manager = VoiceManager(
            keyFetcher: self.mockKeyFetcher,
            sidebandNotifier: self.mockSideband,
            navHintPoller: self.mockNavHintPoller,
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

    func testIdleTimerRearmsWhenEventsArrive() async {
        let manager = VoiceManager(
            keyFetcher: self.mockKeyFetcher,
            sidebandNotifier: self.mockSideband,
            navHintPoller: self.mockNavHintPoller,
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
