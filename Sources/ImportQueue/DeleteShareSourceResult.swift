// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct DeleteSourceReceipt: Decodable, Equatable, Sendable {
    struct Removed: Decodable, Equatable, Sendable {
        let originals: Int
        let segments: Int
        let inSegmentDerived: Int
        let indexChunks: Int
        let streamIdentity: Int
        let historyRows: Int

        enum CodingKeys: String, CodingKey {
            case originals
            case segments
            case inSegmentDerived = "in_segment_derived"
            case indexChunks = "index_chunks"
            case streamIdentity = "stream_identity"
            case historyRows = "history_rows"
        }
    }

    struct Issue: Decodable, Equatable, Hashable, Sendable {
        let what: String
        let plainReason: String

        enum CodingKeys: String, CodingKey {
            case what
            case plainReason = "plain_reason"
        }
    }

    let target: String
    let removed: Removed
    let notConfirmed: [Issue]
    let notRemoved: [Issue]
    let backupHosted: String

    enum CodingKeys: String, CodingKey {
        case target
        case removed
        case notConfirmed = "not_confirmed"
        case notRemoved = "not_removed"
        case backupHosted = "backup_hosted"
    }
}

nonisolated enum DeleteShareSourceResult: Equatable, Sendable {
    case confirmed(receipt: DeleteSourceReceipt, localNotRemoved: [DeleteSourceReceipt.Issue])
    case notConfirmed
    case unreachable(reason: String)

    var notRemovedIssues: [DeleteSourceReceipt.Issue] {
        switch self {
        case .confirmed(let receipt, let localNotRemoved):
            receipt.notRemoved + localNotRemoved
        case .notConfirmed, .unreachable:
            []
        }
    }

    var isPartial: Bool {
        switch self {
        case .confirmed:
            !self.notRemovedIssues.isEmpty
        case .notConfirmed, .unreachable:
            false
        }
    }

    var shouldFlipOff: Bool {
        switch self {
        case .confirmed:
            true
        case .notConfirmed, .unreachable:
            false
        }
    }

    var notConfirmedIssues: [DeleteSourceReceipt.Issue] {
        switch self {
        case .confirmed(let receipt, _):
            receipt.notConfirmed
        case .notConfirmed, .unreachable:
            []
        }
    }
}
