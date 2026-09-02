// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiSourceManagerDiagnosticTests: XCTestCase {
    func testPendantNotFoundNeedsAttentionEmitsUploadDiagnostic() async throws {
        let defaultsName = "OmiSourceManagerDiagnosticTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let log = DiagnosticLog()
        let manager = OmiSourceManager(
            defaults: defaults,
            clock: MockObserverClock(),
            bluetoothPort: MockOmiBluetoothPort(),
            diagnosticLog: log
        )

        manager.handleCentralStateUpdate(.poweredOn)
        await manager.openLaunchReadiness()
        manager.enable()

        XCTAssertEqual(manager.connectionState, .needsAttention(.pendantNotFound))
        XCTAssertEqual(log.events.count, 1)
        let event = try XCTUnwrap(log.events.first)
        XCTAssertEqual(event.category, .upload)
        XCTAssertEqual(event.severity, .warning)
        XCTAssertEqual(event.message, "needs attention")
        XCTAssertEqual(event.detail, "source=omi reason=pendantNotFound")
    }

    func testSystemReconnectingEmitsInfoUploadDiagnostic() async throws {
        let defaultsName = "OmiSourceManagerDiagnosticTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let log = DiagnosticLog()
        let manager = OmiSourceManager(
            defaults: defaults,
            clock: MockObserverClock(),
            bluetoothPort: MockOmiBluetoothPort(),
            diagnosticLog: log
        )
        let peripheral = OmiPeripheralDescriptor(
            id: UUID(),
            name: "omi",
            state: .disconnected,
            services: []
        )

        manager.enable()
        await manager.handleDisconnected(
            peripheral,
            timestamp: 0,
            isReconnecting: true,
            error: nil
        )

        XCTAssertEqual(manager.connectionState, .reconnecting)
        XCTAssertEqual(log.events.count, 1)
        let event = try XCTUnwrap(log.events.first)
        XCTAssertEqual(event.category, .upload)
        XCTAssertEqual(event.severity, .info)
        XCTAssertEqual(event.message, "waiting")
        XCTAssertEqual(event.detail, "source=omi reason=systemReconnecting")
    }
}
