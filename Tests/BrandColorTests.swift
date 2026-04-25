// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import UIKit
import XCTest

@MainActor
final class BrandColorTests: XCTestCase {
    func testSolOrangeMatchesBrandSpec() throws {
        try self.assertMatchesBrandSpec(
            Color.solOrange,
            red: 0.910,
            green: 0.573,
            blue: 0.227
        )
    }

    func testSolGoldMatchesBrandSpec() throws {
        try self.assertMatchesBrandSpec(
            Color.solGold,
            red: 0.961,
            green: 0.780,
            blue: 0.251
        )
    }

    func testSolOrangeAccessibleMatchesBrandSpec() throws {
        try self.assertMatchesBrandSpec(
            Color.solOrangeAccessible,
            red: 0.690,
            green: 0.416,
            blue: 0.102
        )
    }

    func testAccentColorLightMatchesSolOrangeAccessible() throws {
        let bundle = Bundle(for: AppDelegate.self)
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let accentColor = try XCTUnwrap(
            UIColor(named: "AccentColor", in: bundle, compatibleWith: nil)?.resolvedColor(with: traits)
        )
        try self.assertMatchesBrandSpec(
            Color(uiColor: accentColor),
            red: 0.690,
            green: 0.416,
            blue: 0.102
        )
    }

    private func assertMatchesBrandSpec(
        _ color: Color,
        red expectedRed: CGFloat,
        green expectedGreen: CGFloat,
        blue expectedBlue: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let uiColor = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        XCTAssertTrue(
            uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
            "expected RGB-convertible color",
            file: file,
            line: line
        )
        XCTAssertEqual(red, expectedRed, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(green, expectedGreen, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(blue, expectedBlue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(alpha, 1, accuracy: 0.001, file: file, line: line)
    }
}
