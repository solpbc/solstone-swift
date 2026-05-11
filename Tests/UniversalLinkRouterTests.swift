// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class UniversalLinkRouterTests: XCTestCase {
    @MainActor
    func testValidFragmentParses() throws {
        let url = Self.validURL()
        let pairURL = try XCTUnwrap(UniversalLinkRouter.route(url))

        XCTAssertEqual(pairURL.homeURL.absoluteString, "https://home.example.com:8443")
        XCTAssertEqual(pairURL.token, "token-123")
        XCTAssertEqual(pairURL.caFingerprintHex, String(repeating: "a", count: 64))
        XCTAssertEqual(pairURL.label, "home one")
        XCTAssertEqual(pairURL.version, 1)
    }

    @MainActor
    func testUnrelatedURLReturnsNil() {
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "https://example.com/p#h=x")!))
    }

    @MainActor
    func testMissingFieldsThrowSpecificErrors() {
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "t=token&f=\(Self.fingerprint)&l=home&v=1"))) {
            XCTAssertEqual($0 as? PairURLError, .missingField("h"))
        }
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&f=\(Self.fingerprint)&l=home&v=1"))) {
            XCTAssertEqual($0 as? PairURLError, .missingField("t"))
        }
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&t=token&l=home&v=1"))) {
            XCTAssertEqual($0 as? PairURLError, .missingField("f"))
        }
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&t=token&f=\(Self.fingerprint)&v=1"))) {
            XCTAssertEqual($0 as? PairURLError, .missingField("l"))
        }
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&t=token&f=\(Self.fingerprint)&l=home"))) {
            XCTAssertEqual($0 as? PairURLError, .invalidVersion)
        }
    }

    @MainActor
    func testInvalidFingerprintLengthThrows() {
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&t=token&f=abc&l=home&v=1"))) {
            XCTAssertEqual($0 as? PairURLError, .invalidFingerprint)
        }
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&t=token&f=\(String(repeating: "a", count: 65))&l=home&v=1"))) {
            XCTAssertEqual($0 as? PairURLError, .invalidFingerprint)
        }
    }

    @MainActor
    func testNonHTTPSHomeAndBadVersionThrow() {
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=http%3A%2F%2Fhome.example.com&t=token&f=\(Self.fingerprint)&l=home&v=1"))) {
            XCTAssertEqual($0 as? PairURLError, .nonHTTPSHomeURL)
        }
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&t=token&f=\(Self.fingerprint)&l=home&v=2"))) {
            XCTAssertEqual($0 as? PairURLError, .invalidVersion)
        }
    }

    @MainActor
    func testExtraFragmentFieldsAreIgnored() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: "h=https%3A%2F%2Fhome.example.com&t=token&f=\(Self.fingerprint)&l=home&v=1&x=ignored"))
        XCTAssertEqual(pairURL.token, "token")
    }

    private static let fingerprint = String(repeating: "a", count: 64)

    private static func validURL() -> URL {
        url(fragment: "h=https%3A%2F%2Fhome.example.com%3A8443&t=token-123&f=\(fingerprint)&l=home%20one&v=1")
    }

    private static func url(fragment: String) -> URL {
        URL(string: "https://link.solpbc.org/p#\(fragment)")!
    }
}
