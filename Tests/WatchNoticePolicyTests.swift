// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class WatchNoticePolicyTests: XCTestCase {
    func testOwnerStopHasNoNoticeCopy() {
        XCTAssertNil(WatchNoticeCopy(reason: .ownerStopped, disposition: .ownerStopped))
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
