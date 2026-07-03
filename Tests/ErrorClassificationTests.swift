// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class ErrorClassificationTests: XCTestCase {
    @MainActor
    func testUserMessages() {
        XCTAssertEqual(TunnelError.revoked.userMessage, "your journal asked this phone to reconnect.")
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
        XCTAssertEqual(manager.mapTransportError(SessionError.tokenExpired), .revoked)
        XCTAssertEqual(
            manager.mapTransportError(SessionError.revoked).userMessage,
            "your journal asked this phone to reconnect."
        )
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
}
