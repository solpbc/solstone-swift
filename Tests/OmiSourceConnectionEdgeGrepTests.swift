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

    func testRestoreHandlerRoutesThroughCodecGatedAction() throws {
        let managerURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Omi/OmiSourceManager.swift")
        let text = try String(contentsOf: managerURL, encoding: .utf8)
        let restoreBody = try Self.functionSlice(named: "handleRestoredPeripheral", in: text)

        XCTAssertTrue(restoreBody.contains("cacheRestoredCharacteristics"))
        XCTAssertTrue(restoreBody.contains("codec: self.codec"))
        XCTAssertTrue(restoreBody.contains("case .readCodec"))
    }

    func testWriterFaultEscalationIsWiredThroughDerivedState() throws {
        let root = StringLiteralGrepSupport.worktreeRoot()
        let appText = try String(
            contentsOf: root.appendingPathComponent("Sources/SolstoneSwiftApp.swift"),
            encoding: .utf8
        )
        let managerText = try String(
            contentsOf: root.appendingPathComponent("Sources/Omi/OmiSourceManager.swift"),
            encoding: .utf8
        )
        let noteBody = try Self.functionSlice(named: "noteWriterFault", in: managerText)
        let audioBody = try Self.functionSlice(named: "handleAudioData", in: managerText)

        XCTAssertTrue(appText.contains("onWriterFault"))
        XCTAssertTrue(noteBody.contains("writerFaulted = true"))
        XCTAssertFalse(audioBody.contains("connectionState = .needsAttention(.audioUnavailable)"))
    }

    private static func functionSlice(named name: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "func \(name)"))
        let remaining = text[start.upperBound...]
        let end = try XCTUnwrap(remaining.range(of: "\n    func "))
        return text[start.lowerBound..<end.lowerBound]
    }
}
