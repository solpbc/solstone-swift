// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import SPLTunnel
import XCTest

nonisolated final class Crockford32Tests: XCTestCase {
    func testEmptyStringDecodesToEmptyBytes() throws {
        XCTAssertEqual(try Crockford32.decode(""), [])
    }

    func testByteRoundTrip() throws {
        let bytes = Array(UInt8.min...UInt8.max)
        XCTAssertEqual(try Crockford32.decode(Self.encode(bytes)), bytes)
    }

    func testLowercaseFoldsToUppercase() throws {
        let lowercase = "080w000258dsx8djrfaebxg733favfqfsbzbnfg14d2pf2dbsqqg"
        XCTAssertEqual(try Crockford32.decode(lowercase), try Crockford32.decode(lowercase.uppercased()))
    }

    func testAmbiguousOneCharactersFoldToOne() throws {
        let expected = try Crockford32.decode("10")
        XCTAssertEqual(try Crockford32.decode("I0"), expected)
        XCTAssertEqual(try Crockford32.decode("i0"), expected)
        XCTAssertEqual(try Crockford32.decode("l0"), expected)
        XCTAssertEqual(try Crockford32.decode("L0"), expected)
    }

    func testAmbiguousOCharactersFoldToZero() throws {
        let expected = try Crockford32.decode("00")
        XCTAssertEqual(try Crockford32.decode("O0"), expected)
        XCTAssertEqual(try Crockford32.decode("o0"), expected)
    }

    func testHyphenAndWhitespaceAreIgnored() throws {
        XCTAssertEqual(try Crockford32.decode("080W0002"), try Crockford32.decode("08 0W-00\n02"))
    }

    func testQuestionMarkIsRejectedAsOutOfAlphabet() {
        // ? survives Crockford folding and is clearly outside the alphabet.
        XCTAssertThrowsError(try Crockford32.decode("?")) { error in
            XCTAssertEqual(error as? PairURLError.Base32Reason, .outOfAlphabet("?"))
        }
    }

    func testNonCanonicalPadBitsAreRejected() {
        let canonical = "080W000258DSX8DJRFAEBXG733FAVFQFSBZBNFG14D2PF2DBSQQG"
        let nonCanonical = String(canonical.dropLast()) + "H"

        XCTAssertThrowsError(try Crockford32.decode(nonCanonical)) { error in
            XCTAssertEqual(error as? PairURLError.Base32Reason, .nonCanonicalPadBits)
        }
    }

    func testSingleNonzeroPadBitsAreRejected() {
        XCTAssertThrowsError(try Crockford32.decode("1")) { error in
            XCTAssertEqual(error as? PairURLError.Base32Reason, .nonCanonicalPadBits)
        }
    }

    func testSingleZeroPadBitsDecodeToEmptyBytes() throws {
        XCTAssertEqual(try Crockford32.decode("0"), [])
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
