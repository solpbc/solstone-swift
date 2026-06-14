// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SwiftUI
import UIKit
import XCTest

nonisolated final class SendStateStyleTests: XCTestCase {
    @MainActor
    func testSendStateAssetColorsResolveAndMeetContrastGate() throws {
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

        for pair in Self.contrastGatedPairs {
            let lightRatio = try self.contrastRatio(
                foregroundAssetName: pair.foregroundAssetName,
                backgroundAssetName: pair.backgroundAssetName,
                in: bundle,
                traits: lightTraits
            )
            let darkRatio = try self.contrastRatio(
                foregroundAssetName: pair.foregroundAssetName,
                backgroundAssetName: pair.backgroundAssetName,
                in: bundle,
                traits: darkTraits
            )
            XCTAssertGreaterThanOrEqual(lightRatio, 4.5, pair.foregroundAssetName)
            XCTAssertGreaterThanOrEqual(darkRatio, 4.5, pair.foregroundAssetName)
        }

        let orangeLightRatio = try self.contrastRatio(
            foregroundAssetName: "SendState/Sending/Foreground",
            backgroundAssetName: "SendState/Sending/ChipBackground",
            in: bundle,
            traits: lightTraits
        )
        let orangeDarkRatio = try self.contrastRatio(
            foregroundAssetName: "SendState/Sending/Foreground",
            backgroundAssetName: "SendState/Sending/ChipBackground",
            in: bundle,
            traits: darkTraits
        )
        let orangeReport = String(
            format: "orange send-state contrast: light %.3f:1, dark %.3f:1",
            Double(orangeLightRatio),
            Double(orangeDarkRatio)
        )
        XCTContext.runActivity(named: orangeReport) { activity in
            let attachment = XCTAttachment(string: orangeReport)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
            print(orangeReport)
        }

        let lightForegrounds = try Self.foregroundAssetNames.map {
            try self.resolvedComponents(assetName: $0, in: bundle, traits: lightTraits)
        }
        for lhsIndex in lightForegrounds.indices {
            for rhsIndex in lightForegrounds.indices where lhsIndex < rhsIndex {
                XCTAssertNotEqual(lightForegrounds[lhsIndex], lightForegrounds[rhsIndex])
            }
        }
    }

    @MainActor
    func testSendStateStyleMappingsUseLockedVocabulary() {
        let cases: [(OnThisPhoneSendState, String, String)] = [
            (.savedOnThisPhone, SourceVocabulary.sendStateCompactSaved, "internaldrive"),
            (.sending, SourceVocabulary.sendStateCompactOnTheWay, "arrow.up.circle"),
            (.inYourJournal, SourceVocabulary.sendStateCompactInJournal, "checkmark.circle"),
            (.needsAttention, SourceVocabulary.needsAttention, "exclamationmark.triangle"),
        ]

        for (state, expectedLabel, expectedSymbol) in cases {
            let style = SendStateStyle.style(for: state)
            XCTAssertEqual(style.compactLabel, expectedLabel)
            XCTAssertEqual(style.summaryLabel, expectedLabel)
            XCTAssertEqual(style.symbol, expectedSymbol)
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

    private func contrastRatio(
        foregroundAssetName: String,
        backgroundAssetName: String,
        in bundle: Bundle,
        traits: UITraitCollection
    ) throws -> CGFloat {
        let foreground = try self.resolvedComponents(assetName: foregroundAssetName, in: bundle, traits: traits)
        let background = try self.resolvedComponents(assetName: backgroundAssetName, in: bundle, traits: traits)
        return Self.contrastRatio(foreground: foreground, background: background)
    }

    private static func relativeLuminance(_ color: RGBA) -> CGFloat {
        func adjusted(_ component: CGFloat) -> CGFloat {
            if component <= 0.04045 {
                return component / 12.92
            }
            return pow((component + 0.055) / 1.055, 2.4)
        }

        return 0.2126 * adjusted(color.red)
            + 0.7152 * adjusted(color.green)
            + 0.0722 * adjusted(color.blue)
    }

    private static func contrastRatio(foreground: RGBA, background: RGBA) -> CGFloat {
        let foregroundLuminance = self.relativeLuminance(foreground)
        let backgroundLuminance = self.relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

private extension SendStateStyleTests {
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

    struct ContrastPair {
        let foregroundAssetName: String
        let backgroundAssetName: String
    }

    static let foregroundAssetNames = [
        "SendState/SavedOnThisPhone/Foreground",
        "SendState/Sending/Foreground",
        "SendState/InYourJournal/Foreground",
        "SendState/NeedsAttention/Foreground",
    ]

    static let contrastGatedPairs = [
        ContrastPair(
            foregroundAssetName: "SendState/SavedOnThisPhone/Foreground",
            backgroundAssetName: "SendState/SavedOnThisPhone/ChipBackground"
        ),
        ContrastPair(
            foregroundAssetName: "SendState/InYourJournal/Foreground",
            backgroundAssetName: "SendState/InYourJournal/ChipBackground"
        ),
        ContrastPair(
            foregroundAssetName: "SendState/NeedsAttention/Foreground",
            backgroundAssetName: "SendState/NeedsAttention/ChipBackground"
        ),
    ]

    static let expectedColors = [
        ExpectedColor(
            assetName: "SendState/SavedOnThisPhone/Foreground",
            light: RGBA(red: 0.282, green: 0.282, blue: 0.298, alpha: 1.000),
            dark: RGBA(red: 0.796, green: 0.835, blue: 0.882, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/SavedOnThisPhone/Dot",
            light: RGBA(red: 0.420, green: 0.420, blue: 0.439, alpha: 1.000),
            dark: RGBA(red: 0.580, green: 0.639, blue: 0.722, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/SavedOnThisPhone/ChipBackground",
            light: RGBA(red: 0.929, green: 0.929, blue: 0.941, alpha: 1.000),
            dark: RGBA(red: 0.118, green: 0.161, blue: 0.231, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/Sending/Foreground",
            light: RGBA(red: 0.690, green: 0.416, blue: 0.102, alpha: 1.000),
            dark: RGBA(red: 0.988, green: 0.827, blue: 0.302, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/Sending/Dot",
            light: RGBA(red: 0.910, green: 0.573, blue: 0.227, alpha: 1.000),
            dark: RGBA(red: 0.984, green: 0.573, blue: 0.235, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/Sending/ChipBackground",
            light: RGBA(red: 0.984, green: 0.925, blue: 0.851, alpha: 1.000),
            dark: RGBA(red: 0.259, green: 0.125, blue: 0.024, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/InYourJournal/Foreground",
            light: RGBA(red: 0.180, green: 0.486, blue: 0.196, alpha: 1.000),
            dark: RGBA(red: 0.290, green: 0.871, blue: 0.502, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/InYourJournal/Dot",
            light: RGBA(red: 0.180, green: 0.490, blue: 0.196, alpha: 1.000),
            dark: RGBA(red: 0.133, green: 0.773, blue: 0.369, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/InYourJournal/ChipBackground",
            light: RGBA(red: 0.906, green: 0.953, blue: 0.910, alpha: 1.000),
            dark: RGBA(red: 0.020, green: 0.180, blue: 0.086, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/NeedsAttention/Foreground",
            light: RGBA(red: 0.753, green: 0.224, blue: 0.169, alpha: 1.000),
            dark: RGBA(red: 0.988, green: 0.647, blue: 0.647, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/NeedsAttention/Dot",
            light: RGBA(red: 0.753, green: 0.224, blue: 0.169, alpha: 1.000),
            dark: RGBA(red: 0.973, green: 0.443, blue: 0.443, alpha: 1.000)
        ),
        ExpectedColor(
            assetName: "SendState/NeedsAttention/ChipBackground",
            light: RGBA(red: 0.984, green: 0.906, blue: 0.894, alpha: 1.000),
            dark: RGBA(red: 0.271, green: 0.039, blue: 0.039, alpha: 1.000)
        ),
    ]
}
