// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum OnThisPhoneItemPreviewMode: Equatable, Sendable {
    case audioPlayer
    case thumbnail
    case none
}

nonisolated enum OnThisPhoneFailureBucket: Equatable, Sendable {
    case network
    case timeout
    case server
    case unknown
}

nonisolated struct OnThisPhoneItemSummary: Equatable, Sendable {
    let big: String
    let small: String
}

nonisolated struct OnThisPhoneJournalAvailability: Equatable, Sendable {
    let enabled: Bool
    let hint: String
}

nonisolated struct OnThisPhoneFailureLegibility: Equatable, Sendable {
    let message: String
    let lastTried: String?
}

nonisolated struct OnThisPhoneDetailRow: Identifiable, Equatable, Sendable {
    let label: String
    let value: String

    var id: String {
        self.label
    }
}

nonisolated enum OnThisPhoneItemDetailPresentation {
    static func navigationTitle(
        for item: OnThisPhoneItem,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let source = SourceVocabulary.onThisPhoneSourceName(for: item.sourceKind)
        guard let itemTime = item.itemTime else {
            return SourceVocabulary.onThisPhoneNavigationTitle(source: source, shortTime: nil)
        }
        return SourceVocabulary.onThisPhoneNavigationTitle(
            source: source,
            shortTime: self.shortTimeLabel(for: itemTime, locale: locale, timeZone: timeZone)
        )
    }

    static func previewMode(
        sourceKind: OnThisPhoneSourceKind,
        contentType: String?,
        hasLocalRaw: Bool
    ) -> OnThisPhoneItemPreviewMode {
        guard hasLocalRaw else { return .none }
        switch sourceKind {
        case .audio:
            return .audioPlayer
        case .location:
            return .none
        case .share:
            return self.isThumbnailContentType(contentType) ? .thumbnail : .none
        }
    }

    static func summaryBig(for item: OnThisPhoneItem) -> String {
        switch item.sourceKind {
        case .audio:
            let duration = OnThisPhoneItem.formattedDuration(item.audioDurationS) ?? SourceVocabulary.notProvided
            return SourceVocabulary.onThisPhoneAudioSummary(duration: duration)
        case .location:
            guard let count = item.locationFixCount else {
                return SourceVocabulary.notProvided
            }
            return SourceVocabulary.onThisPhoneLocationSummary(count: count)
        case .share:
            return item.filename ?? SourceVocabulary.onThisPhone
        }
    }

    static func summarySmall(
        for item: OnThisPhoneItem,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let relativeDay: String?
        let shortTime: String?
        if let itemTime = item.itemTime {
            relativeDay = self.relativeDayLabel(
                for: itemTime,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
            shortTime = self.shortTimeLabel(for: itemTime, locale: locale, timeZone: timeZone)
        } else {
            relativeDay = nil
            shortTime = nil
        }

        switch item.sourceKind {
        case .audio, .location:
            return SourceVocabulary.onThisPhoneObservedSummary(relativeDay: relativeDay, shortTime: shortTime)
        case .share:
            return SourceVocabulary.onThisPhoneShareSummary(
                originApp: self.nonEmpty(item.originApp),
                relativeDay: relativeDay,
                shortTime: shortTime
            )
        }
    }

    static func summary(
        for item: OnThisPhoneItem,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> OnThisPhoneItemSummary {
        OnThisPhoneItemSummary(
            big: self.summaryBig(for: item),
            small: self.summarySmall(
                for: item,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            )
        )
    }

    static func relativeDayLabel(
        for date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var zonedCalendar = calendar
        zonedCalendar.timeZone = timeZone
        if zonedCalendar.isDate(date, inSameDayAs: now) {
            return "today"
        }
        if let yesterday = zonedCalendar.date(
            byAdding: .day,
            value: -1,
            to: zonedCalendar.startOfDay(for: now)
        ), zonedCalendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday"
        }

        let formatter = DateFormatter()
        formatter.calendar = zonedCalendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func shortTimeLabel(
        for date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func fullDateTimeLabel(
        for date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func failureBucket(for rawReason: String?) -> OnThisPhoneFailureBucket {
        guard let rawReason = rawReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawReason.isEmpty
        else {
            return .unknown
        }

        let reason = rawReason.lowercased()
        if self.containsAny(reason, needles: ["timed out", "timeout", "time out", "-1001"]) {
            return .timeout
        }
        if self.containsAny(reason, needles: ["http 4", "http 5"]) {
            return .server
        }
        if self.containsAny(reason, needles: [
            "cannot connect",
            "cannot-connect",
            "could not connect",
            "can't connect",
            "cannot find host",
            "cannot-find-host",
            "could not find host",
            "network connection lost",
            "connection lost",
            "network lost",
            "network-lost",
            "offline",
            "not connected",
            "-1003",
            "-1004",
            "-1005",
            "-1009",
        ]) {
            return .network
        }
        return .unknown
    }

    static func failureLegibility(
        for item: OnThisPhoneItem,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> OnThisPhoneFailureLegibility? {
        guard item.sourceKind == .audio,
              item.sendState == .needsAttention,
              let failureAttemptCount = item.failureAttemptCount
        else {
            return nil
        }

        let message: String
        if item.retryAvailable {
            message = SourceVocabulary.onThisPhoneFailureRetryableMessage(count: failureAttemptCount)
        } else {
            let bucket = self.failureBucket(for: item.failureReason)
            let reason = self.failurePlainReason(for: bucket)
            message = SourceVocabulary.onThisPhoneFailurePermanentMessage(reason: reason)
        }

        let lastTried = item.lastAttemptAt.map { lastAttemptAt in
            let relativeDay = self.relativeDayLabel(
                for: lastAttemptAt,
                now: now,
                calendar: Calendar(identifier: .gregorian),
                locale: locale,
                timeZone: timeZone
            )
            let shortTime = self.shortTimeLabel(
                for: lastAttemptAt,
                locale: locale,
                timeZone: timeZone
            )
            return SourceVocabulary.onThisPhoneFailureLastTried(datePhrase: "\(relativeDay) at \(shortTime)")
        }

        return OnThisPhoneFailureLegibility(message: message, lastTried: lastTried)
    }

    static func journalAvailability(
        sendState: OnThisPhoneSendState,
        hasConveyURL: Bool,
        sourceKind: OnThisPhoneSourceKind
    ) -> OnThisPhoneJournalAvailability {
        guard sendState == .inYourJournal else {
            return OnThisPhoneJournalAvailability(
                enabled: false,
                hint: SourceVocabulary.onThisPhoneJournalHintPending
            )
        }

        if hasConveyURL {
            return OnThisPhoneJournalAvailability(
                enabled: true,
                hint: sourceKind == .location
                    ? SourceVocabulary.onThisPhoneJournalHintLocationSaved
                    : SourceVocabulary.onThisPhoneJournalHintSaved
            )
        }

        return OnThisPhoneJournalAvailability(
            enabled: false,
            hint: sourceKind == .location
                ? SourceVocabulary.onThisPhoneJournalHintLocationUnreachable
                : SourceVocabulary.onThisPhoneJournalHintUnreachable
        )
    }

    static func detailRows(
        for item: OnThisPhoneItem,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> [OnThisPhoneDetailRow] {
        let when = item.itemTime.map {
            self.fullDateTimeLabel(for: $0, locale: locale, timeZone: timeZone)
        } ?? SourceVocabulary.notProvided

        switch item.sourceKind {
        case .audio, .share:
            var rows = [
                OnThisPhoneDetailRow(
                    label: SourceVocabulary.onThisPhoneFileLabel,
                    value: SourceVocabulary.onThisPhoneFileDetail(
                        filename: item.filename ?? SourceVocabulary.notProvided,
                        size: self.sizeText(bytes: item.bytes)
                    )
                ),
                OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneWhenLabel, value: when),
            ]
            if let sourceLabel = self.nonEmpty(item.sourceLabel) {
                rows.append(OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneSourceLabel, value: sourceLabel))
            }
            if let failureReason = self.nonEmpty(item.failureReason) {
                rows.append(OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneFailureReasonLabel, value: failureReason))
            }
            if let failureAttemptCount = item.failureAttemptCount {
                rows.append(OnThisPhoneDetailRow(
                    label: SourceVocabulary.onThisPhoneFailureStatusLabel,
                    value: SourceVocabulary.onThisPhoneFailureAttemptStatus(count: failureAttemptCount)
                ))
            }
            return rows
        case .location:
            return [
                OnThisPhoneDetailRow(
                    label: SourceVocabulary.onThisPhoneObservationsLabel,
                    value: item.locationFixCount.map {
                        SourceVocabulary.onThisPhoneFixCount(count: $0)
                    } ?? SourceVocabulary.notProvided
                ),
                OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneWhenLabel, value: when),
            ]
        }
    }
}

private extension OnThisPhoneItemDetailPresentation {
    nonisolated static func isThumbnailContentType(_ contentType: String?) -> Bool {
        guard let contentType = contentType?.lowercased() else { return false }
        switch contentType {
        case "com.adobe.pdf", "application/pdf",
             "public.jpeg", "public.jpg", "image/jpeg",
             "public.png", "image/png",
             "public.heic", "public.heif", "image/heic", "image/heif",
             "com.compuserve.gif", "image/gif",
             "org.webmproject.webp", "public.webp", "image/webp",
             "public.tiff", "image/tiff":
            return true
        default:
            return false
        }
    }

    nonisolated static func sizeText(bytes: Int64?) -> String {
        guard let bytes else {
            return SourceVocabulary.notProvided
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    nonisolated static func containsAny(_ value: String, needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }

    nonisolated static func failurePlainReason(for bucket: OnThisPhoneFailureBucket) -> String {
        switch bucket {
        case .network:
            SourceVocabulary.onThisPhoneFailureReasonNetwork
        case .timeout:
            SourceVocabulary.onThisPhoneFailureReasonTimeout
        case .server:
            SourceVocabulary.onThisPhoneFailureReasonServer
        case .unknown:
            SourceVocabulary.onThisPhoneFailureReasonUnknown
        }
    }
}
