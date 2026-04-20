// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

private final class PairingState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSessionKey: String?
    private var pairIdentityDeleted = false

    func sessionKey() -> String? {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storedSessionKey
    }

    func save(sessionKey: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storedSessionKey = sessionKey
    }

    func clearSessionKey() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storedSessionKey = nil
    }

    func markPairIdentityDeleted() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.pairIdentityDeleted = true
    }

    func didDeletePairIdentity() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.pairIdentityDeleted
    }
}

@MainActor
final class AppConfigTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var pairingState: PairingState!

    override func setUp() {
        super.setUp()
        self.suiteName = "AppConfigTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.pairingState = PairingState()
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        self.pairingState = nil
        super.tearDown()
    }

    func testApplyPairConfirmPersistsState() throws {
        let config = self.makeConfig()

        try config.applyPairConfirm(
            PairConfirmResponse(
                sessionKey: "session-123",
                deviceID: "device-123",
                journalRoot: "https://journal.example.com",
                ownerIdentity: "sol",
                serverVersion: "2026.04.20",
                host: "journal.example.com",
                port: 22
            )
        )

        XCTAssertTrue(config.isPaired)
        XCTAssertEqual(config.host, "journal.example.com")
        XCTAssertEqual(config.port, 22)
        XCTAssertEqual(config.journalRoot, "https://journal.example.com")
        XCTAssertEqual(config.ownerIdentity, "sol")
        XCTAssertEqual(config.deviceID, "device-123")
        XCTAssertEqual(config.serverVersion, "2026.04.20")
        XCTAssertEqual(self.pairingState.sessionKey(), "session-123")
    }

    func testClearPairingWipesState() throws {
        let config = self.makeConfig()
        try config.applyPairConfirm(
            PairConfirmResponse(
                sessionKey: "session-123",
                deviceID: "device-123",
                journalRoot: "https://journal.example.com",
                ownerIdentity: "sol",
                serverVersion: "2026.04.20",
                host: "journal.example.com",
                port: 22
            )
        )

        config.clearPairing()

        XCTAssertFalse(config.isPaired)
        XCTAssertEqual(config.host, "")
        XCTAssertEqual(config.port, 22)
        XCTAssertNil(self.pairingState.sessionKey())
        XCTAssertTrue(self.pairingState.didDeletePairIdentity())
    }

    func testSeedUITestPairingProvidesCurrentSessionKey() {
        let config = self.makeConfig()

        config.seedUITestPairing(
            journalRoot: "http://127.0.0.1:8676",
            deviceID: "device-123",
            sessionKey: "pair-session-test"
        )

        XCTAssertEqual(config.currentSessionKey(), "pair-session-test")
        XCTAssertEqual(self.pairingState.sessionKey(), "pair-session-test")
    }

    private func makeConfig() -> AppConfig {
        let pairingState = self.pairingState!
        return AppConfig(
            defaults: self.defaults,
            loadPairSession: { pairingState.sessionKey() },
            savePairSession: { pairingState.save(sessionKey: $0) },
            deletePairSession: { pairingState.clearSessionKey() },
            deletePairIdentity: { pairingState.markPairIdentityDeleted() }
        )
    }
}
