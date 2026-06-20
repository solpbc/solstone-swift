// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OmiSourceStateMappingTests: XCTestCase {
    func testDisabledAlwaysMapsOff() {
        let states: [OmiSourceState] = [
            .disconnected,
            .connecting,
            .connected,
            .reconnecting,
            .needsAttention(.bluetoothOff)
        ]

        for state in states {
            let mapped = omiSourceState(for: state, enabled: false)

            XCTAssertEqual(mapped.0, .off)
            XCTAssertNil(mapped.1)
        }
    }

    func testEnabledConnectionStatesMapToSourceStates() {
        XCTAssertEqual(omiSourceState(for: .disconnected, enabled: true).0, .enrolling)
        XCTAssertEqual(omiSourceState(for: .connecting, enabled: true).0, .enrolling)
        XCTAssertEqual(omiSourceState(for: .reconnecting, enabled: true).0, .enrolling)
        XCTAssertEqual(omiSourceState(for: .connected, enabled: true).0, .active)
    }

    func testEnabledNeedsAttentionMapsReasonMessage() {
        let bluetoothOff = omiSourceState(for: .needsAttention(.bluetoothOff), enabled: true)
        let connectFailed = omiSourceState(for: .needsAttention(.connectFailed("connection timed out")), enabled: true)

        XCTAssertEqual(bluetoothOff.0, .needsAttention)
        XCTAssertEqual(bluetoothOff.1, SourceAttention(message: "bluetooth off"))
        XCTAssertEqual(connectFailed.0, .needsAttention)
        XCTAssertEqual(connectFailed.1, SourceAttention(message: "connection failed: connection timed out"))
    }

    func testOmiAttentionDisplayStringsAreOwnerSafe() {
        let cases: [(OmiAttention, String)] = [
            (.bluetoothOff, "bluetooth off"),
            (.unauthorized, "bluetooth permission needed"),
            (.unsupported, "bluetooth unsupported"),
            (.pendantNotFound, "omi pendant not found"),
            (.connectFailed("connection timed out"), "connection failed: connection timed out"),
            (.codecNotOpus, "audio codec unsupported"),
            (.audioUnavailable, "audio unavailable")
        ]

        for (attention, displayString) in cases {
            XCTAssertEqual(attention.displayString, displayString)
        }
    }
}
