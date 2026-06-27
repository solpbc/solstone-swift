// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel
import XCTest

nonisolated final class SPLKeychainCodableTests: XCTestCase {
    func testEncodingWritesRelayEnrollmentAsTopLevelKey() throws {
        let data = try SPLKeychain.encode(Self.pairing(enrollment: .enrolled(deviceToken: "token-123", expiresAt: nil)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNotNil(object["relayEnrollment"])
        XCTAssertNil(object["deviceToken"])
    }

    func testRelayEnrollmentRoundTripsExpiresAt() throws {
        let expected = Self.pairing(enrollment: .enrolled(deviceToken: "token-123", expiresAt: "2036-01-01T00:00:00Z"))

        let decoded = try SPLKeychain.decode(try SPLKeychain.encode(expected))

        XCTAssertEqual(decoded, expected)
    }

    func testLegacyDeviceTokenDecodesAsEnrolled() throws {
        let pairing = try SPLKeychain.decode(Self.legacyPayload(extra: ["deviceToken": "legacy-token"]))

        XCTAssertEqual(pairing.relayEnrollment, .enrolled(deviceToken: "legacy-token", expiresAt: nil))
    }

    func testCurrentRelayEnrollmentWithoutExpiresAtDecodesAsNil() throws {
        let pairing = try SPLKeychain.decode(Self.legacyPayload(extra: [
            "relayEnrollment": [
                "enrolled": [
                    "deviceToken": "current-token"
                ]
            ]
        ]))

        XCTAssertEqual(pairing.relayEnrollment, .enrolled(deviceToken: "current-token", expiresAt: nil))
    }

    func testMissingRelayEnrollmentDecodesAsUnavailable() throws {
        let pairing = try SPLKeychain.decode(Self.legacyPayload(extra: [:]))

        XCTAssertEqual(pairing.relayEnrollment, .unavailable)
    }

    func testLocalEndpointCodableUsesIPWireKey() throws {
        let endpoint = LocalEndpoint(host: "192.168.1.10", port: 7657, scope: "lan")
        let data = try JSONEncoder().encode(endpoint)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(json.contains(#""ip""#))
        XCTAssertFalse(json.contains(#""host""#))
        XCTAssertEqual(try JSONDecoder().decode(LocalEndpoint.self, from: data), endpoint)
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

    private static func legacyPayload(extra: [String: Any]) throws -> Data {
        var payload: [String: Any] = [
            "instanceID": "instance",
            "homeLabel": "home",
            "relayEndpoint": "wss://relay.example.com",
            "fingerprint": "sha256:\(String(repeating: "a", count: 64))",
            "clientCertPEM": "cert",
            "clientKeyPEM": "key",
            "caChainPEM": "ca",
            "localEndpoints": [],
            "pairedAt": "2026-01-01T00:00:00Z",
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }
}
