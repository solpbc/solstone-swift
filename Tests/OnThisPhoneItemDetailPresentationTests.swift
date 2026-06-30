// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OnThisPhoneItemDetailPresentationTests: XCTestCase {
    func testNavigationTitleUsesSourceAndOptionalShortTime() {
        let itemTime = Self.date(year: 2026, month: 6, day: 14, hour: 9, minute: 30)
        let audio = Self.item(sourceKind: .audio, itemTime: itemTime)
        let share = Self.item(sourceKind: .share, itemTime: nil)

        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.navigationTitle(
                for: audio,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            SourceVocabulary.onThisPhoneNavigationTitle(
                source: "audio",
                shortTime: OnThisPhoneItemDetailPresentation.shortTimeLabel(
                    for: itemTime,
                    locale: Self.locale,
                    timeZone: Self.timeZone
                )
            )
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.navigationTitle(
                for: share,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            SourceVocabulary.shareSheetDisplayName
        )
    }

    func testPreviewModeBranches() {
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.previewMode(
                sourceKind: .audio,
                contentType: "audio/mp4",
                hasLocalRaw: true
            ),
            .audioPlayer
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.previewMode(
                sourceKind: .audio,
                contentType: "audio/mp4",
                hasLocalRaw: false
            ),
            .none
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.previewMode(
                sourceKind: .share,
                contentType: "image/jpeg",
                hasLocalRaw: true
            ),
            .thumbnail
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.previewMode(
                sourceKind: .share,
                contentType: "application/pdf",
                hasLocalRaw: true
            ),
            .thumbnail
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.previewMode(
                sourceKind: .share,
                contentType: "text/plain",
                hasLocalRaw: true
            ),
            .none
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.previewMode(
                sourceKind: .location,
                contentType: "application/jsonl",
                hasLocalRaw: true
            ),
            .none
        )
    }

    func testSummaryBigBranches() {
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summaryBig(
                for: Self.item(sourceKind: .audio, audioDurationS: 75)
            ),
            "1m 15s of audio"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summaryBig(
                for: Self.item(sourceKind: .audio, audioDurationS: nil)
            ),
            "not provided of audio"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summaryBig(
                for: Self.item(sourceKind: .location, locationFixCount: nil)
            ),
            SourceVocabulary.notProvided
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summaryBig(
                for: Self.item(sourceKind: .location, locationFixCount: 1)
            ),
            "1 observation"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summaryBig(
                for: Self.item(sourceKind: .location, locationFixCount: 3)
            ),
            "3 observations"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summaryBig(
                for: Self.item(sourceKind: .share, filename: "receipt.pdf")
            ),
            "receipt.pdf"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summaryBig(
                for: Self.item(sourceKind: .share, filename: nil)
            ),
            SourceVocabulary.onThisPhone
        )
    }

    func testSummarySmallBranches() {
        let now = Self.date(year: 2026, month: 6, day: 14, hour: 12, minute: 0)
        let today = Self.date(year: 2026, month: 6, day: 14, hour: 9, minute: 30)
        let yesterday = Self.date(year: 2026, month: 6, day: 13, hour: 8, minute: 15)
        let older = Self.date(year: 2026, month: 6, day: 10, hour: 7, minute: 45)

        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summarySmall(
                for: Self.item(sourceKind: .audio, itemTime: today),
                now: now,
                calendar: Self.calendar,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            "observed on this phone · today at \(Self.shortTime(today))"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summarySmall(
                for: Self.item(sourceKind: .location, itemTime: yesterday),
                now: now,
                calendar: Self.calendar,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            "observed on this phone · yesterday at \(Self.shortTime(yesterday))"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summarySmall(
                for: Self.item(sourceKind: .audio, itemTime: nil),
                now: now,
                calendar: Self.calendar,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            "observed on this phone"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summarySmall(
                for: Self.item(sourceKind: .share, originApp: "Files", itemTime: today),
                now: now,
                calendar: Self.calendar,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            "from Files · today at \(Self.shortTime(today))"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summarySmall(
                for: Self.item(sourceKind: .share, originApp: nil, itemTime: older),
                now: now,
                calendar: Self.calendar,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            "\(Self.relativeDay(older, now: now)) at \(Self.shortTime(older))"
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.summarySmall(
                for: Self.item(sourceKind: .share, originApp: nil, itemTime: nil),
                now: now,
                calendar: Self.calendar,
                locale: Self.locale,
                timeZone: Self.timeZone
            ),
            SourceVocabulary.notProvided
        )

        let summary = OnThisPhoneItemDetailPresentation.summary(
            for: Self.item(sourceKind: .share, filename: "receipt.pdf", originApp: "Files", itemTime: today),
            now: now,
            calendar: Self.calendar,
            locale: Self.locale,
            timeZone: Self.timeZone
        )
        XCTAssertEqual(summary.big, "receipt.pdf")
        XCTAssertEqual(summary.small, "from Files · today at \(Self.shortTime(today))")
    }

    func testRelativeDayThresholds() {
        let now = Self.date(year: 2026, month: 6, day: 14, hour: 12, minute: 0)
        let today = Self.date(year: 2026, month: 6, day: 14, hour: 0, minute: 5)
        let yesterday = Self.date(year: 2026, month: 6, day: 13, hour: 23, minute: 55)
        let older = Self.date(year: 2026, month: 6, day: 12, hour: 23, minute: 55)

        XCTAssertEqual(Self.relativeDay(today, now: now), "today")
        XCTAssertEqual(Self.relativeDay(yesterday, now: now), "yesterday")
        XCTAssertEqual(Self.relativeDay(older, now: now), Self.formattedDate(older))
    }

    func testFailureLegibilityShowsMessageForWaitingAndPermafailed() throws {
        let now = Self.date(year: 2026, month: 6, day: 14, hour: 12, minute: 0)

        let retryableLocation = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
            for: Self.item(
                sourceKind: .location,
                sendState: .savedOnThisPhone,
                failureAttemptCount: 2,
                retryAvailable: true
            ),
            now: now
        ))
        XCTAssertEqual(
            retryableLocation.message,
            SourceVocabulary.onThisPhoneFailureRetryableMessage(count: 2)
        )

        let permafailed = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
            for: Self.item(sourceKind: .audio, sendState: .needsAttention),
            now: now
        ))
        XCTAssertEqual(
            permafailed.message,
            SourceVocabulary.onThisPhoneFailurePermanentMessage(reason: "something got in the way")
        )

        XCTAssertNil(OnThisPhoneItemDetailPresentation.failureLegibility(
            for: Self.item(sourceKind: .location, sendState: .savedOnThisPhone),
            now: now
        ))

        let waiting = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
            for: Self.item(sourceKind: .location, sendState: .savedOnThisPhone, retryAvailable: true),
            now: now
        ))
        XCTAssertEqual(waiting.message, SourceVocabulary.onThisPhoneWaitingExplain)
    }

    func testFailureLegibilityRetryableMessageUsesSingularAndPluralAttempts() throws {
        let now = Self.date(year: 2026, month: 6, day: 14, hour: 12, minute: 0)

        let singular = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
            for: Self.item(
                sourceKind: .audio,
                sendState: .needsAttention,
                failureAttemptCount: 1,
                retryAvailable: true
            ),
            now: now
        ))
        XCTAssertEqual(
            singular.message,
            "hasn't reached your journal yet — tried 1 time. it'll try again automatically when you reconnect."
        )
        XCTAssertNil(singular.lastTried)

        let plural = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
            for: Self.item(
                sourceKind: .audio,
                sendState: .needsAttention,
                failureAttemptCount: 3,
                retryAvailable: true
            ),
            now: now
        ))
        XCTAssertEqual(
            plural.message,
            "hasn't reached your journal yet — tried 3 times. it'll try again automatically when you reconnect."
        )
    }

    func testFailureLegibilityPermanentMessageUsesPlainReasonBuckets() throws {
        let now = Self.date(year: 2026, month: 6, day: 14, hour: 12, minute: 0)
        let cases: [(String?, String)] = [
            ("network connection lost", "this can't be sent — the connection wasn't available. you can remove it from this phone."),
            ("request timed out -1001", "this can't be sent — the connection took too long. you can remove it from this phone."),
            ("HTTP 503: service unavailable", "this can't be sent — your journal couldn't accept it. you can remove it from this phone."),
            ("upload failed after 3 attempts", "this can't be sent — something got in the way. you can remove it from this phone."),
        ]

        for (rawReason, expectedMessage) in cases {
            let legibility = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
                for: Self.item(
                    sourceKind: .audio,
                    sendState: .needsAttention,
                    failureReason: rawReason,
                    failureAttemptCount: 3,
                    retryAvailable: false
                ),
                now: now
            ))
            XCTAssertEqual(legibility.message, expectedMessage)
        }
    }

    func testFailureBucketClassifiesPersistedFailureReasonShapes() {
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.failureBucket(for: "HTTP 503: service unavailable"), .server)
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.failureBucket(for: "request timed out -1001"), .timeout)
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.failureBucket(for: "network-lost"), .network)
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.failureBucket(for: "cannot-find-host"), .network)
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.failureBucket(for: "offline -1009"), .network)
        XCTAssertEqual(OnThisPhoneItemDetailPresentation.failureBucket(for: "upload failed after 3 attempts"), .unknown)
    }

    func testFailureLegibilityFormatsLastTriedWithInjectedDateContext() throws {
        let now = Self.date(year: 2026, month: 6, day: 14, hour: 16, minute: 0)
        let lastAttemptAt = Self.date(year: 2026, month: 6, day: 14, hour: 15, minute: 0)

        let legibility = try XCTUnwrap(OnThisPhoneItemDetailPresentation.failureLegibility(
            for: Self.item(
                sourceKind: .audio,
                sendState: .needsAttention,
                failureAttemptCount: 1,
                retryAvailable: true,
                lastAttemptAt: lastAttemptAt
            ),
            now: now,
            locale: Self.locale,
            timeZone: Self.timeZone
        ))

        XCTAssertEqual(legibility.lastTried, "last tried today at 3:00\u{202F}PM")
    }

    func testJournalAvailabilityMatrix() {
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.journalAvailability(
                sendState: .savedOnThisPhone,
                hasConveyURL: true,
                sourceKind: .audio
            ),
            OnThisPhoneJournalAvailability(
                enabled: false,
                hint: SourceVocabulary.onThisPhoneJournalHintPending
            )
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.journalAvailability(
                sendState: .sending,
                hasConveyURL: true,
                sourceKind: .share
            ),
            OnThisPhoneJournalAvailability(
                enabled: false,
                hint: SourceVocabulary.onThisPhoneJournalHintPending
            )
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.journalAvailability(
                sendState: .needsAttention,
                hasConveyURL: true,
                sourceKind: .location
            ),
            OnThisPhoneJournalAvailability(
                enabled: false,
                hint: SourceVocabulary.onThisPhoneJournalHintPending
            )
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.journalAvailability(
                sendState: .inYourJournal,
                hasConveyURL: true,
                sourceKind: .share
            ),
            OnThisPhoneJournalAvailability(
                enabled: true,
                hint: SourceVocabulary.onThisPhoneJournalHintSaved
            )
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.journalAvailability(
                sendState: .inYourJournal,
                hasConveyURL: true,
                sourceKind: .location
            ),
            OnThisPhoneJournalAvailability(
                enabled: true,
                hint: SourceVocabulary.onThisPhoneJournalHintLocationSaved
            )
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.journalAvailability(
                sendState: .inYourJournal,
                hasConveyURL: false,
                sourceKind: .audio
            ),
            OnThisPhoneJournalAvailability(
                enabled: false,
                hint: SourceVocabulary.onThisPhoneJournalHintUnreachable
            )
        )
        XCTAssertEqual(
            OnThisPhoneItemDetailPresentation.journalAvailability(
                sendState: .inYourJournal,
                hasConveyURL: false,
                sourceKind: .location
            ),
            OnThisPhoneJournalAvailability(
                enabled: false,
                hint: SourceVocabulary.onThisPhoneJournalHintLocationUnreachable
            )
        )
    }

    func testDetailRowsUseExpectedOrderAndFallbacks() {
        let itemTime = Self.date(year: 2026, month: 6, day: 14, hour: 9, minute: 30)
        let audioRows = OnThisPhoneItemDetailPresentation.detailRows(
            for: Self.item(sourceKind: .audio, filename: "chunk.m4a", bytes: 2048, itemTime: itemTime),
            locale: Self.locale,
            timeZone: Self.timeZone
        )
        XCTAssertEqual(audioRows, [
            OnThisPhoneDetailRow(
                label: SourceVocabulary.onThisPhoneFileLabel,
                value: SourceVocabulary.onThisPhoneFileDetail(
                    filename: "chunk.m4a",
                    size: ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file)
                )
            ),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneWhenLabel, value: Self.fullDateTime(itemTime)),
        ])

        let fallbackRows = OnThisPhoneItemDetailPresentation.detailRows(
            for: Self.item(sourceKind: .share, filename: nil, bytes: nil, itemTime: nil),
            locale: Self.locale,
            timeZone: Self.timeZone
        )
        XCTAssertEqual(fallbackRows, [
            OnThisPhoneDetailRow(
                label: SourceVocabulary.onThisPhoneFileLabel,
                value: SourceVocabulary.onThisPhoneFileDetail(
                    filename: SourceVocabulary.notProvided,
                    size: SourceVocabulary.notProvided
                )
            ),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneWhenLabel, value: SourceVocabulary.notProvided),
        ])

        let locationRows = OnThisPhoneItemDetailPresentation.detailRows(
            for: Self.item(sourceKind: .location, itemTime: itemTime, locationFixCount: 1),
            locale: Self.locale,
            timeZone: Self.timeZone
        )
        XCTAssertEqual(locationRows, [
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneObservationsLabel, value: "1 fix"),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneWhenLabel, value: Self.fullDateTime(itemTime)),
        ])

        let missingLocationRows = OnThisPhoneItemDetailPresentation.detailRows(
            for: Self.item(sourceKind: .location, itemTime: nil, locationFixCount: nil),
            locale: Self.locale,
            timeZone: Self.timeZone
        )
        XCTAssertEqual(missingLocationRows, [
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneObservationsLabel, value: SourceVocabulary.notProvided),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneWhenLabel, value: SourceVocabulary.notProvided),
        ])
    }

    func testDetailRowsIncludeFailureDetailWhenAvailable() {
        let itemTime = Self.date(year: 2026, month: 6, day: 14, hour: 9, minute: 30)
        let rows = OnThisPhoneItemDetailPresentation.detailRows(
            for: Self.item(
                sourceKind: .audio,
                sendState: .needsAttention,
                filename: "chunk.m4a",
                bytes: 2048,
                itemTime: itemTime,
                failureReason: "journal rejected the upload (HTTP 503)",
                failureAttemptCount: 5,
                sourceLabel: SourceVocabulary.onThisPhoneOmiAudioSourceLabel,
                retryAvailable: true
            ),
            locale: Self.locale,
            timeZone: Self.timeZone
        )

        XCTAssertEqual(rows, [
            OnThisPhoneDetailRow(
                label: SourceVocabulary.onThisPhoneFileLabel,
                value: SourceVocabulary.onThisPhoneFileDetail(
                    filename: "chunk.m4a",
                    size: ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file)
                )
            ),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneWhenLabel, value: Self.fullDateTime(itemTime)),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneSourceLabel, value: SourceVocabulary.onThisPhoneOmiAudioSourceLabel),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneFailureReasonLabel, value: "journal rejected the upload (HTTP 503)"),
            OnThisPhoneDetailRow(label: SourceVocabulary.onThisPhoneFailureStatusLabel, value: "upload failed after 5 attempts"),
        ])
        XCTAssertFalse(rows.contains { $0.label == "next" || $0.value.contains("tap retry") })
    }
}

