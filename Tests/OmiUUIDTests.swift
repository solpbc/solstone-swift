// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OmiUUIDTests: XCTestCase {
    func testUUIDConstantsMatchDocumentedValues() {
        XCTAssertEqual(OmiUUIDs.audioService.uuidString, "19B10000-E8F2-537E-4F6C-D104768A1214")
        XCTAssertEqual(OmiUUIDs.audioDataCharacteristic.uuidString, "19B10001-E8F2-537E-4F6C-D104768A1214")
        XCTAssertEqual(OmiUUIDs.codecCharacteristic.uuidString, "19B10002-E8F2-537E-4F6C-D104768A1214")
        XCTAssertEqual(OmiUUIDs.storageService.uuidString, "30295780-4301-EABD-2904-2849ADFEAE43")
        XCTAssertEqual(OmiUUIDs.storageControlCharacteristic.uuidString, "30295782-4301-EABD-2904-2849ADFEAE43")
        XCTAssertEqual(OmiUUIDs.batteryService.uuidString, "180F")
        XCTAssertEqual(OmiUUIDs.batteryLevelCharacteristic.uuidString, "2A19")
        XCTAssertEqual(OmiUUIDs.deviceInformationService.uuidString, "180A")
        XCTAssertEqual(OmiUUIDs.firmwareRevisionCharacteristic.uuidString, "2A26")
        XCTAssertEqual(OmiUUIDs.manufacturerNameCharacteristic.uuidString, "2A29")
        XCTAssertEqual(OmiUUIDs.modelNumberCharacteristic.uuidString, "2A24")
        XCTAssertEqual(OmiUUIDs.hardwareRevisionCharacteristic.uuidString, "2A27")
    }
}
