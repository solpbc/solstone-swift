// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreBluetooth
import XCTest

nonisolated final class BLEDiagnosticStorageTests: XCTestCase {
    func testReadCommandBytesUseLittleEndianOffset() {
        XCTAssertEqual(
            BLEDiagnosticStorage.readCommandBytes(fileNumber: 0x01, offset: 790_240),
            [0x00, 0x01, 0xE0, 0x0E, 0x0C, 0x00]
        )
    }

    func testWriteTypeSelectionPrefersWithResponseThenWithoutResponse() {
        XCTAssertEqual(BLEDiagnosticStorage.writeType(for: [.write]), .withResponse)
        XCTAssertEqual(BLEDiagnosticStorage.writeType(for: [.writeWithoutResponse]), .withoutResponse)
        XCTAssertEqual(BLEDiagnosticStorage.writeType(for: [.write, .writeWithoutResponse]), .withResponse)
        XCTAssertNil(BLEDiagnosticStorage.writeType(for: CBCharacteristicProperties(rawValue: 0)))
    }

    func testReadTimeoutTransitionOnlyFailsReadingWithZeroBytes() {
        XCTAssertEqual(
            BLEDiagnosticStorage.readTimeoutTransition(currentState: .reading, bytesReceived: 0),
            .failed("no storage data received within 5s — read command likely wrong for this firmware")
        )
        XCTAssertNil(BLEDiagnosticStorage.readTimeoutTransition(currentState: .reading, bytesReceived: 1))
        XCTAssertNil(BLEDiagnosticStorage.readTimeoutTransition(currentState: .ready, bytesReceived: 0))
    }
}
