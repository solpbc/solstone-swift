// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum AboutBlock {
    static func line(
        name: String,
        version: String,
        build: String = "",
        os: String = "",
        osVersion: String = "",
        arch: String = "",
        isCurrent: Bool = true,
        observedAt: TimeInterval? = nil,
        now: Date = Date()
    ) -> String {
        let cleanVersion = trimLeadingV(version)
        if name == "journal", cleanVersion.isEmpty {
            return "journal unknown"
        }

        var result = name
        if !cleanVersion.isEmpty {
            result += " \(cleanVersion)"
        }
        if !build.isEmpty {
            result += " (\(build))"
        }
        if !os.isEmpty {
            result += " · \(os)"
            if !osVersion.isEmpty {
                result += " \(osVersion)"
            }
        }
        if !arch.isEmpty {
            result += " · \(normalizedArch(arch))"
        }
        if !isCurrent, let observedAt {
            let seconds = max(0, Int((now.timeIntervalSince1970 - observedAt).rounded(.down)))
            result += " · last seen \(relativeInterval(seconds))"
        }
        return result
    }

    static func block(_ lines: [String]) -> String {
        lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func trimLeadingV(_ value: String) -> String {
        String(value.drop(while: { $0 == "v" }))
    }

    private static func normalizedArch(_ arch: String) -> String {
        switch arch {
        case "aarch64", "ARM64", "arm64-v8a", "arm64": "arm64"
        case "amd64", "x64", "AMD64", "x86_64": "x86_64"
        default: arch
        }
    }

    private static func relativeInterval(_ seconds: Int) -> String {
        let count: Int
        let unit: String
        if seconds < 60 {
            count = seconds
            unit = "second"
        } else if seconds < 3_600 {
            count = seconds / 60
            unit = "minute"
        } else if seconds < 86_400 {
            count = seconds / 3_600
            unit = "hour"
        } else {
            count = seconds / 86_400
            unit = "day"
        }
        return "\(count) \(unit)\(count == 1 ? "" : "s") ago"
    }
}
