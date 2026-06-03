// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OnThisPhoneSourceKind: Equatable, Sendable {
    case audio
    case location
    case share
}

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
    let sourceKind: OnThisPhoneSourceKind
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
    let audioDurationS: Double?
    let locationFixCount: Int?

    init(
        id: String,
        sourceKind: OnThisPhoneSourceKind,
        sendState: OnThisPhoneSendState,
        contentType: String?,
        filename: String?,
        bytes: Int64?,
        originApp: String?,
        basis: String?,
        itemTime: Date?,
        targetJournal: String?,
        stream: String?,
        day: String?,
        segment: String?,
        deliveredAt: Date?,
        rawFileURL: URL?,
        audioDurationS: Double? = nil,
        locationFixCount: Int? = nil
    ) {
        self.id = id
        self.sourceKind = sourceKind
        self.sendState = sendState
        self.contentType = contentType
        self.filename = filename
        self.bytes = bytes
        self.originApp = originApp
        self.basis = basis
        self.itemTime = itemTime
        self.targetJournal = targetJournal
        self.stream = stream
        self.day = day
        self.segment = segment
        self.deliveredAt = deliveredAt
        self.rawFileURL = rawFileURL
        self.audioDurationS = audioDurationS
        self.locationFixCount = locationFixCount
    }

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

nonisolated enum OnThisPhoneSourceResult: Equatable, Sendable {
    case loaded(items: [OnThisPhoneItem])
    case failed

    var count: Int? {
        switch self {
        case .loaded(let items):
            items.count
        case .failed:
            nil
        }
    }

    var items: [OnThisPhoneItem] {
        switch self {
        case .loaded(let items):
            items
        case .failed:
            []
        }
    }
}

nonisolated struct OnThisPhoneSourceSnapshot: Equatable, Sendable {
    let sourceKind: OnThisPhoneSourceKind
    let result: OnThisPhoneSourceResult
}

nonisolated struct OnThisPhoneAggregateSnapshot: Equatable, Sendable {
    let sources: [OnThisPhoneSourceSnapshot]
    let items: [OnThisPhoneItem]
}

nonisolated enum OnThisPhoneItemSort {
    static func newestFirst(_ items: [OnThisPhoneItem]) -> [OnThisPhoneItem] {
        items.sorted { lhs, rhs in
            let lhsTime = self.timestamp(for: lhs)
            let rhsTime = self.timestamp(for: rhs)
            if lhsTime != rhsTime {
                return lhsTime > rhsTime
            }
            return lhs.id < rhs.id
        }
    }

    static func timestamp(for item: OnThisPhoneItem) -> Date {
        item.deliveredAt ?? item.itemTime ?? .distantPast
    }
}
