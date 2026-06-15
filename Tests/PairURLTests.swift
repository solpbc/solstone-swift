// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel
import XCTest

nonisolated final class PairURLTests: XCTestCase {
    func testCanonicalReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.canonicalBlob))

        XCTAssertEqual(pairURL.version, 0x04)
        XCTAssertEqual(pairURL.kind, .direct)
        XCTAssertEqual(pairURL.addressBytes, [0xC0, 0x00, 0x02, 0x2A])
        XCTAssertEqual(pairURL.addressString, "192.0.2.42")
        XCTAssertEqual(pairURL.port, 0x1B9E)
        XCTAssertEqual(pairURL.nonceBytes, [
            0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
            0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
        ])
        XCTAssertEqual(pairURL.caFingerprintBytes, [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
        XCTAssertEqual(pairURL.caFingerprintKind, .certificateSHA256)
        XCTAssertNil(pairURL.instanceID)
        XCTAssertNil(pairURL.totp)
        XCTAssertNil(pairURL.relayOrigin)
    }

    func testWellKnownRelayReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.wellKnownRelayBlob))

        XCTAssertEqual(pairURL.version, 0x03)
        XCTAssertEqual(pairURL.kind, .relay)
        XCTAssertEqual(pairURL.instanceID, "12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(pairURL.totp, "123456")
        XCTAssertEqual(pairURL.nonceBytes, [
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
        XCTAssertEqual(pairURL.caFingerprintKind, .spkiSHA256)
        XCTAssertEqual(pairURL.caFingerprintBytes, [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
        XCTAssertNil(pairURL.relayOrigin)
    }

    func testCustomRelayReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.customRelayBlob))

        XCTAssertEqual(pairURL.kind, .relay)
        XCTAssertEqual(pairURL.instanceID, "12345678-1234-5678-1234-567812345678")
        XCTAssertEqual(pairURL.totp, "123456")
        XCTAssertEqual(pairURL.relayOrigin?.absoluteString, "https://relay.example")
    }

    func testWrongSchemeThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "http://go.solstone.app/p#\(Self.canonicalBlob)")!)) {
            XCTAssertEqual($0 as? PairURLError, .wrongScheme("http"))
        }
    }

    func testWrongHostThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "https://example.com/p#\(Self.canonicalBlob)")!)) {
            XCTAssertEqual($0 as? PairURLError, .wrongHost("example.com"))
        }
    }

    func testWrongPathThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "https://go.solstone.app/wrong#\(Self.canonicalBlob)")!)) {
            XCTAssertEqual($0 as? PairURLError, .wrongPath("/wrong"))
        }
    }

    func testMissingFragmentThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "https://go.solstone.app/p")!)) {
            XCTAssertEqual($0 as? PairURLError, .missingFragment)
        }
    }

    func testInvalidBase32Throws() {
        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: "?"))) {
            XCTAssertEqual($0 as? PairURLError, .invalidBase32(.outOfAlphabet("?")))
        }
    }

    func testInvalidVersionThrows() {
        var bytes = Self.canonicalBytes
        bytes[0] = 0x01

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidVersion(0x01))
        }
    }

    func testLegacyDirectFragmentThrowsInvalidVersion() {
        let legacyBytes: [UInt8] = [
            0x02, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
            0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ]

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(legacyBytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidVersion(0x02))
        }
    }

    func testIPv4AddressTypeWithLength39ThrowsInvalidLength() {
        var bytes = Self.canonicalBytes
        bytes.removeLast()

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidLength(39))
        }
    }

    func testIPv4AddressTypeWithLength41ThrowsInvalidLength() {
        var bytes = Self.canonicalBytes
        bytes.append(0x00)

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidLength(41))
        }
    }

    func testReservedIPv6AddressTypeThrowsUnsupported() {
        var bytes = Self.canonicalBytes
        bytes[1] = 0x02

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .unsupportedAddrType(0x02))
        }
    }

    func testUnknownAddressTypeThrowsUnsupported() {
        var bytes = Self.canonicalBytes
        bytes[1] = 0x03

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .unsupportedAddrType(0x03))
        }
    }

    func testRelayUnsupportedFingerprintTagThrows() {
        var bytes = Self.relayBytes()
        bytes[36] = 0x02

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .unsupportedCAFingerprintTag(0x02))
        }
    }

    func testRelaySelectorLengthMismatchThrowsInvalidLength() {
        var bytes = Self.relayBytes()
        bytes[53] = 0x04

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidLength(54))
        }
    }

    func testRelayInvalidOriginThrows() {
        let bytes = Self.relayBytes(selector: "ftp://relay.example")

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidRelayOrigin)
        }
    }

    private static let canonicalBlob = "0G0W000258DSX8DJRFAEBXG7308J4CT4ANK7F26YNPZEZJQYQAZ028T5CY4TQKFF"
    private static let wellKnownRelayBlob = "0C938NKR28T5CY0J6HB7G4HMASW03RJ004HMASW9NF6YY0938NKRKAYDXW0XXBDYXZ5FXENY04HMASW9NF6YY00"
    private static let customRelayBlob = "0C938NKR28T5CY0J6HB7G4HMASW03RJ004HMASW9NF6YY0938NKRKAYDXW0XXBDYXZ5FXENY04HMASW9NF6YY5B8EHT70WST5WQQ4SBCC5WJWSBRC5PQ0V35"
    private static let canonicalBytes: [UInt8] = [
        0x04, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
    ]

    private static func url(fragment: String) -> URL {
        URL(string: "https://go.solstone.app/p#\(fragment)")!
    }

    private static func relayBytes(selector: String = "") -> [UInt8] {
        let selectorBytes = Array(selector.utf8)
        return [
            0x03,
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
            0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x56, 0x78,
            0x01, 0xE2, 0x40,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            0x01,
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF,
            UInt8(selectorBytes.count)
        ] + selectorBytes
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
