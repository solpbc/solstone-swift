// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

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

        XCTAssertEqual(pairURL.version, Self.canonicalBytes[0])
        XCTAssertEqual(pairURL.addressBytes, Array(Self.canonicalBytes[2..<6]))
        XCTAssertEqual(pairURL.addressString, "192.0.2.42")
        XCTAssertEqual(pairURL.port, UInt16(Self.canonicalBytes[6]) << 8 | UInt16(Self.canonicalBytes[7]))
        XCTAssertEqual(pairURL.nonceBytes, Array(Self.canonicalBytes[8..<24]))
        XCTAssertEqual(pairURL.caFingerprintBytes, Array(Self.canonicalBytes[24..<40]))
    }

    @MainActor
    func testValidRelayFragmentParses() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.wellKnownRelayBlob)))
        guard case .success(let pairURL) = result else {
            return XCTFail("expected successful relay pair URL parse, got \(result)")
        }

        XCTAssertEqual(pairURL.kind, .relay)
        XCTAssertEqual(pairURL.instanceID, "12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(pairURL.totp, "123456")
        XCTAssertEqual(pairURL.caFingerprintKind, .spkiSHA256)
    }

    @MainActor
    func testUnrelatedURLReturnsNil() {
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "https://example.com/p#\(Self.canonicalBlob)")!))
    }

    @MainActor
    func testBadBlobReturnsFailure_invalidBase32() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(URL(string: "https://link.solpbc.org/p#?")!))

        XCTAssertEqual(result, .failure(.invalidBase32(.outOfAlphabet("?"))))
    }

    @MainActor
    func testShortBlobReturnsFailure_invalidLength() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode([0x04, 0x01]))))

        guard case .failure(.invalidLength(_)) = result else {
            return XCTFail("expected invalidLength failure, got \(result)")
        }
    }

    @MainActor
    func testInvalidVersionReturnsFailure() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode([0x05]))))

        guard case .failure(.invalidVersion(_)) = result else {
            return XCTFail("expected invalidVersion failure, got \(result)")
        }
    }

    @MainActor
    func testUnsupportedAddressTypeReturnsFailure() throws {
        let result = try XCTUnwrap(UniversalLinkRouter.route(Self.url(fragment: Self.encode([0x04, 0x02]))))

        guard case .failure(.unsupportedAddrType(_)) = result else {
            return XCTFail("expected unsupportedAddrType failure, got \(result)")
        }
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
        XCTAssertNil(UniversalLinkRouter.route(URL(string: "http://link.solpbc.org/p#\(Self.canonicalBlob)")!))
    }

    private static let canonicalBlob = "0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
    private static let wellKnownRelayBlob = "0C938NKR28T5CY0J6HB7G4HMASW03RJ004HMASW9NF6YY0938NKRKAYDXW0XXBDYXZ5FXENY04HMASW9NF6YY00"
    private static let canonicalBytes: [UInt8] = [
        0x04, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
    ]

    private static func canonicalURL() -> URL {
        URL(string: "https://link.solpbc.org/p#\(canonicalBlob)")!
    }

    private static func url(fragment: String) -> URL {
        URL(string: "https://link.solpbc.org/p#\(fragment)")!
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
