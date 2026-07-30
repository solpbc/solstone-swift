// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class WatchNoticePolicyTests: XCTestCase {
    func testOwnerStopHasNoNoticeCopy() {
        XCTAssertNil(WatchNoticeCopy(reason: .ownerStopped, disposition: .ownerStopped))
    }

    func testOwnerStoppedWithDetectedDispositionStillDoesNotScheduleWristNotice() {
        XCTAssertEqual(
            watchNoticeDecision(
                authorizationStatus: .authorized,
                alertSetting: .enabled,
                disposition: .detectedStoppedItself,
                reason: .ownerStopped,
                leaseArmed: false
            ),
            .none
        )
        XCTAssertEqual(
            watchNoticeDecision(
                authorizationStatus: .authorized,
                alertSetting: .enabled,
                disposition: .detectedStoppedItself,
                reason: .ownerStopped,
                leaseArmed: true
            ),
            .cancelLease
        )
    }

    func testTerminalResolverHandlesHalfPopulatedPairs() {
        XCTAssertNil(WatchNoticeCopy(terminalReason: nil, terminalDisposition: nil))
        XCTAssertNil(WatchNoticeCopy(
            terminalReason: .audioInterrupted,
            terminalDisposition: .ownerStopped
        ))
        XCTAssertEqual(
            WatchNoticeCopy(terminalReason: nil, terminalDisposition: .detectedStoppedItself),
            .audioCouldNotBeConfirmed
        )
        XCTAssertEqual(
            WatchNoticeCopy(terminalReason: .audioInterrupted, terminalDisposition: nil),
            .audioCouldNotBeConfirmed
        )
        XCTAssertEqual(
            WatchNoticeCopy(terminalReason: .audioInterrupted, terminalDisposition: .detectedStoppedItself),
            .audioStoppedItself
        )
    }

    func testCannotConfirmCopyIsNotDetectedCopy() {
        let detectedCopies = Set(WatchNoticeCopy.allCases.filter(\.isDetectedCopy).map(\.title))

        XCTAssertFalse(detectedCopies.contains(WatchNoticeCopy.audioCouldNotBeConfirmed.title))
    }

    func testDifferentRemediesHaveDistinctCopy() throws {
        let microphone = try XCTUnwrap(WatchNoticeCopy(
            reason: .microphonePermissionRevoked,
            disposition: .detectedStoppedItself
        ))
        let start = try XCTUnwrap(WatchNoticeCopy(
            reason: .audioStartFailed,
            disposition: .detectedStoppedItself
        ))
        let stopped = try XCTUnwrap(WatchNoticeCopy(
            reason: .audioInterrupted,
            disposition: .detectedStoppedItself
        ))
        let saved = try XCTUnwrap(WatchNoticeCopy(
            reason: .audioUndecodable,
            disposition: .detectedStoppedItself
        ))
        let confirmed = try XCTUnwrap(WatchNoticeCopy(
            reason: .processExitedWhileActive,
            disposition: .inferredStoppedItself
        ))

        XCTAssertEqual(Set([
            microphone.title,
            start.title,
            stopped.title,
            saved.title,
            confirmed.title,
        ]).count, 5)
    }

    func testCannotConfirmDispositionOverridesDetectedReason() {
        XCTAssertEqual(
            WatchNoticeCopy(reason: .audioInterrupted, disposition: .inferredStoppedItself),
            .audioCouldNotBeConfirmed
        )
    }

    func testDetectedAndInferredDispositionCopyDifferForSameReason() throws {
        let detected = try XCTUnwrap(WatchNoticeCopy(
            reason: .audioInterrupted,
            disposition: .detectedStoppedItself
        ))
        let inferred = try XCTUnwrap(WatchNoticeCopy(
            reason: .audioInterrupted,
            disposition: .inferredStoppedItself
        ))

        XCTAssertNotEqual(detected.title, inferred.title)
        XCTAssertNotEqual(detected.body, inferred.body)
    }

    func testInferredDispositionAlwaysUsesCannotConfirmCopy() {
        for reason in WatchCaptureTerminalReason.allCases {
            XCTAssertEqual(
                WatchNoticeCopy(reason: reason, disposition: .inferredStoppedItself),
                .audioCouldNotBeConfirmed,
                "\(reason)"
            )
        }
    }

    func testAllNonOwnerDetectedReasonsHaveNoticeCopy() {
        for reason in WatchCaptureTerminalReason.allCases where reason != .ownerStopped {
            for disposition in [WatchCaptureTerminalDisposition.detectedStoppedItself, .inferredStoppedItself] {
                XCTAssertNotNil(
                    WatchNoticeCopy(reason: reason, disposition: disposition),
                    "\(reason) \(disposition)"
                )
            }
        }
    }

    func testOwnerFacingNoticeCopyDoesNotExposeRawValuesOrSwiftText() {
        for reason in WatchCaptureTerminalReason.allCases {
            for disposition in Self.terminalDispositions {
                guard let copy = WatchNoticeCopy(reason: reason, disposition: disposition) else {
                    continue
                }
                Self.assertOwnerFacingCopyIsClean(copy.title)
                Self.assertOwnerFacingCopyIsClean(copy.body)
            }
        }
    }

    func testNewWatchStatusVocabularyAvoidsForbiddenWords() {
        for string in [
            SourceVocabulary.watchStatusAudioOutcomeLabel,
            SourceVocabulary.watchStatusAudioOutcomeOwnerStopped,
        ] {
            XCTAssertFalse(string.contains("capture"))
            XCTAssertFalse(string.contains("server"))
        }
    }

    func testWristAlertDecisionSeparatesRequestAndSettingsRoutes() {
        XCTAssertEqual(
            watchNoticeDecision(
                authorizationStatus: .notDetermined,
                alertSetting: .enabled,
                disposition: .detectedStoppedItself,
                reason: .audioInterrupted,
                leaseArmed: true
            ),
            .cannotSchedule(settingsRoute: .notificationGrant)
        )
        XCTAssertEqual(
            watchNoticeDecision(
                authorizationStatus: .denied,
                alertSetting: .enabled,
                disposition: .detectedStoppedItself,
                reason: .audioInterrupted,
                leaseArmed: true
            ),
            .cannotSchedule(settingsRoute: .notificationSettings)
        )
        XCTAssertEqual(
            watchNoticeDecision(
                authorizationStatus: .authorized,
                alertSetting: .enabled,
                disposition: .detectedStoppedItself,
                reason: .audioInterrupted,
                leaseArmed: true
            ),
            .schedule(copy: .audioStoppedItself)
        )
    }

    func testWristAlertAssuranceCopy() {
        XCTAssertEqual(WatchWristAlertAssurance.willTap.line, SourceVocabulary.watchWristAlertWillTap)
        XCTAssertEqual(WatchWristAlertAssurance.alertsOff.line, SourceVocabulary.watchWristAlertsOff)
        XCTAssertNil(watchWristAlertAssurance(authorization: .notDetermined, alertSetting: .enabled))
        XCTAssertEqual(
            watchWristAlertAssurance(authorization: .authorized, alertSetting: .notSupported),
            .alertsOff
        )
    }

    func testForegroundNoticePresentationOptionsExcludeSound() {
        XCTAssertEqual(watchNoticePresentationOptions(), [.banner, .list])
    }

    func testMicrophoneRevokedDetectedCopyHasMicrophoneRouteInPresentation() {
        let presentation = WatchCaptureOwnerPresentation(
            status: .needsAttention(WatchCaptureTerminalReason.microphonePermissionRevoked.observerError),
            queuedCount: 0,
            settingsRoute: .microphone,
            terminalReason: .microphonePermissionRevoked,
            terminalDisposition: .detectedStoppedItself
        )

        XCTAssertEqual(presentation.settingsRoute, .microphone)
        XCTAssertEqual(
            WatchNoticeCopy(reason: .microphonePermissionRevoked, disposition: .detectedStoppedItself),
            .microphoneAccessNeeded
        )
    }
}

private extension WatchNoticePolicyTests {
    static let terminalDispositions: [WatchCaptureTerminalDisposition] = [
        .ownerStopped,
        .detectedStoppedItself,
        .inferredStoppedItself,
    ]

    static var terminalRawValues: [String] {
        WatchCaptureTerminalReason.allCases.map(\.rawValue)
            + terminalDispositions.map(\.rawValue)
    }

    static func assertOwnerFacingCopyIsClean(
        _ string: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for rawValue in terminalRawValues {
            XCTAssertFalse(string.contains(rawValue), rawValue, file: file, line: line)
        }

        XCTAssertNil(
            string.range(of: #"[a-z]+(?:[-_][a-z0-9]+)+"#, options: .regularExpression),
            file: file,
            line: line
        )
        XCTAssertFalse(string.contains("Error"), file: file, line: line)
        XCTAssertFalse(string.contains("NSError"), file: file, line: line)
        XCTAssertFalse(string.contains("Swift"), file: file, line: line)
        XCTAssertFalse(string.contains("Optional("), file: file, line: line)
    }
}
