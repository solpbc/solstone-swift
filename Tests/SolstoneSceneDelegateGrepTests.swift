// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SolstoneSceneDelegateGrepTests: XCTestCase {
    func testSceneDelegateSourceOmitsWindowConstruction() throws {
        let url = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSceneDelegate.swift")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Sources/SolstoneSceneDelegate.swift is missing"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        for forbidden in Self.forbiddenSymbols where text.contains(forbidden) {
            XCTFail("forbidden scene-delegate symbol \(forbidden) in \(url.path)")
        }
    }

    private static let forbiddenSymbols = [
        "UIWindow(",
        "rootViewController",
        "makeKeyAndVisible",
        "var window",
    ]
}
