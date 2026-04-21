// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let log = Logger(subsystem: "app.solstone.swift", category: "brain")

enum BrainStatus: Sendable, Equatable {
    case ready
    case refreshing
    case answering
    case unavailable
}

@Observable
final class BrainStatusMonitor {
    var status: BrainStatus = .unavailable
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    init(diagnosticLog: DiagnosticLog? = nil) {
        self.diagnosticLog = diagnosticLog
    }

    func update(from jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            self.setStatus(.unavailable)
            return
        }
        switch payload.status {
        case "ready", "idle":
            self.setStatus(.ready)
        case "refreshing":
            self.setStatus(.refreshing)
        case "answering":
            self.setStatus(.answering)
        default:
            self.setStatus(.unavailable)
        }
    }

    func reset() {
        self.setStatus(.unavailable)
    }

    func startPolling(localPort: Int) {
        self.stopPolling()
        self.pollingTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                await self.refreshStatus(localPort: localPort)
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
            }
        }
    }

    func stopPolling() {
        self.pollingTask?.cancel()
        self.pollingTask = nil
        self.setStatus(.unavailable)
    }
}

private extension BrainStatusMonitor {
    func setStatus(_ newStatus: BrainStatus) {
        let oldStatus = self.status
        self.status = newStatus

        if oldStatus != self.status {
            log.info("[solstone-swift] brain: status \(String(describing: self.status))")
            let severity: DiagnosticSeverity = self.status == .unavailable ? .warning : .info
            self.diagnosticLog?.append(
                category: .brain,
                severity: severity,
                message: "brain: \(oldStatus) → \(self.status)"
            )
        }
    }

    func refreshStatus(localPort: Int) async {
        guard let url = VoiceServerURL.url(localPort: localPort, path: "/api/voice/status") else {
            self.setStatus(.unavailable)
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                self.setStatus(.unavailable)
                return
            }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try decoder.decode(StatusPayload.self, from: data)
            self.setStatus(payload.brainReady ? .ready : .refreshing)
        } catch {
            self.setStatus(.unavailable)
        }
    }

    struct Payload: Decodable {
        let status: String
    }

    struct StatusPayload: Decodable {
        let brainReady: Bool
        let brainAgeSeconds: Int
    }
}
