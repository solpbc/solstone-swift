// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import XCTest

nonisolated final class AudioPlaybackModelTests: XCTestCase {
    @MainActor
    func testInitialIdleMirrorsPlayer() {
        let player = MockAudioPlayer(currentTime: 2, duration: 10)
        let model = AudioPlaybackModel(
            player: player,
            session: MockObserverAudioSession(category: .soloAmbient),
            ticks: { AsyncStream { $0.finish() } }
        )

        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.elapsed, 2)
        XCTAssertEqual(model.duration, 10)
        XCTAssertEqual(model.progressFraction, 0.2, accuracy: 0.0001)
    }

    @MainActor
    func testPlaySetsPlaybackSessionAndTickAdvancesElapsed() async throws {
        let player = MockAudioPlayer(currentTime: 0, duration: 10)
        let session = MockObserverAudioSession(category: .soloAmbient)
        let ticks = ManualTicks()
        let model = AudioPlaybackModel(player: player, session: session, ticks: { ticks.stream })

        try model.play()

        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(player.isPlaying)
        XCTAssertEqual(player.playCalls, 1)
        XCTAssertEqual(session.categoryCalls, [.playback])
        XCTAssertEqual(session.activeCalls, [ActiveCall(active: true, options: [])])

        await Task.yield()
        player.currentTime = 2
        await ticks.yieldAndWait(until: { model.elapsed == 2 })

        XCTAssertEqual(model.elapsed, 2)
        XCTAssertEqual(model.progressFraction, 0.2, accuracy: 0.0001)
    }

    @MainActor
    func testSeekClampsAndUpdatesCurrentTime() {
        let player = MockAudioPlayer(currentTime: 0, duration: 10)
        let model = AudioPlaybackModel(
            player: player,
            session: MockObserverAudioSession(category: .soloAmbient),
            ticks: { AsyncStream { $0.finish() } }
        )

        model.seek(to: 12)
        XCTAssertEqual(player.seekCalls, [10])
        XCTAssertEqual(model.elapsed, 10)
        XCTAssertEqual(model.progressFraction, 1)

        model.seek(to: -3)
        XCTAssertEqual(player.seekCalls, [10, 0])
        XCTAssertEqual(model.elapsed, 0)
        XCTAssertEqual(model.progressFraction, 0)

        model.progressFraction = 0.5
        XCTAssertEqual(player.seekCalls, [10, 0, 5])
        XCTAssertEqual(model.elapsed, 5)
    }

    @MainActor
    func testPauseDeactivatesAndRestoresSavedCategory() throws {
        let player = MockAudioPlayer(currentTime: 0, duration: 10)
        let session = MockObserverAudioSession(category: .soloAmbient)
        let model = AudioPlaybackModel(
            player: player,
            session: session,
            ticks: { AsyncStream { $0.finish() } }
        )

        try model.play()
        model.pause()

        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.pauseCalls, 1)
        XCTAssertEqual(session.activeCalls, [
            ActiveCall(active: true, options: []),
            ActiveCall(active: false, options: .notifyOthersOnDeactivation),
        ])
        XCTAssertEqual(session.categoryCalls, [.playback, .soloAmbient])
        XCTAssertEqual(session.category, .soloAmbient)
    }

    @MainActor
    func testStopForDisappearDeactivatesAndRestoresSavedCategory() throws {
        let player = MockAudioPlayer(currentTime: 0, duration: 10)
        let session = MockObserverAudioSession(category: .soloAmbient)
        let model = AudioPlaybackModel(
            player: player,
            session: session,
            ticks: { AsyncStream { $0.finish() } }
        )

        try model.play()
        model.stopForDisappear()

        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(session.activeCalls, [
            ActiveCall(active: true, options: []),
            ActiveCall(active: false, options: .notifyOthersOnDeactivation),
        ])
        XCTAssertEqual(session.categoryCalls, [.playback, .soloAmbient])
    }

    @MainActor
    func testFinishRestoresSessionAndLeavesModelNotPlaying() async throws {
        let player = MockAudioPlayer(currentTime: 0, duration: 5)
        let session = MockObserverAudioSession(category: .soloAmbient)
        let ticks = ManualTicks()
        let model = AudioPlaybackModel(player: player, session: session, ticks: { ticks.stream })

        try model.play()
        await Task.yield()
        player.currentTime = 5
        await ticks.yieldAndWait(until: { !model.isPlaying })

        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.pauseCalls, 1)
        XCTAssertEqual(model.elapsed, 5)
        XCTAssertEqual(session.activeCalls, [
            ActiveCall(active: true, options: []),
            ActiveCall(active: false, options: .notifyOthersOnDeactivation),
        ])
        XCTAssertEqual(session.categoryCalls, [.playback, .soloAmbient])
    }

    @MainActor
    func testPlayAfterFinishSeeksToZeroBeforePlaying() throws {
        let player = MockAudioPlayer(currentTime: 10, duration: 10)
        let model = AudioPlaybackModel(
            player: player,
            session: MockObserverAudioSession(category: .soloAmbient),
            ticks: { AsyncStream { $0.finish() } }
        )

        try model.play()

        XCTAssertEqual(player.seekCalls.first, 0)
        XCTAssertTrue(model.isPlaying)
        XCTAssertEqual(player.playCalls, 1)
    }

    @MainActor
    func testRepeatedPlayDoesNotDuplicateSessionSetup() throws {
        let player = MockAudioPlayer(currentTime: 0, duration: 10)
        let session = MockObserverAudioSession(category: .soloAmbient)
        let model = AudioPlaybackModel(
            player: player,
            session: session,
            ticks: { AsyncStream { $0.finish() } }
        )

        try model.play()
        try model.play()

        XCTAssertEqual(player.playCalls, 1)
        XCTAssertEqual(session.categoryCalls, [.playback])
        XCTAssertEqual(session.activeCalls, [ActiveCall(active: true, options: [])])
    }

    @MainActor
    func testPlayFailureRestoresSessionAndLeavesNotPlaying() {
        let player = MockAudioPlayer(currentTime: 0, duration: 10)
        player.playError = AudioPlaybackError.playbackFailed
        let session = MockObserverAudioSession(category: .soloAmbient)
        let model = AudioPlaybackModel(
            player: player,
            session: session,
            ticks: { AsyncStream { $0.finish() } }
        )

        XCTAssertThrowsError(try model.play())

        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(player.isPlaying)
        XCTAssertEqual(player.pauseCalls, 1)
        XCTAssertEqual(session.activeCalls, [
            ActiveCall(active: true, options: []),
            ActiveCall(active: false, options: .notifyOthersOnDeactivation),
        ])
        XCTAssertEqual(session.categoryCalls, [.playback, .soloAmbient])
    }
}

