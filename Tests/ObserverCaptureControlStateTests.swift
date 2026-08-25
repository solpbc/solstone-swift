// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class ObserverCaptureControlStateTests: XCTestCase {
    func testIdleUnpairedIsUnavailable() {
        let value = ObserverCaptureControlState.value(
            snapshot: self.snapshot(pairing: self.unpairedPairing, session: .notLive),
            permission: .granted
        )

        XCTAssertEqual(value, ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .journalRequired))
    }

    func testLivePairedIsOnAndPopulated() {
        let value = ObserverCaptureControlState.value(
            snapshot: self.snapshot(pairing: self.pairedPairing, session: .live(mode: .meeting, startedAt: self.now)),
            permission: .denied
        )

        XCTAssertEqual(value, ObserverCaptureControlValue(isOn: true, isUnavailable: false, status: nil))
    }

    func testIdlePairedDistinguishesUndeterminedAndDeniedPermission() {
        let snapshot = self.snapshot(pairing: self.pairedPairing, session: .notLive)

        XCTAssertEqual(
            ObserverCaptureControlState.value(snapshot: snapshot, permission: .undetermined),
            ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .permissionUndetermined)
        )
        XCTAssertEqual(
            ObserverCaptureControlState.value(snapshot: snapshot, permission: .denied),
            ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .permissionDenied)
        )
    }

    func testIdlePairedGrantedPermissionIsEnabled() {
        let value = ObserverCaptureControlState.value(
            snapshot: self.snapshot(pairing: self.pairedPairing, session: .notLive),
            permission: .granted
        )

        XCTAssertEqual(value, ObserverCaptureControlValue(isOn: false, isUnavailable: false, status: nil))
    }

    func testMissingSnapshotIsUnavailable() {
        let value = ObserverCaptureControlState.value(snapshot: nil, permission: .granted)

        XCTAssertEqual(value, ObserverCaptureControlValue(isOn: false, isUnavailable: true, status: .unknownState))
    }
}

private extension ObserverCaptureControlStateTests {
    var now: Date {
        Date(timeIntervalSince1970: 1_776_144_000)
    }

    var pairedPairing: AppGroupMirror.PairingSnapshot {
        AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true)
    }

    var unpairedPairing: AppGroupMirror.PairingSnapshot {
        AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false)
    }

    func snapshot(
        pairing: AppGroupMirror.PairingSnapshot,
        session: AppGroupMirror.SessionState
    ) -> AppGroupMirror.Snapshot {
        AppGroupMirror.Snapshot(
            schemaVersion: AppGroupMirror.Snapshot.currentSchemaVersion,
            writtenAt: self.now,
            pairing: pairing,
            microphonePermission: .granted,
            session: session,
            sourceStates: [:],
            backlogCount: 0
        )
    }
}
