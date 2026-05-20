// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class UniversalLinkRouterTests: XCTestCase {
    @MainActor
    func testValidV2FragmentParses() throws {
        let pairURL = try XCTUnwrap(UniversalLinkRouter.route(Self.canonicalURL()))

        XCTAssertEqual(pairURL.version, 2)
        XCTAssertEqual(pairURL.addressBytes, [192, 0, 2, 42])
        XCTAssertEqual(pairURL.addressString, "192.0.2.42")
        XCTAssertEqual(pairURL.port, 7070)
        XCTAssertEqual(pairURL.nonceBytes, [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18])
        XCTAssertEqual(pairURL.caFingerprintBytes, [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
    }

    @MainActor
    func testUnrelatedURLReturnsNil() {
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "https://example.com/p#\(Self.canonicalBlob)")!))
    }

    @MainActor
    func testBadBlobReturnsNil() {
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "https://link.solpbc.org/p#?")!))
    }

    private static let canonicalBlob = "080W000258DSX8DJRFAEBXG733FAVFQFSBZBNFG14D2PF2DBSQQG"

    private static func canonicalURL() -> URL {
        URL(string: "https://link.solpbc.org/p#\(canonicalBlob)")!
    }
}
