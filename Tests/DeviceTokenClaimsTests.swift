// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
// Reaches SPLTunnel package internals; relies on Xcode compiling SPM products with testability in Debug.
@testable import SPLTunnel
import XCTest

nonisolated final class DeviceTokenClaimsTests: XCTestCase {
    func testParseValidToken() throws {
        let token = Self.token(payload: ["iat": 1_000.0, "exp": 2_000.0])

        let claims = try XCTUnwrap(DeviceTokenClaims.parse(token))

        XCTAssertEqual(claims.issuedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(claims.expiresAt, Date(timeIntervalSince1970: 2_000))
    }

    func testNeedsRefreshForMalformedShortMissingClaimsAndBadTTL() {
        XCTAssertTrue(DeviceTokenClaims.needsRefresh(token: nil, now: Date(timeIntervalSince1970: 1_500)))
        XCTAssertTrue(DeviceTokenClaims.needsRefresh(token: "not-a-jwt", now: Date(timeIntervalSince1970: 1_500)))
        XCTAssertTrue(DeviceTokenClaims.needsRefresh(token: Self.token(payload: ["iat": 1_000.0]), now: Date(timeIntervalSince1970: 1_500)))
        XCTAssertTrue(DeviceTokenClaims.needsRefresh(token: Self.token(payload: ["exp": 2_000.0]), now: Date(timeIntervalSince1970: 1_500)))
        XCTAssertTrue(DeviceTokenClaims.needsRefresh(token: Self.token(payload: ["iat": 2_000.0, "exp": 1_000.0]), now: Date(timeIntervalSince1970: 1_500)))
    }

    func testNeedsRefreshBoundaryUsesStrictlyGreaterThanEightyPercent() throws {
        let claims = try XCTUnwrap(DeviceTokenClaims.parse(Self.token(payload: ["iat": 1_000.0, "exp": 2_000.0])))

        XCTAssertFalse(claims.needsRefresh(now: Date(timeIntervalSince1970: 1_799)))
        XCTAssertFalse(claims.needsRefresh(now: Date(timeIntervalSince1970: 1_800)))
        XCTAssertTrue(claims.needsRefresh(now: Date(timeIntervalSince1970: 1_801)))
    }

    static func token(payload: [String: Double]) -> String {
        "e30.\(Self.base64URL(payload)).sig"
    }

    private static func base64URL(_ object: [String: Double]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
