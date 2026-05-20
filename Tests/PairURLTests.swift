// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import SPLTunnel
import XCTest

nonisolated final class PairURLTests: XCTestCase {
    func testCanonicalReferenceVectorParses() throws {
        let pairURL = try PairURL.parse(Self.url(fragment: Self.canonicalBlob))

        XCTAssertEqual(pairURL.version, 0x02)
        XCTAssertEqual(pairURL.addressBytes, [0xC0, 0x00, 0x02, 0x2A])
        XCTAssertEqual(pairURL.addressString, "192.0.2.42")
        XCTAssertEqual(pairURL.port, 0x1B9E)
        XCTAssertEqual(pairURL.nonceBytes, [0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18])
        XCTAssertEqual(pairURL.caFingerprintBytes, [
            0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
            0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
        ])
    }

    func testWrongSchemeThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "http://link.solpbc.org/p#\(Self.canonicalBlob)")!)) {
            XCTAssertEqual($0 as? PairURLError, .wrongScheme("http"))
        }
    }

    func testWrongHostThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "https://example.com/p#\(Self.canonicalBlob)")!)) {
            XCTAssertEqual($0 as? PairURLError, .wrongHost("example.com"))
        }
    }

    func testWrongPathThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "https://link.solpbc.org/wrong#\(Self.canonicalBlob)")!)) {
            XCTAssertEqual($0 as? PairURLError, .wrongPath("/wrong"))
        }
    }

    func testMissingFragmentThrows() {
        XCTAssertThrowsError(try PairURL.parse(URL(string: "https://link.solpbc.org/p")!)) {
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

    func testIPv4AddressTypeWithLength31ThrowsInvalidLength() {
        var bytes = Self.canonicalBytes
        bytes.removeLast()

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidLength(31))
        }
    }

    func testIPv4AddressTypeWithLength33ThrowsInvalidLength() {
        var bytes = Self.canonicalBytes
        bytes.append(0x00)

        XCTAssertThrowsError(try PairURL.parse(Self.url(fragment: Self.encode(bytes)))) {
            XCTAssertEqual($0 as? PairURLError, .invalidLength(33))
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

    private static let canonicalBlob = "080W000258DSX8DJRFAEBXG733FAVFQFSBZBNFG14D2PF2DBSQQG"
    private static let canonicalBytes: [UInt8] = [
        0x02, 0x01, 0xC0, 0x00, 0x02, 0x2A, 0x1B, 0x9E,
        0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6, 0x07, 0x18,
        0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF
    ]

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
