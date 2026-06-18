// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreBluetooth
import XCTest

nonisolated final class BLEDiagnosticFormatterTests: XCTestCase {
    func testStateLinesAreDistinctAndSpecific() {
        let states: [CBManagerState] = [
            .unauthorized,
            .poweredOff,
            .unsupported,
            .resetting,
            .unknown,
            .poweredOn
        ]
        let lines = states.map(BLEDiagnosticFormatters.stateLine)

        XCTAssertEqual(Set(lines).count, states.count)
        for line in lines {
            XCTAssertFalse(line.isEmpty)
            XCTAssertNotEqual(line, "bluetooth unavailable")
            XCTAssertNotEqual(line, "unknown")
        }
    }

    func testPropertyLabelsAreOrdered() {
        XCTAssertEqual(
            BLEDiagnosticFormatters.propertyLabels([.read, .notify]),
            ["read", "notify"]
        )
        XCTAssertEqual(
            BLEDiagnosticFormatters.propertyLabels([.indicate, .write, .writeWithoutResponse]),
            ["writeWithoutResponse", "write", "indicate"]
        )
        XCTAssertEqual(
            BLEDiagnosticFormatters.propertyLabels([.notifyEncryptionRequired, .extendedProperties, .authenticatedSignedWrites]),
            ["authenticatedSignedWrites", "extendedProperties", "notifyEncryptionRequired"]
        )
    }

    func testHexAndAsciiDumps() {
        let data = Data([0x48, 0x69, 0x00, 0x21])

        XCTAssertEqual(BLEDiagnosticFormatters.hexDump(data), "48 69 00 21")
        XCTAssertEqual(BLEDiagnosticFormatters.asciiDump(data), "Hi.!")
    }

    func testCodecLabels() {
        XCTAssertEqual(BLEDiagnosticFormatters.codecLabel(0), "pcm16 16 kHz mono")
        XCTAssertEqual(BLEDiagnosticFormatters.codecLabel(1), "pcm16 8 kHz mono")
        XCTAssertEqual(BLEDiagnosticFormatters.codecLabel(10), "µ-law 16 kHz mono")
        XCTAssertEqual(BLEDiagnosticFormatters.codecLabel(11), "µ-law 8 kHz mono")
        XCTAssertEqual(BLEDiagnosticFormatters.codecLabel(20), "opus 16 kHz mono")
        XCTAssertEqual(BLEDiagnosticFormatters.codecLabel(21), "opus 16 kHz mono (fs320)")
        XCTAssertTrue(BLEDiagnosticFormatters.codecLabel(99).contains("unknown"))
    }
}
