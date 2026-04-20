// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import os

private let log = Logger(subsystem: "org.solpbc.solstone-swift", category: "brain")

enum BrainStatus: Sendable, Equatable {
    case idle
    case refreshing
    case answering
    case unavailable
}

@Observable
final class BrainStatusMonitor {
    var status: BrainStatus = .unavailable
    @ObservationIgnored private let diagnosticLog: DiagnosticLog?

    init(diagnosticLog: DiagnosticLog? = nil) {
        self.diagnosticLog = diagnosticLog
    }

    func update(from jsonString: String) {
        let oldStatus = self.status
        guard let data = jsonString.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            self.status = .unavailable
            return
        }
        switch payload.status {
        case "ready", "idle":
            self.status = .idle
        case "refreshing":
            self.status = .refreshing
        case "answering":
            self.status = .answering
        default:
            self.status = .unavailable
        }
        if oldStatus != self.status {
            log.info("[solstone-swift] brain status: \(String(describing: oldStatus)) → \(String(describing: self.status))")
            let severity: DiagnosticSeverity = self.status == .unavailable ? .warning : .info
            self.diagnosticLog?.append(
                category: .brain,
                severity: severity,
                message: "brain: \(oldStatus) → \(self.status)"
            )
        }
    }

    func reset() {
        if self.status != .unavailable {
            self.diagnosticLog?.append(category: .brain, severity: .warning, message: "brain: unavailable")
        }
        self.status = .unavailable
    }
}

private extension BrainStatusMonitor {
    struct Payload: Decodable {
        let status: String
    }
}
