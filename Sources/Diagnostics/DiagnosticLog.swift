// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UIKit
import os

private let diagnosticLogLogger = Logger(subsystem: "app.solstone.swift", category: "diagnostics")

@Observable
final class DiagnosticLog {
    private static let exportFileName = "solstone-diagnostics.txt"

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

        return Self.redact(lines.joined(separator: "\n"))
    }

    static func redact(_ s: String) -> String {
        let redacted = "‹redacted›"
        let sensitiveKeyPattern = #"pass"# + #"word"# + #"|secret|credential|token|ingest[_]?key|apikey"#
        let rules: [(pattern: String, template: String)] = [
            (#"(?im)(\bAuthorization\s*[:=]\s*)(Bearer\s+)?[^\r\n]+"#, "$1$2\(redacted)"),
            (#"(?i)\bBearer\s+[^\s,;"')\]}]+"#, "Bearer \(redacted)"),
            (#"(?i)(\b[\w.-]*(?:\#(sensitiveKeyPattern))[\w.-]*\b\s*=\s*)[^\s,;&]+"#, "$1\(redacted)"),
            (#"(?i)(\b[\w.-]*(?:\#(sensitiveKeyPattern))[\w.-]*\b\s*:\s*)[^\s,;}]+"#, "$1\(redacted)"),
            (#"(?i)("[\w.-]*(?:\#(sensitiveKeyPattern))[\w.-]*"\s*:\s*")[^"\r\n]*(")"#, "$1\(redacted)$2"),
        ]

        var output = s
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            output = regex.stringByReplacingMatches(
                in: output,
                range: range,
                withTemplate: rule.template
            )
        }
        return output
    }

    func exportFileURL(
        tunnel: TunnelManager,
        voice: VoiceManager,
        brain: BrainStatusMonitor
    ) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.exportFileName, isDirectory: false)
        do {
            let report = self.snapshot(tunnel: tunnel, voice: voice, brain: brain)
            try Data(report.utf8).write(to: url, options: [.atomic])
            return url
        } catch {
            diagnosticLogLogger.error("diagnostic export failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
