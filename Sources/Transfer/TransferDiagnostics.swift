// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

typealias TransferDiagnosticSink = @Sendable (TransferDiagnosticEvent) -> Void

nonisolated struct TransferDiagnosticEvent: Codable, Equatable, Sendable {
    var source: String
    var itemID: UUID
    var previousState: TransferRuntimeState
    var nextState: TransferRuntimeState
    var outcome: TransferDiagnosticOutcomeSummary
    var attempt: Int
    var shortDetail: String
    var at: Date
}

nonisolated enum TransferRuntimeState: String, Codable, Equatable, Sendable {
    case staged
    case queued
    case dispatching
    case attention
    case delivered
    case held
    case dropped
    case paused
}

nonisolated enum TransferDiagnosticOutcomeSummary: String, Codable, Equatable, Sendable {
    case queued
    case delivered
    case retrying
    case needsAttention = "needs_attention"
    case held
    case dropped
    case paused
    case resumed
}
