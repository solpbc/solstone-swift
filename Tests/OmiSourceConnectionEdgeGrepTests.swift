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

    func testDisconnectFinalizesOpenChunkBeforeReconnectDecision() throws {
        let managerURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/Omi/OmiSourceManager.swift")
        let text = try String(contentsOf: managerURL, encoding: .utf8)
        let body = try Self.functionSlice(named: "handleDisconnected", in: text)

        let finalize = try XCTUnwrap(body.range(of: "await self.omiSegmentWriter?.finalizeOpenChunk()"))
        let decision = try XCTUnwrap(body.range(of: "OmiSourceLogic.reconnectDecision"))
        XCTAssertLessThan(
            body.distance(from: body.startIndex, to: finalize.lowerBound),
            body.distance(from: body.startIndex, to: decision.lowerBound)
        )
    }

    func testBackgroundFinalizesOmiBeforeDrainCoordinatorRuns() throws {
        let appURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSwiftApp.swift")
        let text = try String(contentsOf: appURL, encoding: .utf8)
        let backgroundStart = try XCTUnwrap(text.range(of: "case .background:"))
        let backgroundBody = text[backgroundStart.lowerBound...]

        let finalize = try XCTUnwrap(backgroundBody.range(of: "finalizeOpenChunkForBackground"))
        let coordinator = try XCTUnwrap(backgroundBody.range(of: "BackgroundDrainCoordinator("))
        let awaitFinalize = try XCTUnwrap(backgroundBody.range(of: "await omiFinalizeTask.value"))
        let runCoordinator = try XCTUnwrap(backgroundBody.range(of: "await coordinator.run()"))
        XCTAssertLessThan(
            backgroundBody.distance(from: backgroundBody.startIndex, to: finalize.lowerBound),
            backgroundBody.distance(from: backgroundBody.startIndex, to: coordinator.lowerBound)
        )
        XCTAssertLessThan(
            backgroundBody.distance(from: backgroundBody.startIndex, to: awaitFinalize.lowerBound),
            backgroundBody.distance(from: backgroundBody.startIndex, to: runCoordinator.lowerBound)
        )
    }

    func testOmiTransferConstructionAndMigrationUseCutoverPath() throws {
        let appURL = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/SolstoneSwiftApp.swift")
        let text = try String(contentsOf: appURL, encoding: .utf8)
        let transferEnqueuer = try XCTUnwrap(text.range(of: "let transferEnqueuer = ObserverAudioTransferEnqueuer"))
        let writer = try XCTUnwrap(text.range(of: "OmiSegmentWriter(transferEnqueuer: transferEnqueuer"))
        XCTAssertLessThan(
            text.distance(from: text.startIndex, to: transferEnqueuer.lowerBound),
            text.distance(from: text.startIndex, to: writer.lowerBound)
        )
        let migration = try XCTUnwrap(text.range(of: "OmiTransferSpoolMigrator.migrate"))
        let recovery = try XCTUnwrap(text.range(of: "recoverOmiInProgress"))
        XCTAssertLessThan(text.distance(from: text.startIndex, to: migration.lowerBound), text.distance(from: text.startIndex, to: recovery.lowerBound))
        XCTAssertFalse(text.contains("didMigrateObserverRootToAppGroupV1"))
    }

    private static func functionSlice(named name: String, in text: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: "func \(name)"))
        let remaining = text[start.upperBound...]
        let end = try XCTUnwrap(remaining.range(of: "\n    func "))
        return text[start.lowerBound..<end.lowerBound]
    }
}
