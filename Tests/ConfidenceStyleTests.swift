// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import UIKit
import XCTest

nonisolated final class ConfidenceStyleTests: XCTestCase {
    @MainActor
    func testConfidenceAssetColorsResolveToCopiedTriples() throws {
        let bundle = Bundle(for: AppDelegate.self)
        let lightTraits = UITraitCollection(userInterfaceStyle: .light)
        let darkTraits = UITraitCollection(userInterfaceStyle: .dark)

        for expected in Self.expectedColors {
            try self.assertResolvedColor(
                expected.assetName,
                in: bundle,
                traits: lightTraits,
                matches: expected.light
            )
            try self.assertResolvedColor(
                expected.assetName,
                in: bundle,
                traits: darkTraits,
                matches: expected.dark
            )
        }
    }

    @MainActor
    func testConfidenceStyleMappingsUseLockedVocabularyAndAssets() {
        let cases: [(AnswerProvenance.Confidence, String, String, String, String)] = [
            (
                .high,
                "Confidence/High/Dot",
                "Confidence/High/Text",
                "Confidence/High/ChipBackground",
                SourceVocabulary.chatSourceConfidenceHigh
            ),
            (
                .medium,
                "Confidence/Medium/Dot",
                "Confidence/Medium/Text",
                "Confidence/Medium/ChipBackground",
                SourceVocabulary.chatSourceConfidenceMedium
            ),
            (
                .low,
                "Confidence/Low/Dot",
                "Confidence/Low/Text",
                "Confidence/Low/ChipBackground",
                SourceVocabulary.chatSourceConfidenceLow
            ),
        ]

        for (confidence, dotAssetName, textAssetName, chipBackgroundAssetName, label) in cases {
            let style = ConfidenceStyle.style(for: confidence)
            XCTAssertEqual(style.dotAssetName, dotAssetName)
            XCTAssertEqual(style.textAssetName, textAssetName)
            XCTAssertEqual(style.chipBackgroundAssetName, chipBackgroundAssetName)
            XCTAssertEqual(style.label, label)
        }
    }

    private func assertResolvedColor(
        _ assetName: String,
        in bundle: Bundle,
        traits: UITraitCollection,
        matches expected: RGBA,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let actual = try self.resolvedComponents(assetName: assetName, in: bundle, traits: traits, file: file, line: line)
        XCTAssertEqual(actual.red, expected.red, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(actual.alpha, expected.alpha, accuracy: 0.001, file: file, line: line)
    }

    private func resolvedComponents(
        assetName: String,
        in bundle: Bundle,
        traits: UITraitCollection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> RGBA {
        let uiColor = try XCTUnwrap(
            UIColor(named: assetName, in: bundle, compatibleWith: nil)?.resolvedColor(with: traits),
            file: file,
            line: line
        )
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
        return RGBA(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension ConfidenceStyleTests {
    struct RGBA: Equatable {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    struct ExpectedColor {
        let assetName: String
        let light: RGBA
        let dark: RGBA
    }

    static let expectedColors = [
        ExpectedColor(
            assetName: "Confidence/High/Dot",
            light: RGBA(red: 0.180, green: 0.490, blue: 0.196, alpha: 1.000),
            dark: RGBA(red: 0.133, green: 0.773, blue: 0.369, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/High/Text",
            light: RGBA(red: 0.180, green: 0.486, blue: 0.196, alpha: 1.000),
            dark: RGBA(red: 0.290, green: 0.871, blue: 0.502, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/High/ChipBackground",
            light: RGBA(red: 0.906, green: 0.953, blue: 0.910, alpha: 1.000),
            dark: RGBA(red: 0.020, green: 0.180, blue: 0.086, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/Medium/Dot",
            light: RGBA(red: 0.910, green: 0.573, blue: 0.227, alpha: 1.000),
            dark: RGBA(red: 0.984, green: 0.573, blue: 0.235, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/Medium/Text",
            light: RGBA(red: 0.596, green: 0.357, blue: 0.078, alpha: 1.000),
            dark: RGBA(red: 0.988, green: 0.827, blue: 0.302, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/Medium/ChipBackground",
            light: RGBA(red: 0.984, green: 0.925, blue: 0.851, alpha: 1.000),
            dark: RGBA(red: 0.259, green: 0.125, blue: 0.024, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/Low/Dot",
            light: RGBA(red: 0.420, green: 0.420, blue: 0.439, alpha: 1.000),
            dark: RGBA(red: 0.580, green: 0.639, blue: 0.722, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/Low/Text",
            light: RGBA(red: 0.282, green: 0.282, blue: 0.298, alpha: 1.000),
            dark: RGBA(red: 0.796, green: 0.835, blue: 0.882, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "Confidence/Low/ChipBackground",
            light: RGBA(red: 0.929, green: 0.929, blue: 0.941, alpha: 1.000),
            dark: RGBA(red: 0.118, green: 0.161, blue: 0.231, alpha: 1.000)
        ),
    ]
}
