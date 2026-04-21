// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

@MainActor
final class MockPairingClientTests: XCTestCase {
    func testMockPairingClientRoundTrip() async throws {
        let client = MockPairingClient()

        let confirm = try await client.confirm(
            token: "ptk_123",
            publicKey: "pub-key",
            deviceName: "Jer's iPhone",
            platform: "ios",
            bundleID: "app.solstone.swift",
            appVersion: "0.1.0"
        )

        XCTAssertEqual(confirm, client.confirmResponse)
        XCTAssertEqual(client.lastConfirmToken, "ptk_123")
        XCTAssertEqual(client.lastConfirmPublicKey, "pub-key")
        XCTAssertEqual(client.lastDeviceName, "Jer's iPhone")

        try await client.setBriefingTime(hour: 7, minute: 0, tzIdentifier: "America/Denver", sessionKey: "pair-session")
        XCTAssertEqual(client.lastBriefingHour, 7)
        XCTAssertEqual(client.lastBriefingMinute, 0)
        XCTAssertEqual(client.lastBriefingTZIdentifier, "America/Denver")

        let progress = try await client.progressToday(sessionKey: "pair-session")
        XCTAssertEqual(progress, client.progressResponse)
        XCTAssertEqual(client.lastProgressSessionKey, "pair-session")

        try await client.unpair(deviceID: "device-123", sessionKey: "pair-session")
        XCTAssertEqual(client.lastUnpairDeviceID, "device-123")
        XCTAssertEqual(client.lastUnpairSessionKey, "pair-session")
    }
}
