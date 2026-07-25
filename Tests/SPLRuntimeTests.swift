// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import SPLTunnel
import XCTest

nonisolated final class SPLRuntimeTests: XCTestCase {
    func testKeychainPolicyMatchesVendoredStorageContract() {
        let policy = SPLRuntime.keychainPolicy

        XCTAssertEqual(policy.service, "app.solstone.observer.spl")
        XCTAssertEqual(policy.account, "spl-pairing-bundle")
        XCTAssertNil(policy.accessGroup)
        XCTAssertFalse(policy.useDataProtectionKeychain)
        XCTAssertEqual(policy.accessibility, .afterFirstUnlock)
    }

    func testKeychainStoreRoundTripsStoredPairingWithTestService() throws {
        let store = SPLKeychainStore(
            policy: KeychainPolicy(
                service: "app.solstone.swift.tests.spl.\(UUID().uuidString)",
                account: "spl-pairing-bundle-tests",
                accessGroup: nil,
                useDataProtectionKeychain: false,
                accessibility: .afterFirstUnlock
            )
        )
        defer { try? store.delete() }

        let pairing = StoredPairing(
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

        try store.delete()
        try store.save(pairing)
        XCTAssertEqual(try store.load(), pairing)

        try store.delete()
        XCTAssertNil(try store.load())
    }
}
