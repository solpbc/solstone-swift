// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ScreencastCopyTests: XCTestCase {
    func testExactScreencastCopy() {
        XCTAssertEqual(SourceVocabulary.screencastDisplayName, "screen")
        XCTAssertEqual(SourceVocabulary.screencastActiveSubtext, "sharing your screen")
        XCTAssertEqual(SourceVocabulary.screencastStartingSubtext, "waiting for the system sheet")
        XCTAssertEqual(SourceVocabulary.screencastOffSubtext, "off")
        XCTAssertEqual(SourceVocabulary.screencastAttentionSubtext, "needs attention")
        XCTAssertEqual(SourceVocabulary.screencastUnavailableSubtext, "unavailable")
        XCTAssertEqual(SourceVocabulary.screencastDetailTitle, "screen")
        XCTAssertEqual(SourceVocabulary.screencastStateTitle, "state")
        XCTAssertEqual(SourceVocabulary.screencastRecentTitle, "recent")
        XCTAssertEqual(SourceVocabulary.screencastDeliveryTitle, "delivery")
        XCTAssertEqual(SourceVocabulary.screencastStartButton, "start screen")
        XCTAssertEqual(SourceVocabulary.screencastStopButton, "stop screen")
        XCTAssertEqual(SourceVocabulary.screencastOpenSystemSheet, "open system sheet")
        XCTAssertEqual(SourceVocabulary.screencastReadyText, "screen is ready")
        XCTAssertEqual(SourceVocabulary.screencastStartingText, "waiting for the system sheet")
        XCTAssertEqual(SourceVocabulary.screencastActiveText, "screen is active")
        XCTAssertEqual(SourceVocabulary.screencastUnavailableText, "screen is unavailable")
        XCTAssertEqual(SourceVocabulary.screencastNoVideoText, "no screen video was saved")
        XCTAssertEqual(SourceVocabulary.screencastFinalizeFailedText, "screen video could not be saved")
        XCTAssertEqual(SourceVocabulary.screencastFinalizeTimeoutText, "screen video timed out while saving")
        XCTAssertEqual(SourceVocabulary.screencastFilesystemFailedText, "screen video could not be stored")
        XCTAssertEqual(SourceVocabulary.screencastStorageLowText, "screen stopped. this device is low on storage.")
        XCTAssertEqual(SourceVocabulary.screencastSystemEndedSubtext, "the system ended screen sharing")
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBody,
            "what's on your screen goes into your journal. tap \"Start Broadcast\" in the sheet that comes up. the system ends screen sharing when this device locks."
        )
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBodyActive,
            "to stop sharing your screen, tap \"Stop Broadcast\" in the sheet that comes up."
        )
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBodyOff,
            "what's on your screen goes into your journal. tap \"Start Broadcast\" in the sheet that comes up. the system ends screen sharing when this device locks."
        )
    }

    func testScreencastPrimerAndActionHelpers() {
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBody(state: .active(sessionID: UUID(), segmentID: UUID(), startedAt: Date())),
            SourceVocabulary.screencastPrimerBodyActive
        )
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBody(state: .off),
            SourceVocabulary.screencastPrimerBodyOff
        )
        XCTAssertEqual(
            SourceVocabulary.screencastPrimerBody(state: .starting(startedAt: Date(), deadline: Date())),
            SourceVocabulary.screencastPrimerBodyOff
        )

        XCTAssertEqual(
            SourceVocabulary.screencastActionTitle(state: .active(sessionID: UUID(), segmentID: UUID(), startedAt: Date())),
            SourceVocabulary.screencastOpenSystemSheet
        )
        XCTAssertEqual(
            SourceVocabulary.screencastActionTitle(state: .off),
            SourceVocabulary.screencastStartButton
        )
        XCTAssertEqual(
            SourceVocabulary.screencastActionTitle(state: .starting(startedAt: Date(), deadline: Date())),
            SourceVocabulary.screencastStartButton
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

    private static let screencastCopy = [
        SourceVocabulary.screencastDisplayName,
        SourceVocabulary.screencastActiveSubtext,
        SourceVocabulary.screencastStartingSubtext,
        SourceVocabulary.screencastOffSubtext,
        SourceVocabulary.screencastAttentionSubtext,
        SourceVocabulary.screencastUnavailableSubtext,
        SourceVocabulary.screencastDetailTitle,
        SourceVocabulary.screencastStateTitle,
        SourceVocabulary.screencastRecentTitle,
        SourceVocabulary.screencastDeliveryTitle,
        SourceVocabulary.screencastStartButton,
        SourceVocabulary.screencastStopButton,
        SourceVocabulary.screencastOpenSystemSheet,
        SourceVocabulary.screencastReadyText,
        SourceVocabulary.screencastStartingText,
        SourceVocabulary.screencastActiveText,
        SourceVocabulary.screencastUnavailableText,
        SourceVocabulary.screencastNoVideoText,
        SourceVocabulary.screencastFinalizeFailedText,
        SourceVocabulary.screencastFinalizeTimeoutText,
        SourceVocabulary.screencastFilesystemFailedText,
        SourceVocabulary.screencastStorageLowText,
        SourceVocabulary.screencastSystemEndedSubtext,
        SourceVocabulary.screencastPrimerBody,
        SourceVocabulary.screencastPrimerBodyActive,
        SourceVocabulary.screencastPrimerBodyOff,
    ]
}
