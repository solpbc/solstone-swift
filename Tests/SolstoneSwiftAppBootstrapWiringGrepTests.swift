// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class SolstoneSwiftAppBootstrapWiringGrepTests: XCTestCase {
    func testBootstrapTransferUsesTwoPhaseStaticSeamInOrder() throws {
        let appURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSwiftApp.swift")
        let text = try String(contentsOf: appURL, encoding: .utf8)

        XCTAssertFalse(text.contains("transferEngine.start()"))

        let bootstrapBody = try Self.slice(
            in: text,
            from: "private func bootstrapTransfer() async",
            to: "private func recoverOmiInProgress"
        )
        let seamStart = try XCTUnwrap(bootstrapBody.range(of: "await Self.bootstrapTransfer("))
        let seamCall = bootstrapBody[seamStart.lowerBound...]

        let reconcileIndex = try XCTUnwrap(seamCall.range(of: "reconcile:")?.lowerBound)
        let enableIndex = try XCTUnwrap(seamCall.range(of: "enableDispatch:")?.lowerBound)
        XCTAssertLessThan(reconcileIndex, enableIndex)
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
