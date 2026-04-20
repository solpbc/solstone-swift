// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UIKit

@Observable
final class DiagnosticLog {
    private(set) var events: [DiagnosticEvent] = []
    private let capacity: Int

    init(capacity: Int = 200) {
        self.capacity = capacity
    }

    func append(_ event: DiagnosticEvent) {
        self.events.append(event)
        if self.events.count > self.capacity {
            self.events.removeFirst(self.events.count - self.capacity)
        }
    }

    func append(
        category: DiagnosticCategory,
        severity: DiagnosticSeverity = .info,
        message: String,
        detail: String? = nil
    ) {
        self.append(DiagnosticEvent(
            category: category,
            severity: severity,
            message: message,
            detail: detail
        ))
    }

    func clear() {
        self.events.removeAll()
    }

    func filtered(by categories: Set<DiagnosticCategory>) -> [DiagnosticEvent] {
        if categories.count == DiagnosticCategory.allCases.count {
            return self.events
        }
        return self.events.filter { categories.contains($0.category) }
    }

    func snapshot(
        tunnel: TunnelManager,
        voice: VoiceManager,
        brain: BrainStatusMonitor
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"

        var lines: [String] = []
        lines.append("solstone-swift diagnostic snapshot")
        lines.append(formatter.string(from: Date()))
        lines.append("connection: \(tunnel.state)")

        let network: String
        switch tunnel.currentInterfaceIsWiFi {
        case true: network = "wifi"
        case false: network = "cellular"
        case nil: network = "unknown"
        }
        lines.append("network: \(network)")

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        lines.append("app: \(version) (\(build)) / iOS \(iosVersion)")

        lines.append("voice: \(voice.state)")
        lines.append("brain: \(brain.status)")
        lines.append("---")

        if self.events.isEmpty {
            lines.append("(no events)")
        } else {
            for event in self.events.reversed() {
                let ts = formatter.string(from: event.timestamp)
                var line = "[\(ts)] [\(event.category.rawValue)] \(event.message)"
                if let detail = event.detail {
                    line += " — \(detail)"
                }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }
}
