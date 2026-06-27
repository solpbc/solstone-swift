// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import SPLTunnel
import Foundation
import Security
import XCTest

nonisolated final class SPLKeychainStorageTests: XCTestCase {
    func testBaseQueryOmitsAccessibleAttribute() {
        let query = SPLKeychain.baseQuery(service: SPLKeychain.prodService)

        XCTAssertNil(query[kSecAttrAccessible as String])
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, SPLKeychain.prodService)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, SPLKeychain.account)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testAddAttributesUseAfterFirstUnlockNotThisDeviceOnly() {
        let data = Data("x".utf8)
        let attributes = SPLKeychain.addAttributes(data: data, service: SPLKeychain.prodService)

        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlock as String
        )
        XCTAssertNotEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(attributes[kSecValueData as String] as? Data, data)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, SPLKeychain.account)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, SPLKeychain.prodService)
    }

    func testSaveLoadDeleteRoundTrip() throws {
        let testService = "app.solstone.observer.spl.test.\(UUID().uuidString)"
        defer { try? SPLKeychain._delete(service: testService) }

        let pairing = Self.pairing(enrollment: .enrolled(deviceToken: "token-123", expiresAt: nil))
        try SPLKeychain._save(pairing, service: testService)
        XCTAssertEqual(try SPLKeychain._load(service: testService), pairing)

        // Simulator read-back ignores kSecAttrAccessible, so this verifies value round-trip
        // and idempotence, not accessibility enforcement.
        try SPLKeychain._delete(service: testService)
        XCTAssertNil(try SPLKeychain._load(service: testService))
    }

    private static func pairing(enrollment: RelayEnrollment) -> StoredPairing {
        StoredPairing(
            instanceID: "instance",
            homeLabel: "home",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: "ca",
            relayEnrollment: enrollment,
            localEndpoints: [LocalEndpoint(host: "10.0.0.2", port: 9443, scope: "wifi")],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }
}
