// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import CoreBluetooth
import XCTest

nonisolated final class BLEDiagnosticDiscoveryMergeTests: XCTestCase {
    func testOverlapCollapsesToConnectedSystemAndKeepsAdvertisedFields() throws {
        let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let advertised = Self.peripheral(
            id: id,
            name: "omi advertised",
            rssi: -51,
            advertisedServiceUUIDs: [BLEDiagnosticUUIDs.audioService],
            source: .advertised
        )
        let connected = Self.peripheral(
            id: id,
            name: "omi connected",
            rssi: 0,
            advertisedServiceUUIDs: [],
            source: .connectedSystem
        )

        let result = BLEDiagnosticDiscovery.mergedDisplayList(
            advertised: [advertised],
            connectedSystem: [connected],
            scanAllDevices: false
        )

        let merged = try XCTUnwrap(result.only)
        XCTAssertEqual(merged.id, id)
        XCTAssertEqual(merged.source, .connectedSystem)
        XCTAssertEqual(merged.name, "omi advertised")
        XCTAssertEqual(merged.rssi, -51)
        XCTAssertEqual(merged.advertisedServiceUUIDs, [BLEDiagnosticUUIDs.audioService])
    }

    func testAudioFilterExcludesNonAudioAdvertisedButKeepsConnectedSystem() throws {
        let audioAdvertised = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000101")),
            name: "audio advertised",
            advertisedServiceUUIDs: [BLEDiagnosticUUIDs.audioService],
            source: .advertised
        )
        let nonAudioAdvertised = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000102")),
            name: "battery advertised",
            advertisedServiceUUIDs: [BLEDiagnosticUUIDs.batteryService],
            source: .advertised
        )
        let connected = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000103")),
            name: "connected",
            advertisedServiceUUIDs: [],
            source: .connectedSystem
        )

        let result = BLEDiagnosticDiscovery.mergedDisplayList(
            advertised: [audioAdvertised, nonAudioAdvertised],
            connectedSystem: [connected],
            scanAllDevices: false
        )

        XCTAssertEqual(result.map(\.id), [connected.id, audioAdvertised.id])
    }

    func testAllDevicesFilterIncludesAllAdvertisedRows() throws {
        let audioAdvertised = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000201")),
            name: "audio advertised",
            advertisedServiceUUIDs: [BLEDiagnosticUUIDs.audioService],
            source: .advertised
        )
        let nonAudioAdvertised = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000202")),
            name: "battery advertised",
            advertisedServiceUUIDs: [BLEDiagnosticUUIDs.batteryService],
            source: .advertised
        )

        let result = BLEDiagnosticDiscovery.mergedDisplayList(
            advertised: [audioAdvertised, nonAudioAdvertised],
            connectedSystem: [],
            scanAllDevices: true
        )

        XCTAssertEqual(result.map(\.id), [audioAdvertised.id, nonAudioAdvertised.id])
    }

    func testOrderingIsConnectedSystemFirstThenAdvertisedByDisplayKey() throws {
        let advertisedB = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000301")),
            name: "zeta advertised",
            advertisedServiceUUIDs: [BLEDiagnosticUUIDs.audioService],
            source: .advertised
        )
        let advertisedA = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000302")),
            name: "alpha advertised",
            advertisedServiceUUIDs: [BLEDiagnosticUUIDs.audioService],
            source: .advertised
        )
        let connectedB = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000303")),
            name: "zeta connected",
            source: .connectedSystem
        )
        let connectedA = Self.peripheral(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000304")),
            name: "alpha connected",
            source: .connectedSystem
        )

        let result = BLEDiagnosticDiscovery.mergedDisplayList(
            advertised: [advertisedB, advertisedA],
            connectedSystem: [connectedB, connectedA],
            scanAllDevices: false
        )

        XCTAssertEqual(result.map(\.id), [
            connectedA.id,
            connectedB.id,
            advertisedA.id,
            advertisedB.id
        ])
    }

    private static func peripheral(
        id: UUID,
        name: String?,
        rssi: Int = 0,
        advertisedServiceUUIDs: [CBUUID] = [],
        source: BLEPeripheralSource
    ) -> BLEDiscoveredPeripheral {
        BLEDiscoveredPeripheral(
            id: id,
            name: name,
            rssi: rssi,
            advertisedServiceUUIDs: advertisedServiceUUIDs,
            source: source
        )
    }
}

private extension Array {
    var only: Element? {
        self.count == 1 ? self[0] : nil
    }
}
