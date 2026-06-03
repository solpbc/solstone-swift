// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OnThisPhoneSendState: Equatable, Sendable {
    case savedOnThisPhone
    case sending
    case inYourJournal
    case needsAttention

    var label: String {
        switch self {
        case .savedOnThisPhone:
            SourceVocabulary.sendStateSaved
        case .sending:
            SourceVocabulary.sendStateSending
        case .inYourJournal:
            SourceVocabulary.shareDeliveredProgress
        case .needsAttention:
            SourceVocabulary.needsAttention
        }
    }
}

nonisolated enum OnThisPhoneLocation: Equatable, Sendable {
    case pending
    case failed
    case delivered
}

nonisolated func onThisPhoneSendState(
    location: OnThisPhoneLocation,
    isActivelyUploading: Bool
) -> OnThisPhoneSendState {
    switch location {
    case .delivered:
        .inYourJournal
    case .failed:
        .needsAttention
    case .pending:
        isActivelyUploading ? .sending : .savedOnThisPhone
    }
}

nonisolated struct OnThisPhoneItem: Identifiable, Sendable, Equatable {
    let id: String
    let sendState: OnThisPhoneSendState
    let contentType: String?
    let filename: String?
    let bytes: Int64?
    let originApp: String?
    let basis: String?
    let itemTime: Date?
    let targetJournal: String?
    let stream: String?
    let day: String?
    let segment: String?
    let deliveredAt: Date?
    let rawFileURL: URL?

    var hasLocalRaw: Bool {
        self.rawFileURL != nil
    }

    var voiceOverText: String {
        [
            self.filename ?? SourceVocabulary.notProvided,
            self.contentType ?? SourceVocabulary.notProvided,
            self.sendState.label,
        ].joined(separator: ". ")
    }
}

nonisolated enum OnThisPhoneResult: Equatable, Sendable {
    case loaded([OnThisPhoneItem])
    case loadedEmpty
    case failed
}
