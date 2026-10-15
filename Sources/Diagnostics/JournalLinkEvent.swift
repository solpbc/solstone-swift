// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import SPLTunnel

nonisolated enum JournalLinkEventKind: String, Codable, Sendable, CaseIterable {
    case streamLimitRefused = "tunnel.stream_limit_refused"
    case streamReset = "tunnel.stream_reset"
    case transportClosed = "tunnel.transport_closed"

    init(peerReset reason: ResetReason) {
        self = reason == .streamLimitExceeded ? .streamLimitRefused : .streamReset
    }

    var summary: String {
        switch self {
        case .streamLimitRefused: "your journal was busy with other requests"
        case .streamReset: "your journal ended a request early"
        case .transportClosed: "the connection to your journal ended"
        }
    }

    var detail: String {
        switch self {
        case .streamLimitRefused:
            "a request was turned away because your journal was handling too many at once. sending retries automatically. if a page did not load, try opening it again."
        case .streamReset:
            // A reset frame arrived over a working carrier; it is not a network loss.
            "the connection was still open. sending retries automatically. if a page did not load, try opening it again."
        case .transportClosed:
            "solstone will try to reconnect. if this keeps happening, check that your journal is running and your network is available."
        }
    }
}

nonisolated struct JournalLinkEvent: Codable, Equatable, Identifiable, Sendable {
    let kind: JournalLinkEventKind
    let timestamp: Date

    var id: String { self.kind.rawValue }

    var reportLine: String {
        "\(self.timestamp.ISO8601Format()) \(self.kind.rawValue): \(self.kind.summary). \(self.kind.detail)"
    }
}
