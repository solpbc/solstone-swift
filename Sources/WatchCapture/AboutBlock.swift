// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum AboutBlock {
    static func line(
        name: String,
        isJournal: Bool = false,
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
        if isJournal, cleanVersion.isEmpty {
            return AppStrings.ios_watch_line()
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
        if !isCurrent, let observedAt,
           let elapsed = Int(exactly: (now.timeIntervalSince1970 - observedAt).rounded(.down)) {
            result += AppStrings.ios_watch_result("\(relativeInterval(max(0, elapsed)))")
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
        if seconds < 60 { return AppStrings.ios_about_relative_second(seconds) }
        if seconds < 3_600 { return AppStrings.ios_about_relative_minute(seconds / 60) }
        if seconds < 86_400 { return AppStrings.ios_about_relative_hour(seconds / 3_600) }
        return AppStrings.ios_about_relative_day(seconds / 86_400)
    }
}