@MainActor
private final class MockAudioPlayer: AudioPlaying {
    var isPlaying: Bool
    var currentTime: TimeInterval
    var duration: TimeInterval
    var playCalls = 0
    var pauseCalls = 0
    var seekCalls: [TimeInterval] = []
    var playError: Error?

    init(currentTime: TimeInterval, duration: TimeInterval, isPlaying: Bool = false) {
        self.currentTime = currentTime
        self.duration = duration
        self.isPlaying = isPlaying
    }

    func play() throws {
        if let playError {
            throw playError
        }
        self.playCalls += 1
        self.isPlaying = true
    }

    func pause() {
        self.pauseCalls += 1
        self.isPlaying = false
    }

    func seek(to time: TimeInterval) {
        self.seekCalls.append(time)
        self.currentTime = time
    }
}

private struct ActiveCall: Equatable {
    let active: Bool
    let options: AVAudioSession.SetActiveOptions
}

@MainActor
private final class MockObserverAudioSession: ObserverAudioSession {
    var category: AVAudioSession.Category
    private(set) var categoryCalls: [AVAudioSession.Category] = []
    private(set) var activeCalls: [ActiveCall] = []

    init(category: AVAudioSession.Category) {
        self.category = category
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode _: AVAudioSession.Mode,
        options _: AVAudioSession.CategoryOptions
    ) throws {
        self.categoryCalls.append(category)
        self.category = category
    }

    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        self.activeCalls.append(ActiveCall(active: active, options: options))
    }
}

@MainActor
private final class ManualTicks: @unchecked Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var captured: AsyncStream<Void>.Continuation?
        self.stream = AsyncStream { continuation in
            captured = continuation
        }
        self.continuation = captured!
    }

    func yieldAndWait(until condition: @MainActor () -> Bool) async {
        for _ in 0..<10 {
            self.continuation.yield(())
            await Task.yield()
            if condition() {
                return
            }
        }
    }
}
