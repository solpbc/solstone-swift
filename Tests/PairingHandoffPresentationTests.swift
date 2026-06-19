// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import SPLTunnel
import XCTest

nonisolated final class PairingHandoffPresentationTests: XCTestCase {
    @MainActor
    func testPresentsWhenPairURLExists() throws {
        let url = try XCTUnwrap(URL(string: Self.canonicalPairingLink))
        let pairURL = try PairURL.parse(url)

        XCTAssertTrue(PairingHandoffPresentation.shouldPresent(pairURL: pairURL, pairURLError: nil))
    }

    @MainActor
    func testPresentsWhenPairURLErrorExists() {
        XCTAssertTrue(
            PairingHandoffPresentation.shouldPresent(pairURL: nil, pairURLError: PairURLError.invalidLength(0))
        )
    }

    @MainActor
    func testIgnoresEmptyHandoff() {
        XCTAssertFalse(PairingHandoffPresentation.shouldPresent(pairURL: nil, pairURLError: nil))
    }

    private static let canonicalPairingLink = "https://go.solstone.app/p#0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
}
