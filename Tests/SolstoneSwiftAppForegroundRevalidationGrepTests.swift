// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SolstoneSwiftAppForegroundRevalidationGrepTests: XCTestCase {
    func testBothForegroundConnectedSitesRouteThroughRevalidationHelper() throws {
        let appURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSwiftApp.swift")
        let text = try String(contentsOf: appURL, encoding: .utf8)

        let coldBody = try Self.slice(
            in: text,
            from: "// cold-launch-into-connected:",
            to: ".onChange(of: self.scenePhase)"
        )
        XCTAssertTrue(coldBody.contains("Self.revalidateThenRequestDrain("))
        XCTAssertFalse(coldBody.contains("Task { await self.foregroundDrainGate.requestDrain() }"))

        let activeBody = try Self.slice(
            in: text,
            from: "case .connected:",
            to: "case .connecting:"
        )
        XCTAssertTrue(activeBody.contains("Self.revalidateThenRequestDrain("))
        XCTAssertFalse(activeBody.contains("Task { await self.foregroundDrainGate.requestDrain() }"))
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
