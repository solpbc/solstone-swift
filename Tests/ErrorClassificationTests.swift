// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class ErrorClassificationTests: XCTestCase {
    @MainActor
    func testUserMessages() {
        XCTAssertEqual(TunnelError.revoked.userMessage, "your journal asked this device to reconnect.")
        XCTAssertEqual(TunnelError.tlsHandshakeFailed.userMessage, "couldn't verify this journal.")
        XCTAssertEqual(TunnelError.muxTeardown.userMessage, "connection lost.")
        XCTAssertEqual(TunnelError.unreachable.userMessage, "can't reach this journal right now.")
    }

    @MainActor
    func testRetryability() {
        XCTAssertFalse(TunnelError.revoked.isRetryable)
        XCTAssertTrue(TunnelError.tlsHandshakeFailed.isRetryable)
        XCTAssertTrue(TunnelError.muxTeardown.isRetryable)
        XCTAssertTrue(TunnelError.unreachable.isRetryable)
    }

    @MainActor
    func testIconsExist() {
        XCTAssertFalse(TunnelError.revoked.iconName.isEmpty)
        XCTAssertFalse(TunnelError.tlsHandshakeFailed.iconName.isEmpty)
        XCTAssertFalse(TunnelError.muxTeardown.iconName.isEmpty)
        XCTAssertFalse(TunnelError.unreachable.iconName.isEmpty)
    }

    @MainActor
    func testSessionRevokedMapsToTunnelRevoked() {
        let manager = TunnelManager(transport: MockCFTunnelTransport())

        XCTAssertEqual(manager.mapTransportError(SessionError.revoked), .revoked)
        XCTAssertEqual(
            manager.mapTransportError(SessionError.revoked).userMessage,
            "your journal asked this device to reconnect."
        )
    }

    @MainActor
    func testSessionAuthRefreshRequiredMapsToUnreachable() {
        let manager = TunnelManager(transport: MockCFTunnelTransport())

        XCTAssertEqual(manager.mapTransportError(SessionError.authRefreshRequired), .unreachable)
    }

    @MainActor
    func testSessionUnreachableKeepsUnreachable() {
        let manager = TunnelManager(transport: MockCFTunnelTransport())

        XCTAssertEqual(manager.mapTransportError(SessionError.unreachable), .unreachable)
        XCTAssertEqual(
            manager.mapTransportError(SessionError.unreachable).userMessage,
            "can't reach this journal right now."
        )
    }

    // Falsified by mapping a stopped credential to a retrying state (it would dial again) or
    // to the plain revoked case (the connect path would delete the pairing).
    @MainActor
    func testRefusalsExhaustedPresentsAsRevokedButIsItsOwnCase() {
        let manager = TunnelManager(transport: MockCFTunnelTransport())
        let mapped = manager.mapTransportError(SessionError.refusalsExhausted)

        XCTAssertEqual(mapped, .refusalsExhausted)
        XCTAssertNotEqual(mapped, .revoked)
        XCTAssertFalse(mapped.isRetryable)
        XCTAssertEqual(mapped.userMessage, TunnelError.revoked.userMessage)
        XCTAssertEqual(mapped.iconName, TunnelError.revoked.iconName)
        XCTAssertTrue(TunnelState.error(mapped).asksToPairAgain)
    }

    // Falsified by showing the revoked copy, or stopping retries, for a refusal the journal
    // means to be temporary, or for a peer that is not the paired journal.
    @MainActor
    func testRetryingRefusalsKeepTheExistingRetryingStates() {
        let manager = TunnelManager(transport: MockCFTunnelTransport())
        let expected: [(SessionError, TunnelError)] = [
            (.refused, .unreachable),
            (.certificateUnknown, .unreachable),
            (.unknownJournal, .tlsHandshakeFailed),
        ]
        for (sessionError, tunnelError) in expected {
            let mapped = manager.mapTransportError(sessionError)
            XCTAssertEqual(mapped, tunnelError, "\(sessionError)")
            XCTAssertTrue(mapped.isRetryable, "\(sessionError)")
            XCTAssertNotEqual(mapped.userMessage, TunnelError.revoked.userMessage, "\(sessionError)")
            XCTAssertFalse(TunnelState.error(mapped).asksToPairAgain, "\(sessionError)")
        }
    }

    @MainActor
    func testOnlyAStoppedCredentialAsksToPairAgain() {
        XCTAssertTrue(TunnelState.error(.revoked).asksToPairAgain)
        XCTAssertTrue(TunnelState.error(.refusalsExhausted).asksToPairAgain)
        for state: TunnelState in [
            .disconnected,
            .connecting,
            .waitingForHome,
            .connected(localPort: 1, via: .lan),
            .error(.unreachable),
            .error(.tlsHandshakeFailed),
            .error(.muxTeardown),
            .error(.unknown("x")),
        ] {
            XCTAssertFalse(state.asksToPairAgain, "\(state)")
        }
    }
}
