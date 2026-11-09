// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

/// The system's prominent button puts white text on the app's orange, which measures 2.5:1.
/// The app's own filled button puts ink on it instead, so no source file may fall back to the system one.
nonisolated final class BrandProminentButtonTests: XCTestCase {
    func testNoSourceUsesTheSystemProminentButton() throws {
        let sources = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources")
        let files = try StringLiteralGrepSupport.swiftFiles(under: sources)
        XCTAssertFalse(files.isEmpty, "the source walk found no Swift files")

        var offenders: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("borderedProminent") {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "use BrandProminentButtonStyle(); white on the orange fails contrast")
    }

    func testTheBrandButtonPutsInkOnTheOrange() throws {
        let style = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Design/DeckStyle.swift")
        let text = try String(contentsOf: style, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "struct BrandProminentButtonStyle"))
        let body = text[start.lowerBound...].prefix(1200)
        XCTAssertTrue(body.contains("Color.inkOnBrand"))
        XCTAssertTrue(body.contains("Color.solOrange"))
    }
}
