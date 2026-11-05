// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
@testable import SPLTunnel
import XCTest

/// The in-app journal's origin is `http://127.0.0.1:<proxy port>`; these pin
/// that a pairing keeps its port across reconnects and relaunches, and that a
/// different journal or an unpair starts fresh.
nonisolated final class JournalWebOriginTests: XCTestCase {
    private static func isolatedOrigins() -> JournalWebOriginStore {
        let suite = "journal-web-origin-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return JournalWebOriginStore(defaults: defaults)
    }

    @MainActor
    private static func makeTransport(
        origins: JournalWebOriginStore,
        pairing: StoredPairing = fixturePairing(),
        diagnosticLog: DiagnosticLog? = nil
    ) -> CFTunnelTransport {
        CFTunnelTransport(
            diagnosticLog: diagnosticLog,
            loadPairing: { pairing },
            makeSession: { _ in FakeTunnelSession() },
            origins: origins
        )
    }

    @MainActor
    private static func connect(_ transport: CFTunnelTransport) async throws -> Int {
        try await transport.connect(
            candidates: [.lan(host: "127.0.0.1", port: 8676, scope: "")],
            onDisconnect: { _ in },
            onStageChange: { _ in }
        )
    }

    @MainActor
    func testEveryReconnectComesBackOnTheSamePort() async throws {
        // Every reconnect trigger in TunnelManager runs the transport's
        // disconnect() and then connect(), which builds a new proxy.
        let origins = Self.isolatedOrigins()
        let transport = Self.makeTransport(origins: origins)
        let first = try await Self.connect(transport)
        for _ in 0..<5 {
            await transport.disconnect()
            let again = try await Self.connect(transport)
            XCTAssertEqual(again, first)
        }
        XCTAssertEqual(origins.preferredPort(for: "instance-123"), UInt16(first))
        await transport.disconnect()
    }

    @MainActor
    func testARelaunchComesBackOnTheRememberedPort() async throws {
        let origins = Self.isolatedOrigins()
        let before = Self.makeTransport(origins: origins)
        let port = try await Self.connect(before)
        await before.disconnect()

        let afterRelaunch = Self.makeTransport(origins: origins)
        let relaunched = try await Self.connect(afterRelaunch)
        XCTAssertEqual(relaunched, port)
        await afterRelaunch.disconnect()
    }

    @MainActor
    func testAPortTakenMeanwhileFallsBackAndIsNoted() async throws {
        let origins = Self.isolatedOrigins()
        let diagnostics = DiagnosticLog()
        let transport = Self.makeTransport(origins: origins, diagnosticLog: diagnostics)
        let port = try await Self.connect(transport)
        await transport.disconnect()

        // Something else binds the port while the app is away from it.
        let holder = LoopbackProxy(opener: FakeTunnelSession())
        let held = try await holder.start(preferredPort: UInt16(port))
        XCTAssertEqual(held.port, UInt16(port))

        let moved = try await Self.connect(transport)
        XCTAssertNotEqual(moved, port)
        XCTAssertEqual(origins.preferredPort(for: "instance-123"), UInt16(moved))
        XCTAssertTrue(diagnostics.events.contains { $0.message == "journal page started fresh" && $0.detail == "reason=port-in-use" })
        await transport.disconnect()
        await holder.stop()
    }

    func testADifferentJournalStartsAFreshOriginAndQueuesTheOldStore() {
        let origins = Self.isolatedOrigins()
        let first = origins.dataStoreID(for: "journal-a")
        XCTAssertNil(first.replaced)
        origins.recordPort(40_123, for: "journal-a")
        XCTAssertEqual(origins.dataStoreID(for: "journal-a").id, first.id)

        XCTAssertNil(origins.preferredPort(for: "journal-b"))
        let second = origins.dataStoreID(for: "journal-b")
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertEqual(second.replaced, first.id)
        XCTAssertEqual(origins.pendingRemovals(), [first.id])
        XCTAssertNil(origins.preferredPort(for: "journal-a"))
    }

    func testForgettingThePairingClearsThePortAndQueuesTheStore() {
        let origins = Self.isolatedOrigins()
        let id = origins.dataStoreID(for: "journal-a").id
        origins.recordPort(40_123, for: "journal-a")

        origins.forget()

        XCTAssertNil(origins.preferredPort(for: "journal-a"))
        XCTAssertEqual(origins.pendingRemovals(), [id])
        XCTAssertNotEqual(origins.dataStoreID(for: "journal-a").id, id)
        origins.markRemoved(id)
        XCTAssertEqual(origins.pendingRemovals(), [])
    }

    private static func fixturePairing() -> StoredPairing {
        StoredPairing(
            instanceID: "instance-123",
            homeLabel: "sol",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: "ca",
            relayEnrollment: .enrolled(deviceToken: "device-token", expiresAt: nil),
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 8676, scope: "")],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }
}
