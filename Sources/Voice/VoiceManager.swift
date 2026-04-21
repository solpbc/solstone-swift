// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "voice")

@Observable
final class VoiceManager {
    var state: VoiceState = .idle
    @ObservationIgnored var onObserverAction: (@MainActor @Sendable (ObserverAction) -> Void)?
    @ObservationIgnored private let keyFetcher: any EphemeralKeyFetching
    @ObservationIgnored private let sidebandNotifier: any SidebandNotifying
    @ObservationIgnored private let navHintPoller: any NavHintPolling
    @ObservationIgnored private let observerActionPoller: any ObserverActionPolling
    @ObservationIgnored private let webrtc: any WebRTCConnecting
    @ObservationIgnored private let onNavHint: @MainActor @Sendable (String) -> Void
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    // OpenAI Realtime keeps the peer connection open indefinitely; client owns owner-facing idle.
    @ObservationIgnored private let voiceIdleTimeout: Duration = .seconds(300)
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var activeLocalPort: Int?
    @ObservationIgnored private let idleTimeoutOverride: Duration?
    private(set) var lastSession: VoiceSession?

    init(
        keyFetcher: any EphemeralKeyFetching = EphemeralKeyFetcher(),
        sidebandNotifier: any SidebandNotifying = SidebandNotifier(),
        navHintPoller: any NavHintPolling = NavHintPoller(),
        observerActionPoller: any ObserverActionPolling = ObserverActionPoller(),
        webrtc: any WebRTCConnecting = WebRTCManager(),
        onNavHint: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        idleTimeoutOverride: Duration? = nil,
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.keyFetcher = keyFetcher
        self.sidebandNotifier = sidebandNotifier
        self.navHintPoller = navHintPoller
        self.observerActionPoller = observerActionPoller
        self.webrtc = webrtc
        self.onNavHint = onNavHint
        self.idleTimeoutOverride = idleTimeoutOverride
        self.diagnosticLog = diagnosticLog
        self.lastSession = VoiceSession.loadFromDefaults()
    }

    func startSession(localPort: Int) async {
        switch self.state {
        case .idle, .error:
            break
        case .connecting, .listening, .speaking:
            return
        }

        log.info("[solstone-swift] voice session starting on port \(localPort)")
        self.diagnosticLog?.append(category: .voice, message: "session starting on port \(localPort)")
        self.state = .connecting
        self.lastSession = VoiceSession(startTime: Date())
        self.lastSession?.saveToDefaults()

        let key: String
        do {
            key = try await self.keyFetcher.fetchKey(localPort: localPort)
            self.diagnosticLog?.append(category: .voice, message: "ephemeral key fetched")
        } catch {
            let detail: String
            let voiceError: VoiceError
            if case .ephemeralKeyFailed(let message) = error as? VoiceError {
                detail = message
                voiceError = .ephemeralKeyFailed(message)
            } else {
                detail = String(describing: error)
                voiceError = .ephemeralKeyFailed(detail)
            }
            log.error("[solstone-swift] failed to fetch voice key: \(detail)")
            self.diagnosticLog?.append(category: .voice, severity: .error, message: "key fetch failed", detail: detail)
            if case .connecting = self.state {
                self.state = .error(voiceError)
                self.lastSession?.endTime = Date()
                self.lastSession?.errorDetail = detail
                self.lastSession?.saveToDefaults()
            }
            return
        }

        guard case .connecting = self.state else { return }

        do {
            let (callId, events) = try await self.webrtc.connect(ephemeralKey: key)
            guard case .connecting = self.state else {
                self.webrtc.disconnect()
                return
            }

            self.lastSession?.callId = callId

            Task {
                await self.sidebandNotifier.notify(callId: callId, localPort: localPort)
            }

            self.state = .listening
            self.activeLocalPort = localPort
            log.info("[solstone-swift] listening")
            self.diagnosticLog?.append(category: .voice, message: "listening")
            self.lastSession?.saveToDefaults()
            self.resetIdleTimer()
            self.startObserving(events)
        } catch {
            let voiceError = self.map(error)
            let detail = String(describing: error)
            log.error("[solstone-swift] voice connect failed: \(detail)")
            self.diagnosticLog?.append(category: .voice, severity: .error, message: "connection failed", detail: detail)
            self.cleanup()
            self.state = .error(voiceError)
            self.lastSession?.endTime = Date()
            self.lastSession?.errorDetail = detail
            self.lastSession?.saveToDefaults()
        }
    }

    func endSession() {
        let wasActive = self.state != .idle
        self.cleanup()
        self.state = .idle
        if wasActive {
            self.lastSession?.endTime = Date()
            self.lastSession?.saveToDefaults()
            let duration = self.lastSession?.duration
            let durationStr = duration.map { String(format: "%.1fs", $0) } ?? "unknown"
            self.diagnosticLog?.append(category: .voice, message: "session ended (\(durationStr))")
        }
    }
}

private extension VoiceManager {
    func startObserving(_ events: AsyncStream<DataChannelEvent>) {
        self.eventTask?.cancel()
        self.eventTask = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                self.resetIdleTimer()
                switch event {
                case .modelSpeakingStarted:
                    if self.state != .speaking {
                        self.state = .speaking
                        log.info("[solstone-swift] speaking")
                        self.diagnosticLog?.append(category: .voice, message: "speaking")
                    }
                case .modelSpeakingStopped:
                    if self.state != .listening {
                        self.state = .listening
                        log.info("[solstone-swift] listening")
                        self.diagnosticLog?.append(category: .voice, message: "listening")
                    }
                case .userSpeechStarted, .userSpeechStopped:
                    break
                case .toolCallCompleted:
                    self.handleToolCallCompleted()
                case .disconnected:
                    self.endSession()
                    return
                }
            }
        }
    }

    func cleanup() {
        self.eventTask?.cancel()
        self.eventTask = nil
        self.idleTimer?.cancel()
        self.idleTimer = nil
        self.activeLocalPort = nil
        self.webrtc.disconnect()
    }

    func map(_ error: any Error) -> VoiceError {
        let description = String(describing: error)
        // Apple AVAudioSession error text — keep literal.
        if description.localizedCaseInsensitiveContains("microphone")
            || description.localizedCaseInsensitiveContains("record permission")
        {
            return .microphoneDenied
        }
        return .connectionFailed(description)
    }

    func resetIdleTimer() {
        self.idleTimer?.cancel()
        self.idleTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.idleTimeoutOverride ?? self?.voiceIdleTimeout ?? .zero)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            self.endSession()
        }
    }

    func handleToolCallCompleted() {
        guard let callId = self.lastSession?.callId,
              !callId.isEmpty,
              let localPort = self.activeLocalPort
        else { return }

        Task { [weak self] in
            guard let self else { return }
            async let hints = self.navHintPoller.fetch(localPort: localPort, callId: callId)
            async let actions = self.observerActionPoller.fetchActions(localPort: localPort, callId: callId)
            let (hintsResult, actionsResult) = await (hints, actions)

            for action in actionsResult {
                guard self.state != .idle,
                      self.lastSession?.callId == callId
                else { return }

                switch action {
                case .startObserver(let mode):
                    log.info("voice-observer-action received: start_observer mode=\(mode.rawValue, privacy: .public)")
                }

                await MainActor.run {
                    self.onObserverAction?(action)
                }
            }

            guard !hintsResult.isEmpty else { return }

            for (index, hint) in hintsResult.enumerated() {
                guard self.state != .idle,
                      self.lastSession?.callId == callId
                else { return }

                await MainActor.run {
                    self.onNavHint(hint)
                }

                if index < hintsResult.count - 1 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }
}
