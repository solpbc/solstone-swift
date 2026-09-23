// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

/// 🔒 2026-09-23 (sun-arc spec §§ 6, 10): the appearance is the owner's system setting. The app
/// reads `\.colorScheme` and never sets it; the sun arc's 09-19 clock-driven
/// `.preferredColorScheme` snap is gone and must not come back, here or anywhere else.
nonisolated final class SunArcAppearanceGrepTests: XCTestCase {
    private static let forbidden = [
        "preferredColorScheme",
        "overrideUserInterfaceStyle",
        ".environment(\\.colorScheme",
    ]

    func testNothingOverridesTheOwnersAppearance() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let scanRoots = [
            "Sources", "Watch", "SolstoneShareExtension", "SolstoneBroadcastExtension",
            "SolstoneLiveActivityWidget", "SolstoneNotificationContent", "SolstoneWatchComplication",
        ].map { root.appendingPathComponent($0) }
        var scanned = 0
        for scanRoot in scanRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: scanRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    for forbidden in Self.forbidden where line.contains(forbidden) {
                        XCTFail("\(forbidden) overrides the owner's appearance at \(url.path):\(index + 1)")
                    }
                }
            }
        }
        // The scan itself must have seen the sun arc, or a moved tree would pass vacuously.
        XCTAssertGreaterThan(scanned, 100)
        let host = root.appendingPathComponent("Sources/SunArc/SunArcBackgroundHost.swift")
        XCTAssertTrue(try String(contentsOf: host, encoding: .utf8).contains("@Environment(\\.colorScheme)"))
    }
}
