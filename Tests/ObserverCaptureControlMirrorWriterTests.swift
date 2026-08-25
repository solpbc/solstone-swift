// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
private final class ObserverCaptureControlReloadSpy: ObserverCaptureControlReloading {
    private(set) var kinds: [String] = []

    func reloadControls(ofKind kind: String) {
        self.kinds.append(kind)
    }
}

nonisolated final class ObserverCaptureControlMirrorWriterTests: XCTestCase {
    private var rootURL: URL!

    override func setUp() {
        super.setUp()
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverCaptureControlMirrorWriterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.rootURL)
        self.rootURL = nil
        super.tearDown()
    }

    @MainActor
    func testLiveWriteReloadsControlsAndNextReadReflectsTheLiveState() {
        let rootURL = self.rootURL!
        let mirror = AppGroupMirror(rootURLProvider: { rootURL })
        let controls = ObserverCaptureControlReloadSpy()
        let startedAt = Date(timeIntervalSince1970: 1_776_144_000)

        let result = ObserverCaptureControlMirrorWriter.update(
            session: .live(mode: .meeting, startedAt: startedAt),
            mirror: mirror,
            controls: controls
        )

        guard case .success = result else {
            return XCTFail("expected app group mirror write to succeed")
        }
        XCTAssertEqual(controls.kinds, [observerCaptureControlKind])
        XCTAssertEqual(mirror.snapshot()?.microphonePermission, .undetermined)
        XCTAssertEqual(
            ObserverCaptureControlState.value(snapshot: mirror.snapshot(), permission: .granted),
            ObserverCaptureControlValue(isOn: true, isUnavailable: false, status: nil)
        )
    }

    @MainActor
    func testWriteCarriesExistingMicrophonePermissionForward() {
        let rootURL = self.rootURL!
        let mirror = AppGroupMirror(rootURLProvider: { rootURL })
        let controls = ObserverCaptureControlReloadSpy()
        let pairing = AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true)

        guard case .success = mirror.updateSessionAndSources(
            pairing: pairing,
            microphonePermission: .denied,
            session: .notLive,
            sourceStates: [.observer: .off],
            backlogCount: 2
        ) else {
            return XCTFail("expected initial app group mirror write to succeed")
        }

        guard case .success = ObserverCaptureControlMirrorWriter.update(
            session: .live(mode: .meeting, startedAt: Date(timeIntervalSince1970: 1_776_144_000)),
            mirror: mirror,
            controls: controls
        ) else {
            return XCTFail("expected app group mirror write to succeed")
        }

        XCTAssertEqual(mirror.snapshot()?.microphonePermission, .denied)
        XCTAssertEqual(controls.kinds, [observerCaptureControlKind])
    }
}
