// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class EnablePushConstantsTests: XCTestCase {
    func testMintNonceMatchesCanonicalRegexAndHasExpectedCardinality() throws {
        let regex = try NSRegularExpression(pattern: EnablePushConstants.NONCE_REGEX)
        var samples = Set<String>()

        for _ in 0..<1_000 {
            let nonce = EnablePushConstants.mintNonce()
            XCTAssertEqual(nonce.count, EnablePushConstants.NONCE_LENGTH_CHARS)
            let range = NSRange(nonce.startIndex..<nonce.endIndex, in: nonce)
            XCTAssertEqual(regex.firstMatch(in: nonce, range: range)?.range, range)
            samples.insert(nonce)
        }

        XCTAssertGreaterThanOrEqual(samples.count, 990)
    }

    func testNonceRegexMatchesGroundingLiteral() throws {
        let groundingRegex = #"^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{52}$"#
        XCTAssertEqual(EnablePushConstants.NONCE_REGEX, groundingRegex)
        _ = try NSRegularExpression(pattern: groundingRegex)
    }

    func testNonceCharacterRejectsBiasedByteRange() {
        XCTAssertNotNil(EnablePushConstants.nonceCharacter(for: 0))
        XCTAssertNotNil(EnablePushConstants.nonceCharacter(for: 247))

        for byte in UInt8(248)...UInt8.max {
            XCTAssertNil(EnablePushConstants.nonceCharacter(for: byte))
        }
    }
}
