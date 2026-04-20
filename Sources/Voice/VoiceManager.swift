// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "voice")

@Observable
final class VoiceManager {
    var state: VoiceState = .idle
    @ObservationIgnored private let keyFetcher: any EphemeralKeyFetching
    @ObservationIgnored private let sidebandNotifier: any SidebandNotifying
    @ObservationIgnored private let webrtc: any WebRTCConnecting
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    private(set) var lastSession: VoiceSession?

    init(
        keyFetcher: any EphemeralKeyFetching = EphemeralKeyFetcher(),
        sidebandNotifier: any SidebandNotifying = SidebandNotifier(),
        webrtc: any WebRTCConnecting = WebRTCManager(),
        diagnosticLog: DiagnosticLog? = nil
    ) {
        self.keyFetcher = keyFetcher
        self.sidebandNotifier = sidebandNotifier
        self.webrtc = webrtc
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
            let detail = String(describing: error)
            log.error("[solstone-swift] failed to fetch voice key: \(detail)")
            self.diagnosticLog?.append(category: .voice, severity: .error, message: "key fetch failed", detail: detail)
            if case .connecting = self.state {
                self.state = .error(.ephemeralKeyFailed(detail))
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
            self.diagnosticLog?.append(category: .voice, message: "listening")
            self.lastSession?.saveToDefaults()
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
                switch event {
                case .modelSpeakingStarted:
                    if self.state != .speaking {
                        self.state = .speaking
                        self.diagnosticLog?.append(category: .voice, message: "speaking")
                    }
                case .modelSpeakingStopped:
                    if self.state != .listening {
                        self.state = .listening
                        self.diagnosticLog?.append(category: .voice, message: "listening")
                    }
                case .userSpeechStarted, .userSpeechStopped:
                    break
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
}
