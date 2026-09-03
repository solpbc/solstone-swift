// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

enum DiagnosticCategory: String, CaseIterable, Sendable {
    case tunnel
    case network
    case upload
    case journal
    case diagnostics
}

enum DiagnosticSeverity: Sendable, Equatable {
    case info
    case warning
    case error

    var rowEmphasis: DiagnosticRowEmphasis {
        switch self {
        case .info:
            .normal
        case .warning:
            .warning
        case .error:
            .error
        }
    }
}

enum DiagnosticRowEmphasis: Sendable, Equatable {
    case normal
    case warning
    case error
}

struct DiagnosticEvent: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let category: DiagnosticCategory
    let severity: DiagnosticSeverity
    let message: String
    let detail: String?

    init(
        category: DiagnosticCategory,
        severity: DiagnosticSeverity = .info,
        message: String,
        detail: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.category = category
        self.severity = severity
        self.message = message
        self.detail = detail
    }
}
