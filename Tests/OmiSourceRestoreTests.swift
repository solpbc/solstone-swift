// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OmiSourceRestoreTests: XCTestCase {
    func testRestoreActionDisconnectedRearmsConnect() {
        XCTAssertEqual(
                OmiSourceLogic.readinessAction(
                    peripheralState: .disconnected,
                    hasAudioService: false,
                    isAudioNotifying: false,
                    codec: .notRead
                ),
                .rearmConnect
        )
        XCTAssertEqual(
                OmiSourceLogic.readinessAction(
                    peripheralState: .connecting,
                    hasAudioService: true,
                    isAudioNotifying: true,
                    codec: .value(Self.opusCodec)
                ),
                .rearmConnect
        )
    }

    func testRestoreActionConnectedWithoutAudioServiceDiscoversServices() {
        XCTAssertEqual(
                OmiSourceLogic.readinessAction(
                    peripheralState: .connected,
                    hasAudioService: false,
                    isAudioNotifying: false,
                    codec: .notRead
                ),
                .discoverServices
        )
    }

    func testRestoreActionConnectedWithAudioServiceReadsCodecWhenUnknown() {
        XCTAssertEqual(
            OmiSourceLogic.readinessAction(
                peripheralState: .connected,
                hasAudioService: true,
                isAudioNotifying: false,
                codec: .notRead
            ),
            .readCodec
        )
    }

    func testRestoreActionConnectedWithConfirmedOpusSubscribesWhenNotNotifying() {
        XCTAssertEqual(
            OmiSourceLogic.readinessAction(
                peripheralState: .connected,
                hasAudioService: true,
                isAudioNotifying: false,
                codec: .value(Self.opusCodec)
            ),
            .subscribeAudio
        )
    }

    func testRestoreActionConnectedAndConfirmedOpusNotifyingIsAlreadyLive() {
        XCTAssertEqual(
            OmiSourceLogic.readinessAction(
                peripheralState: .connected,
                hasAudioService: true,
                isAudioNotifying: true,
                codec: .value(Self.opusCodec)
            ),
            .alreadyLive
        )
    }

    func testRestoreActionConnectedWithUnsupportedCodecNeedsAttention() {
        XCTAssertEqual(
            OmiSourceLogic.readinessAction(
                peripheralState: .connected,
                hasAudioService: true,
                isAudioNotifying: false,
                codec: .value(Self.unsupportedCodec)
            ),
            .needsAttention(.codecNotOpus)
        )
        XCTAssertEqual(
            OmiSourceLogic.readinessAction(
                peripheralState: .connected,
                hasAudioService: true,
                isAudioNotifying: false,
                codec: .unavailable
            ),
            .needsAttention(.codecNotOpus)
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

private extension OmiSourceRestoreTests {
    static let opusCodec = OmiAudioCodecInfo(rawByte: 20, label: "opus")
    static let unsupportedCodec = OmiAudioCodecInfo(rawByte: 1, label: "pcm")
}
