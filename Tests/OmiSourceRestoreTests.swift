// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@preconcurrency import CoreBluetooth
import XCTest

nonisolated final class OmiSourceRestoreTests: XCTestCase {
    func testRestoreActionDisconnectedRearmsConnect() {
        XCTAssertEqual(
            OmiSourceLogic.restoreAction(
                peripheralState: .disconnected,
                hasAudioService: false,
                isAudioNotifying: false
            ),
            .rearmConnect
        )
        XCTAssertEqual(
            OmiSourceLogic.restoreAction(
                peripheralState: .connecting,
                hasAudioService: true,
                isAudioNotifying: true
            ),
            .rearmConnect
        )
    }

    func testRestoreActionConnectedWithoutAudioServiceDiscoversServices() {
        XCTAssertEqual(
            OmiSourceLogic.restoreAction(
                peripheralState: .connected,
                hasAudioService: false,
                isAudioNotifying: false
            ),
            .discoverServices
        )
    }

    func testRestoreActionConnectedWithAudioServiceSubscribesWhenNotNotifying() {
        XCTAssertEqual(
            OmiSourceLogic.restoreAction(
                peripheralState: .connected,
                hasAudioService: true,
                isAudioNotifying: false
            ),
            .subscribeAudio
        )
    }

    func testRestoreActionConnectedAndNotifyingIsAlreadyLive() {
        XCTAssertEqual(
            OmiSourceLogic.restoreAction(
                peripheralState: .connected,
                hasAudioService: true,
                isAudioNotifying: true
            ),
            .alreadyLive
        )
    }

    func testRestoreIdentifierConstant() {
        XCTAssertEqual(OmiSourceManager.restoreIdentifier, "app.solstone.swift.omi-source")
    }

    @MainActor
    func testWillRestoreStateHandlerExistsWithoutInstantiatingManager() {
        let handler = OmiSourceManager.handleWillRestoreState
        _ = handler
    }
}
