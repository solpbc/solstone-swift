// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class UniversalLinkRouterTests: XCTestCase {
    @MainActor
    func testValidDirectFragmentParses() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.canonicalURL()))
        guard case .success(let pairURL) = result else {
            return XCTFail("expected successful pair URL parse, got \(result)")
        }

        XCTAssertEqual(pairURL.kind, .direct)
        XCTAssertEqual(pairURL.candidates, [
            PairCandidate(address: "192.0.2.42", port: UInt16(Self.canonicalBytes[6]) << 8 | UInt16(Self.canonicalBytes[7]))
        ])
        XCTAssertEqual(pairURL.nonceBytes, Array(Self.canonicalBytes[8..<24]))
        XCTAssertEqual(pairURL.caFingerprintBytes, Array(Self.canonicalBytes[24..<40]))
        XCTAssertEqual(pairURL.caPin.kind, .certificateSHA256)
    }

    @MainActor
    func testValidRelayFragmentParses() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.wellKnownRelayBlob)))
        guard case .success(let pairURL) = result else {
            return XCTFail("expected successful relay pair URL parse, got \(result)")
        }

        XCTAssertEqual(pairURL.kind, .relay)
        XCTAssertEqual(Data(pairURL.sBytes), Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]))
        XCTAssertEqual(pairURL.caFingerprintBytes, [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
        XCTAssertEqual(pairURL.caPin.kind, .spkiSHA256)
        XCTAssertEqual(pairURL.relayOrigin?.resolved().absoluteString, "https://link.solstone.app")
    }

    @MainActor
    func testUnrelatedURLReturnsNil() {
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "https://example.com/p#\(Self.canonicalBlob)")!))
    }

    @MainActor
    func testBadBlobReturnsFailure_invalidBase32() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(URL(string: "https://go.solstone.app/p#?")!))

        XCTAssertEqual(result, .failure(.invalidBase32(.outOfAlphabet("?"))))
    }

    @MainActor
    func testShortBlobReturnsFailure_truncated() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode([0x04, 0x01]))))

        XCTAssertEqual(result, .failure(.truncated(expected: 40, got: 2)))
    }

    @MainActor
    func testOverlongBlobReturnsFailure_lengthMismatch() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode(Self.canonicalBytes + [0x00]))))

        XCTAssertEqual(result, .failure(.lengthMismatch(expected: 40, got: 41)))
    }

    @MainActor
    func testCandidateCountOutsideOneToFourReturnsFailure_invalidCandidateCount() throws {
        for count: UInt8 in [0, 5] {
            let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode([0x05, 0x01, count]))))

            XCTAssertEqual(result, .failure(.invalidCandidateCount(count)))
        }
    }

    @MainActor
    func testInvalidVersionReturnsFailure() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode([0x07]))))

        guard case .failure(.invalidVersion(_)) = result else {
            return XCTFail("expected invalidVersion failure, got \(result)")
        }
    }

    @MainActor
    func testUnsupportedAddressTypeReturnsFailure() throws {
        var bytes = Self.canonicalBytes
        bytes[1] = 0x02
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode(bytes))))

        XCTAssertEqual(result, .failure(.unsupportedAddrType(0x02)))
    }

    @MainActor
    func testShortBlobWithUnsupportedAddressTypeReportsTruncationFirst() throws {
        // The direct form's length is checked before its address type, so a two-byte blob
        // no longer reports the address type it names.
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode([0x04, 0x02]))))

        XCTAssertNotEqual(result, .failure(.unsupportedAddrType(0x02)))
        XCTAssertEqual(result, .failure(.truncated(expected: 40, got: 2)))
    }

    @MainActor
    func testNonCanonicalPadBitsReturnsFailure_invalidBase32() throws {
        let canonicalWithPadBits = Self.encode(Array(Self.canonicalBytes.dropLast()))
        let nonCanonical = String(canonicalWithPadBits.dropLast()) + "H"
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: nonCanonical)))

        XCTAssertEqual(result, .failure(.invalidBase32(.nonCanonicalPadBits)))
    }

    @MainActor
    func testWrongSchemeReturnsNilBeforeParsing() {
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "http://go.solstone.app/p#\(Self.canonicalBlob)")!))
    }

    @MainActor
    func testSolstonePairAliasesReturnNilFromRouter() {
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "solstone://pair#\(Self.canonicalBlob)")!))
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "solstone://pair/#\(Self.wellKnownRelayBlob)")!))
    }

    @MainActor
    func testPairAliasNormalizerCanonicalURLRoutesSuccessfully() throws {
        let directAlias = "solstone://pair#\(Self.canonicalBlob)"
        let directCanonical = try XCTUnwrap(PairAliasNormalizer.canonicalURL(from: directAlias))
        let directResult = try XCTUnwrap(UniversalLinkRouter.route(directCanonical))
        let httpsDirectResult = try XCTUnwrap(UniversalLinkRouter.route(Self.canonicalURL()))
        XCTAssertEqual(directResult, httpsDirectResult)

        let relayAlias = "solstone://pair/#\(Self.wellKnownRelayBlob)"
        let relayCanonical = try XCTUnwrap(PairAliasNormalizer.canonicalURL(from: relayAlias))
        let relayResult = try XCTUnwrap(UniversalLinkRouter.route(relayCanonical))
        let httpsRelayResult = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.wellKnownRelayBlob)))
        XCTAssertEqual(relayResult, httpsRelayResult)
    }

    static let canonicalBlob = "0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
    static let wellKnownRelayBlob = "0R0J6HB7H6NWVVR1VTPVXVYAZTXBW0938NKRKAYDXW00"
    private static let canonicalBytes: [UInt8] = [
        0x04, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
    ]

    private static func canonicalURL() -> URL {
        URL(string: "https://go.solstone.app/p#\(canonicalBlob)")!
    }

    private static func url(fragment: String) -> URL {
        URL(string: "https://go.solstone.app/p#\(fragment)")!
    }

    private static func encode(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var accumulator: UInt64 = 0
        var bitCount = 0
        var output = ""

        for byte in bytes {
            accumulator = (accumulator << 8) | UInt64(byte)
            bitCount += 8

            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((accumulator >> UInt64(bitCount)) & 0x1f)
                output.append(alphabet[index])
                accumulator &= (1 << UInt64(bitCount)) - 1
            }
        }

        if bitCount > 0 {
            let index = Int((accumulator << UInt64(5 - bitCount)) & 0x1f)
            output.append(alphabet[index])
        }

        return output
    }
}
