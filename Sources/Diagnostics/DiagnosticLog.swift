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
    private let protectedFloor: Int

    init(capacity: Int = 200, protectedFloor: Int = 40) {
        self.capacity = capacity
        self.protectedFloor = protectedFloor
    }

    func append(_ event: DiagnosticEvent) {
        self.events.append(event)
        while self.events.count > self.capacity {
            let protectedCount = self.events.reduce(into: 0) {
                if self.isProtected($1.category) {
                    $0 += 1
                }
            }
            if protectedCount > self.protectedFloor {
                self.events.removeFirst()
            } else if let idx = self.events.firstIndex(where: { !self.isProtected($0.category) }) {
                self.events.remove(at: idx)
            } else {
                self.events.removeFirst()
            }
        }
    }

    private func isProtected(_ c: DiagnosticCategory) -> Bool {
        c == .tunnel || c == .network
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

    func snapshot(tunnel: TunnelManager) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"

        var lines: [String] = []
        lines.append("solstone-swift diagnostic snapshot")
        lines.append(formatter.string(from: Date()))
        lines.append("connection: \(tunnel.state)")
        let reconnectBreakdown = ReconnectReasonBucket.allCases
            .map { "\($0.exportLabel) \(tunnel.reconnectReasonCounts[$0] ?? 0)" }
            .joined(separator: ", ")
        lines.append("tunnel reconnects: \(tunnel.reconnectCount) (\(reconnectBreakdown))")
        let inboundFaultBreakdown = tunnel.inboundClosedFaultCounts.isEmpty
            ? "(none)"
            : tunnel.inboundClosedFaultCounts
                .sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
        lines.append("tunnel inbound-closed faults: \(inboundFaultBreakdown)")

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

    func exportFileURL(tunnel: TunnelManager) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(Self.exportFileName, isDirectory: false)
        do {
            let report = self.snapshot(tunnel: tunnel)
            try Data(report.utf8).write(to: url, options: [.atomic])
            return url
        } catch {
            diagnosticLogLogger.error("diagnostic export failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
