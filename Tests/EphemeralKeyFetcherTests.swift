// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

final class EphemeralKeyFetcherTests: XCTestCase {
    func testDecodesEphemeralKeyResponse() throws {
        let data = Data(#"{"ephemeral_key": "ek_test123"}"#.utf8)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        struct EphemeralKeyResponse: Decodable {
            let ephemeralKey: String
        }

        let decoded = try decoder.decode(EphemeralKeyResponse.self, from: data)

        XCTAssertEqual(decoded.ephemeralKey, "ek_test123")
    }
}
