// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class BLEDiagnosticLogTests: XCTestCase {
    @MainActor
    func testLogSnapshotIncludesHeaderAndReverseChronEntries() throws {
        let log = BLEDiagnosticLog(capacity: 10)
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)

        log.append(BLELogEntry(
            timestamp: older,
            severity: .info,
            message: "oldest event"
        ))
        log.append(BLELogEntry(
            timestamp: newer,
            severity: .error,
            message: "newest event",
            hex: "01 02"
        ))

        let snapshot = log.logSnapshot(
            connectedPeripheralName: "omi",
            connectedPeripheralID: "peripheral-id",
            firmware: "1.2.3"
        )

        XCTAssertTrue(snapshot.contains("solstone-swift ble diagnostic snapshot"))
        XCTAssertTrue(snapshot.contains("app:"))
        XCTAssertTrue(snapshot.contains("/ iOS"))
        XCTAssertTrue(snapshot.contains("connected peripheral: omi (peripheral-id)"))
        XCTAssertTrue(snapshot.contains("firmware: 1.2.3"))
        XCTAssertTrue(snapshot.contains("---"))
        XCTAssertTrue(snapshot.contains("[error] newest event hex=01 02"))
        XCTAssertTrue(snapshot.contains("[info] oldest event"))

        let newestRange = try XCTUnwrap(snapshot.range(of: "newest event"))
        let oldestRange = try XCTUnwrap(snapshot.range(of: "oldest event"))
        XCTAssertLessThan(newestRange.lowerBound, oldestRange.lowerBound)
    }

    @MainActor
    func testRingBufferKeepsMostRecentFiveHundredEntries() {
        let log = BLEDiagnosticLog(capacity: 500)

        for index in 0..<510 {
            log.append(message: "event \(index)")
        }

        XCTAssertEqual(log.entries.count, 500)
        XCTAssertEqual(log.entries.first?.message, "event 10")
        XCTAssertEqual(log.entries.last?.message, "event 509")
    }
}
