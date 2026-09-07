// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest
@testable import solstone_swift

final class RelayAccessClaimsTests: XCTestCase {
    private func makeJWT(claims: [String: Any]) -> String {
        let header = ["alg": "none", "typ": "JWT"]
        let headerData = try! JSONSerialization.data(withJSONObject: header)
        let payloadData = try! JSONSerialization.data(withJSONObject: claims)

        let headerB64 = headerData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        let payloadB64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))

        return "\(headerB64).\(payloadB64).sig"
    }

    func testOriginValidation() {
        XCTAssertTrue(RelayAccessClaims.isValidOrigin("https://relay.example.com"))
        XCTAssertTrue(RelayAccessClaims.isValidOrigin("wss://relay.example.com"))
        XCTAssertTrue(RelayAccessClaims.isValidOrigin("https://relay.internal:8443"))
        XCTAssertFalse(RelayAccessClaims.isValidOrigin("http://relay.example.com"))
        XCTAssertFalse(RelayAccessClaims.isValidOrigin("ws://evil.example"))
        XCTAssertFalse(RelayAccessClaims.isValidOrigin("ftp://relay.example.com"))
        XCTAssertFalse(RelayAccessClaims.isValidOrigin("https://"))
        XCTAssertFalse(RelayAccessClaims.isValidOrigin("wss://"))
        XCTAssertFalse(RelayAccessClaims.isValidOrigin("invalid"))
    }

    func testValidReadyPayload() {
        let instance = "test-instance-123"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let iat = 1_700_000_000
        let exp = 1_700_003_600

        let claims: [String: Any] = [
            "iss": "solstone-journal",
            "sub": "instance:\(instance)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instance,
            "iat": iat,
            "exp": exp,
            "jti": "jwt-id-xyz"
        ]
        let token = makeJWT(claims: claims)

        let payload = RelayAccessReadyPayload(
            protocolVersion: 2,
            status: "ready",
            relayOrigin: "https://relay.example.com",
            instanceID: instance,
            deviceToken: token,
            expiresAt: "2023-11-14T23:13:20Z" // 1700003600
        )

        XCTAssertTrue(RelayAccessClaims.validateReadyPayload(payload, pairedInstanceID: instance, now: now))
    }

    func testExtraClaimsRejected() {
        let instance = "test-instance-123"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims: [String: Any] = [
            "iss": "solstone-journal",
            "sub": "instance:\(instance)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instance,
            "iat": 1_700_000_000,
            "exp": 1_700_003_600,
            "jti": "jwt-id-xyz",
            "device_fp": "extra-unallowed-field"
        ]
        let token = makeJWT(claims: claims)

        let payload = RelayAccessReadyPayload(
            protocolVersion: 2,
            status: "ready",
            relayOrigin: "https://relay.example.com",
            instanceID: instance,
            deviceToken: token,
            expiresAt: "2023-11-14T23:13:20Z"
        )

        XCTAssertFalse(RelayAccessClaims.validateReadyPayload(payload, pairedInstanceID: instance, now: now))
    }

    func testMismatchedInstanceOrExpiredRejected() {
        let instance = "test-instance-123"
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claims: [String: Any] = [
            "iss": "solstone-journal",
            "sub": "instance:\(instance)",
            "aud": "spl-relay",
            "scope": "session.dial",
            "ver": 2,
            "instance_id": instance,
            "iat": 1_700_000_000,
            "exp": 1_700_003_600,
            "jti": "jwt-id-xyz"
        ]
        let token = makeJWT(claims: claims)

        // Wrong instance ID in payload
        let payloadWrongInstance = RelayAccessReadyPayload(
            protocolVersion: 2,
            status: "ready",
            relayOrigin: "https://relay.example.com",
            instanceID: "other-instance",
            deviceToken: token,
            expiresAt: "2023-11-14T23:13:20Z"
        )
        XCTAssertFalse(RelayAccessClaims.validateReadyPayload(payloadWrongInstance, pairedInstanceID: instance, now: now))

        // Expired relative to now
        let lateNow = Date(timeIntervalSince1970: 1_700_004_000)
        let payloadValid = RelayAccessReadyPayload(
            protocolVersion: 2,
            status: "ready",
            relayOrigin: "https://relay.example.com",
            instanceID: instance,
            deviceToken: token,
            expiresAt: "2023-11-14T23:13:20Z"
        )
        XCTAssertFalse(RelayAccessClaims.validateReadyPayload(payloadValid, pairedInstanceID: instance, now: lateNow))

        // Missing jti
        var claimsMissingJti = claims
        claimsMissingJti.removeValue(forKey: "jti")
        let tokenMissingJti = makeJWT(claims: claimsMissingJti)
        let payloadMissingJti = RelayAccessReadyPayload(
            protocolVersion: 2,
            status: "ready",
            relayOrigin: "https://relay.example.com",
            instanceID: instance,
            deviceToken: tokenMissingJti,
            expiresAt: "2023-11-14T23:13:20Z"
        )
        XCTAssertFalse(RelayAccessClaims.validateReadyPayload(payloadMissingJti, pairedInstanceID: instance, now: now))

        // Empty device_token
        let payloadEmptyToken = RelayAccessReadyPayload(
            protocolVersion: 2,
            status: "ready",
            relayOrigin: "https://relay.example.com",
            instanceID: instance,
            deviceToken: "",
            expiresAt: "2023-11-14T23:13:20Z"
        )
        XCTAssertFalse(RelayAccessClaims.validateReadyPayload(payloadEmptyToken, pairedInstanceID: instance, now: now))
    }
}
