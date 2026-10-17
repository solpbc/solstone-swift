// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ScreencastCopyTests: XCTestCase {
    func testExactScreencastCopy() {
        XCTAssertEqual(SourceVocabulary.screencastDisplayName.key, "ios.sourceSync.screencastDisplayName")
        XCTAssertEqual(SourceVocabulary.screencastActiveSubtext.key, "ios.sourceSync.screencastActiveSubtext")
        XCTAssertEqual(SourceVocabulary.screencastStartingSubtext.key, "ios.sourceSync.screencastStartingSubtext")
        XCTAssertEqual(SourceVocabulary.screencastOffSubtext.key, "ios.sourceSync.screencastOffSubtext")
        XCTAssertEqual(SourceVocabulary.screencastAttentionSubtext.key, "ios.sourceSync.screencastAttentionSubtext")
        XCTAssertEqual(SourceVocabulary.screencastUnavailableSubtext.key, "ios.sourceSync.screencastUnavailableSubtext")
        XCTAssertEqual(SourceVocabulary.screencastDetailTitle.key, "ios.sourceSync.screencastDetailTitle")
        XCTAssertEqual(SourceVocabulary.screencastStateTitle.key, "ios.sourceSync.screencastStateTitle")
        XCTAssertEqual(SourceVocabulary.screencastRecentTitle.key, "ios.sourceSync.screencastRecentTitle")
        XCTAssertEqual(SourceVocabulary.screencastDeliveryTitle.key, "ios.sourceSync.screencastDeliveryTitle")
        XCTAssertEqual(SourceVocabulary.screencastStartButton.key, "ios.sourceSync.screencastStartButton")
        XCTAssertEqual(SourceVocabulary.screencastStopButton.key, "ios.sourceSync.screencastStopButton")
        XCTAssertEqual(SourceVocabulary.screencastOpenSystemSheet.key, "ios.sourceSync.screencastOpenSystemSheet")
        XCTAssertEqual(SourceVocabulary.screencastReadyText.key, "ios.sourceSync.screencastReadyText")
        XCTAssertEqual(SourceVocabulary.screencastStartingText.key, "ios.sourceSync.screencastStartingText")
        XCTAssertEqual(SourceVocabulary.screencastActiveText.key, "ios.sourceSync.screencastActiveText")
        XCTAssertEqual(SourceVocabulary.screencastUnavailableText.key, "ios.sourceSync.screencastUnavailableText")
        XCTAssertEqual(SourceVocabulary.screencastNoVideoText.key, "ios.sourceSync.screencastNoVideoText")
        XCTAssertEqual(SourceVocabulary.screencastFinalizeFailedText.key, "ios.sourceSync.screencastFinalizeFailedText")
        XCTAssertEqual(SourceVocabulary.screencastFinalizeTimeoutText.key, "ios.sourceSync.screencastFinalizeTimeoutText")
        XCTAssertEqual(SourceVocabulary.screencastFilesystemFailedText.key, "ios.sourceSync.screencastFilesystemFailedText")
        XCTAssertEqual(SourceVocabulary.screencastStorageLowText.key, "ios.sourceSync.screencastStorageLowText")
        XCTAssertEqual(SourceVocabulary.screencastSystemEndedSubtext.key, "ios.sourceSync.screencastSystemEndedSubtext")
        XCTAssertEqual(SourceVocabulary.screencastPrimerBody.key, "ios.sourceSync.screencastPrimerBodyOff")
        XCTAssertEqual(SourceVocabulary.screencastPrimerBodyActive.key, "ios.sourceSync.screencastPrimerBodyActive")
        XCTAssertEqual(SourceVocabulary.screencastPrimerBodyOff.key, "ios.sourceSync.screencastPrimerBodyOff")
    }

    func testScreencastPrimerAndActionHelpers() {
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBody(state: .active(sessionID: UUID(), segmentID: UUID(), startedAt: Date())),
            String(localized: SourceVocabulary.screencastPrimerBodyActive)
        )
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBody(state: .off),
            String(localized: SourceVocabulary.screencastPrimerBodyOff)
        )
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBody(state: .starting(startedAt: Date(), deadline: Date())),
            String(localized: SourceVocabulary.screencastPrimerBodyOff)
        )

        XCTAssertEqual(
            SourceVocabulary.screencastActionTitle(state: .active(sessionID: UUID(), segmentID: UUID(), startedAt: Date())),
            String(localized: SourceVocabulary.screencastOpenSystemSheet)
        )
        XCTAssertEqual(
            SourceVocabulary.screencastActionTitle(state: .off),
            String(localized: SourceVocabulary.screencastStartButton)
        )
        XCTAssertEqual(
            SourceVocabulary.screencastActionTitle(state: .starting(startedAt: Date(), deadline: Date())),
            String(localized: SourceVocabulary.screencastStartButton)
        )
    }

    func testScreencastDeliverySummary() {
        XCTAssertEqual(
            ScreencastDetailPresentation.deliverySummary(pending: 0, failed: 0).line,
            "nothing waiting right now."
        )
        XCTAssertEqual(
            ScreencastDetailPresentation.deliverySummary(pending: 1, failed: 0).line,
            "1 stretch of screen on the way to your journal."
        )
        XCTAssertEqual(
            ScreencastDetailPresentation.deliverySummary(pending: 3, failed: 0).line,
            "3 stretches of screen on the way to your journal."
        )
        XCTAssertEqual(
            ScreencastDetailPresentation.deliverySummary(pending: 0, failed: 1).line,
            "1 stretch of screen needs attention."
        )
        XCTAssertEqual(
            ScreencastDetailPresentation.deliverySummary(pending: 0, failed: 4).line,
            "4 stretches of screen need attention."
        )
        XCTAssertEqual(
            ScreencastDetailPresentation.deliverySummary(pending: 5, failed: 2).line,
            "2 stretches of screen need attention."
        )
    }

    func testScreencastCopyIsLowercaseFirst() {
        for string in Self.screencastCopy {
            guard let first = string.first(where: { $0.isLetter }) else { continue }
            XCTAssertEqual(first, Character(String(first).lowercased()), string)
        }
    }

    func testScreencastCopyAvoidsBannedOwnerVisibleTerms() {
        let banned = ["capture", "record", "recording", "watch", "monitor", "track", "collect", "keeper", "assistant", "server", "service"]

        for string in Self.screencastCopy {
            let lowercased = string.lowercased()
            for term in banned {
                XCTAssertFalse(lowercased.contains(term), "\(string) contains \(term)")
            }
        }
    }

    func testOnThisPhoneScreencastRemainsScreenVideo() {
        XCTAssertEqual(SourceVocabulary.onThisPhoneSourceName(for: .screencast), "screen")
        XCTAssertEqual(SourceVocabulary.onThisPhoneDropScreencastDescriptor, "screen video")
    }

    func testNoPhoneNamingInScreencastCopy() {
        for string in Self.screencastCopy + [
            SourceVocabulary.onThisPhoneSourceName(for: .screencast),
            SourceVocabulary.onThisPhoneDropScreencastDescriptor,
        ] {
            XCTAssertFalse(string.contains("Phone"), string)
            XCTAssertFalse(string.contains("phone"), string)
        }
    }

    private static var screencastCopy: [String] {
        PilotCopy.resources(locale: Locale(identifier: "en_US"), bundle: .main)
            .filter { $0.key.hasPrefix("ios.sourceSync.screencast") }
            .map { String(localized: $0) }
    }
}
