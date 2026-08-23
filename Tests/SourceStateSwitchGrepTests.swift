// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SourceStateSwitchGrepTests: XCTestCase {
    func testNewWatchSourceStatesHaveDeliberatePrivateSwitchValues() throws {
        let root = Self.worktreeRoot()
        let row = try Self.contents(root.appendingPathComponent("Sources/SourceRowView.swift"))
        let shell = try Self.contents(root.appendingPathComponent("Sources/RootShellView.swift"))
        let detail = try Self.contents(root.appendingPathComponent("Sources/SourceDetailView.swift"))

        XCTAssertTrue(row.contains("case .active, .enrolling, .readyToSetUp:"))
        XCTAssertTrue(row.contains("case .off, .paused, .checking:"))
        XCTAssertTrue(row.contains("case .readyToSetUp:\n            self.colorScheme == .dark ? .primary : .textOrangeAA"))
        XCTAssertTrue(shell.contains("case .off, .readyToSetUp, .checking, .paused:"))
        XCTAssertTrue(detail.contains("case .off, .enrolling, .readyToSetUp, .checking, .needsAttention:"))
    }
}

private extension SourceStateSwitchGrepTests {
    static func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    static func worktreeRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
