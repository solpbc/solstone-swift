// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OnThisPhoneSourceKind: Hashable, Sendable {
    case audio
    case location
    case share

    var accessibilityID: String {
        switch self {
        case .audio:
            "audio"
        case .location:
            "location"
        case .share:
            "share"
        }
    }
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

    var stateID: String {
        switch self {
        case .savedOnThisPhone:
            "savedOnThisPhone"
        case .sending:
            "sending"
        case .inYourJournal:
            "inYourJournal"
        case .needsAttention:
            "needsAttention"
        }
    }

    static let summaryOrder: [OnThisPhoneSendState] = [
        .savedOnThisPhone,
        .sending,
        .inYourJournal,
        .needsAttention,
    ]
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

    var rowTimestampText: String {
        (self.itemTime ?? self.deliveredAt)?.formatted(date: .omitted, time: .shortened) ?? ""
    }

    var rowDescriptorText: String {
        switch self.sourceKind {
        case .audio:
            Self.formattedDuration(self.audioDurationS)
                ?? self.filename
                ?? SourceVocabulary.notProvided
        case .location:
            self.locationFixCount.map {
                SourceVocabulary.onThisPhoneLocationRowLabel(count: $0)
            } ?? SourceVocabulary.notProvided
        case .share:
            self.filename ?? SourceVocabulary.notProvided
        }
    }

    var dropDescriptor: String {
        guard let itemID = OnThisPhoneItemID(sourceKind: self.sourceKind, id: self.id) else {
            return self.filename ?? SourceVocabulary.notProvided
        }

        switch itemID {
        case .audio:
            guard let duration = Self.formattedDuration(self.audioDurationS) else {
                return self.filename ?? SourceVocabulary.notProvided
            }
            return SourceVocabulary.onThisPhoneDropAudioDescriptor(duration: duration)
        case .location:
            guard let locationFixCount else {
                return self.filename ?? SourceVocabulary.notProvided
            }
            return SourceVocabulary.onThisPhoneDropLocationDescriptor(count: locationFixCount)
        case .share:
            return self.filename ?? SourceVocabulary.notProvided
        }
    }

    var dropConfirmNoun: String {
        guard let itemID = OnThisPhoneItemID(sourceKind: self.sourceKind, id: self.id) else {
            return SourceVocabulary.onThisPhoneDropShareNoun
        }

        switch itemID {
        case .audio:
            return SourceVocabulary.onThisPhoneDropAudioNoun
        case .location:
            return SourceVocabulary.onThisPhoneDropLocationNoun
        case .share:
            return SourceVocabulary.onThisPhoneDropShareNoun
        }
    }

    var voiceOverText: String {
        [
            SourceVocabulary.onThisPhoneSourceName(for: self.sourceKind),
            self.rowPayloadText,
            self.sendState.label,
        ].joined(separator: ". ")
    }

    var rowPayloadText: String {
        switch self.sourceKind {
        case .audio:
            return Self.formattedDuration(self.audioDurationS)
                ?? self.filename
                ?? SourceVocabulary.notProvided
        case .location:
            let countText = self.locationFixCount.map {
                SourceVocabulary.onThisPhoneLocationRowLabel(count: $0)
            } ?? SourceVocabulary.notProvided
            guard let itemTime else { return countText }
            return "\(countText) · \(itemTime.formatted())"
        case .share:
            return self.filename ?? SourceVocabulary.notProvided
        }
    }

    static func formattedDuration(_ duration: Double?) -> String? {
        guard let duration else { return nil }
        let totalSeconds = max(Int(duration.rounded()), 0)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
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

    func filteringOutPending(_ pendingIDs: Set<String>) -> OnThisPhoneAggregateSnapshot {
        guard !pendingIDs.isEmpty else { return self }

        let filteredSources = self.sources.map { source in
            switch source.result {
            case .loaded(let items):
                OnThisPhoneSourceSnapshot(
                    sourceKind: source.sourceKind,
                    result: .loaded(items: items.filter { !pendingIDs.contains($0.id) })
                )
            case .failed:
                source
            }
        }

        return OnThisPhoneAggregateSnapshot(
            sources: filteredSources,
            items: self.items.filter { !pendingIDs.contains($0.id) }
        )
    }

    var sendStateSummary: [OnThisPhoneSendStateSummary] {
        OnThisPhoneSendState.summaryOrder.compactMap { state in
            let count = self.items.filter { $0.sendState == state }.count
            guard count > 0 else { return nil }
            return OnThisPhoneSendStateSummary(sendState: state, count: count)
        }
    }
}

nonisolated struct OnThisPhoneSendStateSummary: Identifiable, Sendable, Equatable {
    let sendState: OnThisPhoneSendState
    let count: Int

    var id: String {
        self.sendState.stateID
    }
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

nonisolated enum OnThisPhoneItemID: Equatable, Sendable {
    case share(UUID)
    case audio(sessionID: UUID, chunkID: String)
    case location(fileID: String)

    init?(sourceKind: OnThisPhoneSourceKind, id: String) {
        switch sourceKind {
        case .share:
            guard let itemID = UUID(uuidString: id) else { return nil }
            self = .share(itemID)
        case .audio:
            let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3,
                  parts[0] == "audio",
                  let sessionID = UUID(uuidString: String(parts[1])),
                  !parts[2].isEmpty
            else {
                return nil
            }
            self = .audio(sessionID: sessionID, chunkID: String(parts[2]))
        case .location:
            let prefix = "location:"
            guard id.hasPrefix(prefix) else { return nil }
            let fileID = String(id.dropFirst(prefix.count))
            guard !fileID.isEmpty else { return nil }
            self = .location(fileID: fileID)
        }
    }
}

nonisolated enum OnThisPhoneBacklogNudge {
    static func shouldShow(items: [OnThisPhoneItem], now: Date) -> Bool {
        guard items.count > 50 else { return false }
        // Prefer the item's local time; deliveredAt is a fallback for delivered share ledger entries.
        let itemTimes = items.compactMap { item in
            item.itemTime ?? item.deliveredAt
        }
        guard let oldest = itemTimes.min() else { return false }
        return oldest < now.addingTimeInterval(-7 * 24 * 60 * 60)
    }
}
