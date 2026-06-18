// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreBluetooth
import XCTest

nonisolated final class BLEDiagnosticUUIDTests: XCTestCase {
    func testUUIDConstantsMatchDocumentedValues() {
        XCTAssertEqual(BLEDiagnosticUUIDs.audioService.uuidString, "19B10000-E8F2-537E-4F6C-D104768A1214")
        XCTAssertEqual(BLEDiagnosticUUIDs.audioDataCharacteristic.uuidString, "19B10001-E8F2-537E-4F6C-D104768A1214")
        XCTAssertEqual(BLEDiagnosticUUIDs.codecCharacteristic.uuidString, "19B10002-E8F2-537E-4F6C-D104768A1214")
        XCTAssertEqual(BLEDiagnosticUUIDs.speakerCharacteristic.uuidString, "19B10003-E8F2-537E-4F6C-D104768A1214")
        XCTAssertEqual(BLEDiagnosticUUIDs.storageService.uuidString, "30295780-4301-EABD-2904-2849ADFEAE43")
        XCTAssertEqual(BLEDiagnosticUUIDs.storageDataCharacteristic.uuidString, "30295781-4301-EABD-2904-2849ADFEAE43")
        XCTAssertEqual(BLEDiagnosticUUIDs.storageControlCharacteristic.uuidString, "30295782-4301-EABD-2904-2849ADFEAE43")
        XCTAssertEqual(BLEDiagnosticUUIDs.batteryService.uuidString, "180F")
        XCTAssertEqual(BLEDiagnosticUUIDs.batteryLevelCharacteristic.uuidString, "2A19")
        XCTAssertEqual(BLEDiagnosticUUIDs.deviceInformationService.uuidString, "180A")
        XCTAssertEqual(BLEDiagnosticUUIDs.firmwareRevisionCharacteristic.uuidString, "2A26")
        XCTAssertEqual(BLEDiagnosticUUIDs.manufacturerNameCharacteristic.uuidString, "2A29")
        XCTAssertEqual(BLEDiagnosticUUIDs.modelNumberCharacteristic.uuidString, "2A24")
        XCTAssertEqual(BLEDiagnosticUUIDs.hardwareRevisionCharacteristic.uuidString, "2A27")
    }

    func testScanServiceUUIDsContainsAudioService() {
        XCTAssertEqual(BLEDiagnosticUUIDs.scanServiceUUIDs.map(\.uuidString), [
            BLEDiagnosticUUIDs.audioService.uuidString
        ])
    }

    func testStorageDisplayNames() {
        XCTAssertEqual(BLEDiagnosticUUIDs.displayName(for: BLEDiagnosticUUIDs.storageDataCharacteristic), "sd-card data")
        XCTAssertEqual(BLEDiagnosticUUIDs.displayName(for: BLEDiagnosticUUIDs.storageControlCharacteristic), "sd-card control")
    }
}
