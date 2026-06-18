// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Observation
import UIKit
import os

private let bleLog = Logger(subsystem: "app.solstone.swift", category: "ble")

@MainActor
@Observable
final class BLEDiagnosticLog {
    private(set) var entries: [BLELogEntry] = []
    private let capacity: Int

    init(capacity: Int = 500) {
        self.capacity = capacity
    }

    func append(
        severity: BLELogSeverity = .info,
        message: String,
        hex: String? = nil
    ) {
        self.append(BLELogEntry(
            severity: severity,
            message: message,
            hex: hex
        ))
    }

    func append(_ entry: BLELogEntry) {
        self.entries.append(entry)
        if self.entries.count > self.capacity {
            self.entries.removeFirst(self.entries.count - self.capacity)
        }

        if let hex = entry.hex {
            self.logToOS(severity: entry.severity, message: "\(entry.message) hex=\(hex)")
        } else {
            self.logToOS(severity: entry.severity, message: entry.message)
        }
    }

    func clear() {
        self.entries.removeAll()
    }

    func logSnapshot(
        connectedPeripheralName: String?,
        connectedPeripheralID: String?,
        firmware: String?
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"

        var lines: [String] = []
        lines.append("solstone-swift ble diagnostic snapshot")
        lines.append(formatter.string(from: Date()))

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        lines.append("app: \(version) (\(build)) / iOS \(iosVersion)")

        if let connectedPeripheralName, let connectedPeripheralID {
            lines.append("connected peripheral: \(connectedPeripheralName) (\(connectedPeripheralID))")
        } else if let connectedPeripheralID {
            lines.append("connected peripheral: \(connectedPeripheralID)")
        } else {
            lines.append("connected peripheral: (not connected)")
        }
        lines.append("firmware: \(firmware ?? "(unknown)")")
        lines.append("---")

        if self.entries.isEmpty {
            lines.append("(no events)")
        } else {
            for entry in self.entries.reversed() {
                let ts = formatter.string(from: entry.timestamp)
                var line = "[\(ts)] [\(entry.severity.rawValue)] \(entry.message)"
                if let hex = entry.hex {
                    line += " hex=\(hex)"
                }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    private func logToOS(severity: BLELogSeverity, message: String) {
        switch severity {
        case .info:
            bleLog.info("\(message, privacy: .public)")
        case .warn:
            bleLog.info("warning: \(message, privacy: .public)")
        case .error:
            bleLog.error("\(message, privacy: .public)")
        }
    }
}
