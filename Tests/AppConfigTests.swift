// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

private final class PairingState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPairing: StoredPairing?
    private var didDelete = false

    func load() -> StoredPairing? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storedPairing
    }

    func save(_ pairing: StoredPairing) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storedPairing = pairing
    }

    func delete() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storedPairing = nil
        self.didDelete = true
    }

    func deleted() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.didDelete
    }
}

nonisolated final class AppConfigTests: XCTestCase {
    private var pairingState: PairingState!
    private var appGroupRoot: URL!

    override func setUp() {
        super.setUp()
        self.pairingState = PairingState()
        self.appGroupRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppConfigTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.appGroupRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: self.appGroupRoot)
        self.appGroupRoot = nil
        self.pairingState = nil
        super.tearDown()
    }

    @MainActor
    func testApplyPairingPersistsState() throws {
        let config = self.makeConfig()
        let pairing = Self.fixturePairing()

        try config.applyPairing(pairing)

        XCTAssertTrue(config.isPaired)
        XCTAssertEqual(config.homeLabel, "sol")
        XCTAssertEqual(config.caFingerprintHex, String(repeating: "a", count: 64))
        XCTAssertEqual(config.deviceID, "instance-123")
        XCTAssertEqual(self.pairingState.load(), pairing)
        XCTAssertEqual(
            self.mirror().snapshot()?.pairing,
            AppGroupMirror.PairingSnapshot(journalName: "sol", isPaired: true)
        )
    }

    @MainActor
    func testClearPairingWipesState() throws {
        let config = self.makeConfig()
        try config.applyPairing(Self.fixturePairing())

        config.clearPairing()

        XCTAssertFalse(config.isPaired)
        XCTAssertEqual(config.host, "")
        XCTAssertEqual(config.port, 22)
        XCTAssertTrue(self.pairingState.deleted())
        XCTAssertEqual(
            self.mirror().snapshot()?.pairing,
            AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false)
        )
    }

    @MainActor
    func testSeedUITestPairingProvidesStoredPairing() {
        let config = self.makeConfig()

        config.seedUITestPairing(journalRoot: "http://127.0.0.1:8676")

        XCTAssertTrue(config.isPaired)
        XCTAssertEqual(config.loopbackPort, 8676)
        XCTAssertEqual(self.pairingState.load()?.homeLabel, "ui-test-solstone")
        XCTAssertEqual(self.pairingState.load()?.relayEndpoint, "wss://127.0.0.1:8676")
        XCTAssertNil(config.currentSessionKey())
        XCTAssertEqual(
            self.mirror().snapshot()?.pairing,
            AppGroupMirror.PairingSnapshot(journalName: "ui-test-solstone", isPaired: true)
        )
    }

    @MainActor
    func testInitWithNoPairingClearsStaleMirror() {
        let mirror = self.mirror()
        if case .failure(let error) = mirror.writePairing(journalName: "stale") {
            XCTFail("unexpected mirror write failure: \(error)")
        }

        _ = self.makeConfig()

        XCTAssertEqual(mirror.snapshot()?.pairing, AppGroupMirror.PairingSnapshot(journalName: nil, isPaired: false))
    }

    @MainActor private func makeConfig() -> AppConfig {
        let pairingState = self.pairingState!
        return AppConfig(
            loadPairing: { pairingState.load() },
            savePairing: { pairingState.save($0) },
            deletePairing: { pairingState.delete() },
            appGroupMirror: self.mirror()
        )
    }

    @MainActor private func mirror() -> AppGroupMirror {
        let rootURL = self.appGroupRoot!
        return AppGroupMirror(rootURLProvider: { rootURL })
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
