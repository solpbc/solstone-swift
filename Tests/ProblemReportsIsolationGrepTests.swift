// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ProblemReportsIsolationGrepTests: XCTestCase {
    func testProblemReportsSourcesDoNotUseNetworkingSymbols() throws {
        let worktree = StringLiteralGrepSupport.worktreeRoot()
        let root = worktree.appendingPathComponent("Sources/ProblemReports")
        var files = try StringLiteralGrepSupport.swiftFiles(under: root)
        files.append(worktree.appendingPathComponent("Sources/UITestSupport/ProblemReportsUITestSeeder.swift"))

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for forbidden in Self.forbiddenSymbols where text.contains(forbidden) {
                XCTFail("forbidden problem reports symbol \(forbidden) in \(file.path)")
            }
        }
    }

    private static let forbiddenSymbols = [
        "URLSession",
        "URLRequest",
        "NWConnection",
        "URLSessionWebSocket",
        "Network.",
        "socket",
    ]
}
