// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class LocationProjectConfigTests: XCTestCase {
    func testProjectYMLIncludesLocationUsageStringsAndBackgroundMode() throws {
        let projectYML = try String(contentsOf: Self.projectYMLURL(), encoding: .utf8)

        XCTAssertTrue(projectYML.contains(#"INFOPLIST_KEY_NSLocationWhenInUseUsageDescription: "solstone adds where your day happens to your journal — kept by you and nowhere else. you choose how much; you can change it or delete it any time.""#))
        XCTAssertTrue(projectYML.contains(#"INFOPLIST_KEY_NSLocationAlwaysAndWhenInUseUsageDescription: "solstone keeps where your day happens in your journal, even when it's not open — kept by you and nowhere else. you choose how much; you can change it or delete it any time.""#))
        XCTAssertTrue(projectYML.contains("          - audio"))
        XCTAssertTrue(projectYML.contains("          - fetch"))
        XCTAssertTrue(projectYML.contains("          - location"))
        XCTAssertTrue(projectYML.contains("          - remote-notification"))
    }

    private static func projectYMLURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("project.yml")
    }
}
