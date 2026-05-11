// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class PairTokenTests: XCTestCase {
    @MainActor
    func testParseHappyPath() throws {
        let parsed = try PairToken.parse("solstone://pair?token=ptk_123&host=https://journal.example.com")

        XCTAssertEqual(parsed.token, "ptk_123")
        XCTAssertEqual(parsed.host, URL(string: "https://journal.example.com"))
    }

    @MainActor
    func testParseRejectsWrongScheme() {
        XCTAssertThrowsError(try PairToken.parse("https://pair?token=ptk_123&host=https://journal.example.com")) { error in
            XCTAssertEqual(error as? PairTokenError, .invalidScheme)
        }
    }

    @MainActor
    func testParseRejectsMissingToken() {
        XCTAssertThrowsError(try PairToken.parse("solstone://pair?host=https://journal.example.com")) { error in
            XCTAssertEqual(error as? PairTokenError, .missingToken)
        }
    }

    @MainActor
    func testParseRejectsMissingHost() {
        XCTAssertThrowsError(try PairToken.parse("solstone://pair?token=ptk_123")) { error in
            XCTAssertEqual(error as? PairTokenError, .missingHost)
        }
    }
}
