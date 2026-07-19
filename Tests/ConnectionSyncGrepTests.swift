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

    func testContentViewHasNoOfflineBanner() throws {
        let text = try Self.sourceText("Sources/ContentView.swift")

        for forbidden in ["OfflineBanner", "updateOfflineBannerVisibility", "showOfflineBanner", "offlineSettleTask", "isNetworkSatisfied"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testShareConfirmedActiveTransferCountExcludesStoredRows() throws {
        let text = try Self.sourceText("Sources/ShareImport/ShareTransferHolder.swift")
        let body = try Self.slice(
            in: text,
            from: "var confirmedActiveTransferCount",
            to: "\n\n    var recentErrorCount"
        )

        XCTAssertTrue(body.contains("status.inFlightCount"))
        XCTAssertFalse(body.contains("store.pendingCount"))
        XCTAssertFalse(body.contains("store.failedCount"))
    }

    func testTransferAggregationUsesFourTransportOwnersOnly() throws {
        let text = try Self.sourceText("Sources/UploadReach.swift")
        let countBody = try Self.slice(in: text, from: "func confirmedTransferCount", to: "\n\n@MainActor\nfunc recentBytesTotal")
        let bytesBody = try Self.slice(in: text, from: "func recentBytesTotal", to: "\n\n@MainActor\nfunc uploadInFlight")

        for required in ["mobileSegment.", "omi.", "watch.", "share."] {
            XCTAssertTrue(countBody.contains(required), required)
            XCTAssertTrue(bytesBody.contains(required), required)
        }
        XCTAssertFalse(countBody.contains("observer."))
        XCTAssertFalse(bytesBody.contains("observer."))
    }

    func testShareImportCutoverRemovedLegacyBackgroundUploadMechanics() throws {
        let shareImportText = try [
            Self.sourceText(under: "Sources/ShareImport"),
            Self.sourceText("Sources/Transfer/ShareImportSaveBody.swift"),
        ].joined(separator: "\n")
        for forbidden in [
            "URLSession",
            "NWPathMonitor",
            "droppedItemIDs",
            "maxInFlightPerSource",
            "save.upload",
            "start.upload",
            "ThroughputMeter",
            "ImportQueueMode",
            "ImportQueueSessionDelegate",
            "handleBackgroundURLSessionEvents",
            "finishBackgroundEvents",
            "reconcilePortIfNeeded",
            "retryDelays",
            "maxAttempts",
            "ForTesting",
        ] {
            XCTAssertFalse(shareImportText.contains(forbidden), forbidden)
        }
    }

    func testTransferEngineHasNoPerSourceInFlightCap() throws {
        let sourceText = try Self.sourceText(under: "Sources")

        XCTAssertFalse(sourceText.contains("maxInFlightPerSource"))
    }

    func testRetiredShareUploadIdentifierTokenOnlyAppearsInAppDelegateComment() throws {
        let sourceHits = try Self.sourceFiles()
            .flatMap { file -> [(String, String)] in
                let text = try String(contentsOf: file, encoding: .utf8)
                return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).compactMap { line in
                    line.contains("share-upload") ? (file.path, line) : nil
                }
            }

        XCTAssertEqual(sourceHits.count, 1)
        XCTAssertTrue(sourceHits.first?.0.hasSuffix("Sources/Push/AppDelegate.swift") == true)
        XCTAssertTrue(sourceHits.first?.1.trimmingCharacters(in: .whitespaces).hasPrefix("// A previous app version uploaded shares") == true)
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func sourceText(under relativePath: String) throws -> String {
        try self.sourceFiles(under: relativePath)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private static func sourceFiles(under relativePath: String = "Sources") throws -> [URL] {
        let root = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return try enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true ? url : nil
        }
    }

    private static func slice(in text: String, from startToken: String, to endToken: String) throws -> Substring {
        let start = try XCTUnwrap(text.range(of: startToken))
        let remaining = text[start.lowerBound...]
        let end = try XCTUnwrap(remaining.range(of: endToken))
        return text[start.lowerBound..<end.lowerBound]
    }
}