private extension OnThisPhoneItemDetailPresentationTests {
    static let locale = Locale(identifier: "en_US_POSIX")
    static let timeZone = TimeZone(secondsFromGMT: 0)!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = self.timeZone
        return calendar
    }

    static func item(
        sourceKind: OnThisPhoneSourceKind,
        sendState: OnThisPhoneSendState = .savedOnThisPhone,
        contentType: String? = nil,
        filename: String? = "item.dat",
        bytes: Int64? = nil,
        originApp: String? = nil,
        itemTime: Date? = nil,
        rawFileURL: URL? = nil,
        audioDurationS: Double? = nil,
        locationFixCount: Int? = nil,
        failureReason: String? = nil,
        failureAttemptCount: Int? = nil,
        sourceLabel: String? = nil,
        retryAvailable: Bool = false,
        lastAttemptAt: Date? = nil
    ) -> OnThisPhoneItem {
        OnThisPhoneItem(
            id: UUID().uuidString,
            sourceKind: sourceKind,
            sendState: sendState,
            contentType: contentType,
            filename: filename,
            bytes: bytes,
            originApp: originApp,
            basis: nil,
            itemTime: itemTime,
            targetJournal: nil,
            stream: nil,
            day: nil,
            segment: nil,
            deliveredAt: nil,
            rawFileURL: rawFileURL,
            audioDurationS: audioDurationS,
            locationFixCount: locationFixCount,
            failureReason: failureReason,
            failureAttemptCount: failureAttemptCount,
            sourceLabel: sourceLabel,
            retryAvailable: retryAvailable,
            lastAttemptAt: lastAttemptAt
        )
    }

    static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        DateComponents(
            calendar: self.calendar,
            timeZone: self.timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ).date!
    }

    static func shortTime(_ date: Date) -> String {
        OnThisPhoneItemDetailPresentation.shortTimeLabel(
            for: date,
            locale: self.locale,
            timeZone: self.timeZone
        )
    }

    static func fullDateTime(_ date: Date) -> String {
        OnThisPhoneItemDetailPresentation.fullDateTimeLabel(
            for: date,
            locale: self.locale,
            timeZone: self.timeZone
        )
    }

    static func relativeDay(_ date: Date, now: Date) -> String {
        OnThisPhoneItemDetailPresentation.relativeDayLabel(
            for: date,
            now: now,
            calendar: self.calendar,
            locale: self.locale,
            timeZone: self.timeZone
        )
    }

    static func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = self.calendar
        formatter.locale = self.locale
        formatter.timeZone = self.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
