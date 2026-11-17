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
        case .streamLimitRefused: AppStrings.ios_diagnostics_summary3()
        case .streamReset: AppStrings.ios_diagnostics_summary2()
        case .transportClosed: AppStrings.ios_diagnostics_summary()
        }
    }

    var detail: String {
        switch self {
        case .streamLimitRefused:
            AppStrings.ios_diagnostics_detail()
        case .streamReset:
            // A reset frame arrived over a working carrier; it is not a network loss.
            AppStrings.ios_diagnostics_detail3()
        case .transportClosed:
            AppStrings.ios_diagnostics_detail2()
        }
    }
}

nonisolated struct JournalLinkEvent: Codable, Equatable, Identifiable, Sendable {
    let kind: JournalLinkEventKind
    let timestamp: Date

    var id: String { self.kind.rawValue }

    var reportLine: String {
        AppStrings.ios_frame_journallinkevent_n44("\(self.timestamp.ISO8601Format())", "\(self.kind.rawValue)", "\(self.kind.summary)", "\(self.kind.detail)")
    }
}
