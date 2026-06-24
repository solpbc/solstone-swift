// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class OmiSourceConnectionEdgeGrepTests: XCTestCase {
    func testAudioSuccessEdgesRecoverThroughHelperOnly() throws {
        let managerURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Omi/OmiSourceManager.swift")
        let text = try String(contentsOf: managerURL, encoding: .utf8)

        XCTAssertTrue(text.contains("recoveredConnectionState"))

        let notificationBody = try Self.functionSlice(
            named: "handleUpdatedNotificationState",
            in: text
        )
        let audioBody = try Self.functionSlice(
            named: "handleAudioData",
            in: text
        )

        XCTAssertFalse(notificationBody.contains("connectionState = .connected"))
        XCTAssertFalse(audioBody.contains("connectionState = .connected"))
    }

    private static func functionSlice(named name: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "func \(name)"))
        let remaining = text[start.upperBound...]
        let end = try XCTUnwrap(remaining.range(of: "\n    func "))
        return text[start.lowerBound..<end.lowerBound]
    }
}
