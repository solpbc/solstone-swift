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
        XCTAssertEqual(SourceVocabulary.screencastPointerFailedText, "screen could not connect to this journal")
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
        SourceVocabulary.screencastPointerFailedText,
    ]
}
