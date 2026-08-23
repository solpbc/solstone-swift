// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class WelcomeScreenCopyTests: XCTestCase {
    func testThreeSplashLinesAreByteIdenticalInOrder() throws {
        let text = try Self.contents("Sources/Onboarding/WelcomeScreen.swift")
        let title = try XCTUnwrap(text.range(of: "welcome to solstone."))
        let line2 = try XCTUnwrap(
            text.range(of: "the solstone app takes in what you share with it, and all of it goes into your journal.")
        )
        let line3 = try XCTUnwrap(text.range(of: "your journal is always private, only yours."))
        XCTAssertLessThan(title.lowerBound, line2.lowerBound)
        XCTAssertLessThan(line2.lowerBound, line3.lowerBound)
        XCTAssertFalse(text.contains("private by design"))
        XCTAssertFalse(text.contains("no ads, no analytics"))
        XCTAssertTrue(text.contains("finishes setup and opens your day"))
    }
}

private extension WelcomeScreenCopyTests {
    static func contents(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
