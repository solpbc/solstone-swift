// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import AVFoundation
import Foundation

@MainActor
final class IntegrationTestObserverRecorder: ObserverRecording {
    var onMeter: (@Sendable (Float, TimeInterval) -> Void)?
    var onInterruption: (@Sendable (ObserverInterruptionEvent) -> Void)?

    private let session: any ObserverAudioSession
    private let permissionGranted: Bool
    private var currentURL: URL?
    private var currentStartedAt: Date?
    private var didActivateSession = false

    init(
        session: any ObserverAudioSession = AVAudioSession.sharedInstance(),
        permissionGranted: Bool = true
    ) {
        self.session = session
        self.permissionGranted = permissionGranted
    }

    func requestPermission() async -> Bool {
        self.permissionGranted
    }

    func start(url: URL, mode _: ObserverMode) async throws -> ObserverRecordingStartResult {
        self.didActivateSession = try ObserverAudioActivator.ensureActiveRecordSession(self.session)

        try Self.writePlaceholderFile(to: url)
        self.currentURL = url
        self.currentStartedAt = Date()
        return ObserverRecordingStartResult(didActivateSession: self.didActivateSession)
    }

    func rotate(to url: URL) async throws -> ObserverRecordedChunk? {
        let finalized = self.finalizeCurrentChunk()
        try Self.writePlaceholderFile(to: url)
        self.currentURL = url
        self.currentStartedAt = Date()
        return finalized
    }

    func stop() async throws -> ObserverRecordedChunk? {
        let finalized = self.finalizeCurrentChunk()
        if self.didActivateSession {
            try? self.session.setActive(false, options: [])
        }
        self.didActivateSession = false
        self.currentURL = nil
        self.currentStartedAt = nil
        return finalized
    }

    func pause() async {}

    func resume() async throws {}
}

private extension IntegrationTestObserverRecorder {
    func finalizeCurrentChunk() -> ObserverRecordedChunk? {
        guard let currentURL, let currentStartedAt else { return nil }
        return ObserverRecordedChunk(url: currentURL, duration: max(Date().timeIntervalSince(currentStartedAt), 1))
    }

    static func writePlaceholderFile(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("solstone-observer".utf8).write(to: url, options: .atomic)
    }
}
#endif
