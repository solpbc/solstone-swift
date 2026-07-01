// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class ConnectionSyncGrepTests: XCTestCase {
    func testRootShellHomeStateNoLongerReadsTunnelConnected() throws {
        let text = try Self.sourceText("Sources/RootShellView.swift")
        let body = try Self.slice(in: text, from: "private var dayHomeJournalState", to: "\n    private func apply")

        XCTAssertTrue(body.contains("connectionSyncModel.status"))
        XCTAssertFalse(body.contains("tunnelManager.state.isConnected"))
    }

    func testMoreViewStatusDoesNotUseRetiredStandingHelpers() throws {
        let text = try Self.sourceText("Sources/MoreView.swift")

        for forbidden in ["standingHealth", "standingSegmentReach", "standingSyncLine", "uploadReach"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testDiagnosticsLifecycleStatusDoesNotUseRetiredStandingHelpers() throws {
        let text = try Self.sourceText("Sources/Diagnostics/DiagnosticsView.swift")
        let body = try Self.slice(
            in: text,
            from: "private func lifecycleSection",
            to: "\n    private var reconnectSection"
        )

        for forbidden in ["standingHealth", "standingSyncLine", "standingSegmentReach"] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }
    }

    func testContentViewOfflineBannerUsesConnectionSyncModelDebounce() throws {
        let text = try Self.sourceText("Sources/ContentView.swift")

        XCTAssertTrue(text.contains("connectionSyncModel.status == .offline"))
        for forbidden in ["updateOfflineBannerVisibility", "showOfflineBanner", "offlineSettleTask", "isNetworkSatisfied"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testObserverUploaderConfirmedActiveTransferCountExcludesOptimisticSets() throws {
        let text = try Self.sourceText("Sources/Observer/ObserverUploader.swift")
        let body = try Self.slice(
            in: text,
            from: "var confirmedActiveTransferCount",
            to: "\n\n    @ObservationIgnored private(set) var fullRecountCount"
        )

        XCTAssertTrue(body.contains("activeTasksByTaskID.count"))
        XCTAssertTrue(body.contains("mobileSegmentTaskIDBySegmentID.count"))
        for forbidden in [
            "retryTasksByChunkID",
            "schedulingChunkIDs",
            "mobileSegmentRetryTasksBySegmentID",
            "mobileSegmentSchedulingIDs",
        ] {
            XCTAssertFalse(body.contains(forbidden), forbidden)
        }
    }

    func testImportQueueConfirmedActiveTransferCountExcludesOptimisticSets() throws {
        let text = try Self.sourceText("Sources/ImportQueue/ImportQueue.swift")
        let body = try Self.slice(
            in: text,
            from: "var confirmedActiveTransferCount",
            to: "\n\n    @ObservationIgnored private let fileManager"
        )

        XCTAssertTrue(body.contains("uploadTaskByItemID.count"))
        XCTAssertFalse(body.contains("retryTasksByItemID"))
        XCTAssertFalse(body.contains("schedulingItemIDs"))
    }

    func testTransferAggregationUsesFourTransportOwnersOnly() throws {
        let text = try Self.sourceText("Sources/UploadReach.swift")
        let countBody = try Self.slice(in: text, from: "func confirmedTransferCount", to: "\n\n@MainActor\nfunc recentBytesTotal")
        let bytesBody = try Self.slice(in: text, from: "func recentBytesTotal", to: "\n\n@MainActor\nfunc uploadInFlight")

        for required in ["observer.", "omi.", "watch.", "importQueue."] {
            XCTAssertTrue(countBody.contains(required), required)
            XCTAssertTrue(bytesBody.contains(required), required)
        }
        XCTAssertFalse(countBody.contains("mobileSegment"))
        XCTAssertFalse(bytesBody.contains("mobileSegment"))
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
