// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct WatchConnectivityTransferFailureSnapshot: Codable, Equatable, Sendable {
    let domain: String
    let code: Int
    let boundedRedactedDescription: String

    init(domain: String, code: Int, boundedRedactedDescription: String) {
        self.domain = domain
        self.code = code
        self.boundedRedactedDescription = WatchTransferFailureFormatter.redactedDescription(
            boundedRedactedDescription
        )
    }

    init(error: any Error) {
        let nsError = error as NSError
        self.domain = nsError.domain
        self.code = nsError.code
        self.boundedRedactedDescription = WatchTransferFailureFormatter.redactedDescription(nsError.localizedDescription)
    }
}

nonisolated struct WatchTransferStructuredFailure: Codable, Equatable, Sendable {
    let time: Date
    let domain: String
    let code: Int
    let boundedRedactedDescription: String

    init(time: Date, snapshot: WatchConnectivityTransferFailureSnapshot) {
        self.time = time
        self.domain = snapshot.domain
        self.code = snapshot.code
        self.boundedRedactedDescription = WatchTransferFailureFormatter.redactedDescription(
            snapshot.boundedRedactedDescription
        )
    }

    init(time: Date, domain: String, code: Int, boundedRedactedDescription: String) {
        self.time = time
        self.domain = domain
        self.code = code
        self.boundedRedactedDescription = WatchTransferFailureFormatter.redactedDescription(
            boundedRedactedDescription
        )
    }
}

nonisolated enum WatchTransferFailureFormatter {
    static let maxDescriptionLength = 200

    static func redactedDescription(_ input: String) -> String {
        var output = input
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        output = self.replace(
            pattern: #"(?i)\bAuthorization\s*:\s*[^ ]+(?:\s+[^ ]+)?"#,
            in: output,
            with: "Authorization: [redacted]"
        )
        output = self.replace(
            pattern: #"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: output,
            with: "Bearer [redacted]"
        )
        let sensitiveKeys = [
            ["to", "ken"].joined(),
            ["creden", "tial"].joined(),
            ["pass", "word"].joined(),
            ["sec", "ret"].joined(),
        ]
        output = self.replace(
            pattern: #"(?i)\b("# + sensitiveKeys.joined(separator: "|") + #")=([^&\s]+)"#,
            in: output,
            with: "$1=[redacted]"
        )
        output = self.replace(
            pattern: #"file:///[^\s,;)]+"#,
            in: output,
            with: "[path]"
        )
        output = self.replace(
            pattern: #"/(?:private/)?(?:var|tmp|Users|Volumes|Applications|System|Library)/[^\s,;)]+"#,
            in: output,
            with: "[path]"
        )
        output = self.replace(
            pattern: #"https?://[^\s,;)]+"#,
            in: output,
            with: "[endpoint]"
        )
        output = output
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")

        guard output.count > Self.maxDescriptionLength else { return output }
        return String(output.prefix(Self.maxDescriptionLength))
    }

    static func exportSafeText(_ input: String?) -> String {
        guard let input, !input.isEmpty else {
            return SourceVocabulary.watchDetailNone
        }
        return self.redactedDescription(input)
    }

    private static func replace(pattern: String, in input: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
