// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

private final class PairFlowMismatchPairingStore: @unchecked Sendable {
    private let lock = NSLock()
    private var pairing: StoredPairing?

    func load() -> StoredPairing? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pairing
    }

    func save(_ pairing: StoredPairing) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pairing = pairing
    }

    func delete() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pairing = nil
    }
}

nonisolated final class PairFlowMismatchTests: XCTestCase {
    @MainActor
    func testMismatchTeardownClearsAppPairingAndDisconnectsTunnel() async throws {
        try? SPLRuntime.keychainStore.delete()
        defer { try? SPLRuntime.keychainStore.delete() }

        let store = PairFlowMismatchPairingStore()
        let pairing = Self.fixturePairing()
        let appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairFlowMismatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: appGroupRoot) }

        let appConfig = AppConfig(
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() },
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            appGroupMirror: AppGroupMirror(rootURLProvider: { appGroupRoot })
        )
        try appConfig.applyPairing(pairing)

        let tunnel = TunnelManager(
            transport: MockCFTunnelTransport(),
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            loadPairing: { store.load() },
            savePairing: { store.save($0) },
            deletePairing: { store.delete() }
        )
        tunnel.forceConnected(port: 7071, via: .lan)

        let coordinator = PairFlowCoordinator(
            endpointCache: EndpointCache(fileURL: Self.tempFileURL()),
            pairOperation: { _, _, _, _ in pairing }
        )

        await tearDownMismatchedPairing(
            appConfig: appConfig,
            tunnelManager: tunnel,
            coordinator: coordinator
        )

        XCTAssertFalse(appConfig.isPaired)
        XCTAssertNil(store.load())
        XCTAssertEqual(tunnel.state, .disconnected)
        XCTAssertEqual(coordinator.state, .idle)
    }

    private static func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("endpoints.json")
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
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 7071, scope: "")],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }
}
