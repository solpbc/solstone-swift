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

    func testStatusPaneDoesNotUseRetiredStandingHelpers() throws {
        let text = try Self.sourceText("Sources/Home/StatusPane.swift")

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

    func testRefreshFromInputChangeHasProductionSourceCallSite() throws {
        let hits = try Self.sourceLineHits(containing: Self.refreshFromInputChangeCallNeedle, under: "Sources")
        XCTAssertFalse(hits.isEmpty, "\(Self.refreshFromInputChangeCallNeedle) was not found in Sources")

        let productionHits = hits.filter { !$0.isInsideDebugRegion }
        XCTAssertFalse(
            productionHits.isEmpty,
            "\(Self.refreshFromInputChangeCallNeedle) only appeared under DEBUG: \(Self.describe(hits))"
        )
        XCTAssertTrue(
            productionHits.contains { $0.relativePath == "Sources/SolstoneSwiftApp.swift" },
            "expected production foreground call site in Sources/SolstoneSwiftApp.swift, got \(Self.describe(productionHits))"
        )
    }

    func testRefreshFromInputChangeScannerHandlesPreprocessorAndComments() {
        let fixtures: [(String, String, Bool)] = [
            (
                "debug branch",
                """
                #if DEBUG
                connectionSyncModel.refreshFromInputChange()
                #endif
                """,
                false
            ),
            (
                "debug else branch",
                """
                #if DEBUG
                integrationOnly()
                #else
                connectionSyncModel.refreshFromInputChange()
                #endif
                """,
                true
            ),
            (
                "inverted debug else branch",
                """
                #if !DEBUG
                productionOnly()
                #else
                connectionSyncModel.refreshFromInputChange()
                #endif
                """,
                false
            ),
            (
                "nested under outer debug",
                """
                #if DEBUG
                #if canImport(UIKit)
                connectionSyncModel.refreshFromInputChange()
                #else
                connectionSyncModel.refreshFromInputChange()
                #endif
                #endif
                """,
                false
            ),
            (
                "line comment",
                """
                // connectionSyncModel.refreshFromInputChange()
                """,
                false
            ),
            (
                "bare symbol",
                """
                refreshFromInputChange()
                """,
                false
            ),
            (
                "simulator debug branch",
                """
                #if DEBUG && targetEnvironment(simulator)
                connectionSyncModel.refreshFromInputChange()
                #endif
                """,
                false
            ),
        ]

        for (name, source, expectsProductionHit) in fixtures {
            let hits = Self.sourceLineHits(
                containing: Self.refreshFromInputChangeCallNeedle,
                in: source,
                relativePath: "\(name).swift"
            )
            XCTAssertEqual(
                hits.contains { !$0.isInsideDebugRegion },
                expectsProductionHit,
                name
            )
        }
    }

    private static let refreshFromInputChangeCallNeedle = "connectionSyncModel.refreshFromInputChange("

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

    private struct SourceLineHit {
        let relativePath: String
        let lineNumber: Int
        let isInsideDebugRegion: Bool
    }

    private enum DebugBranch {
        case debug
        case nonDebug
        case unrelated

        var inverted: DebugBranch {
            switch self {
            case .debug:
                return .nonDebug
            case .nonDebug:
                return .debug
            case .unrelated:
                return .unrelated
            }
        }

        var isDebug: Bool {
            self == .debug
        }
    }

    private struct DebugFrame {
        let parentIsInsideDebugRegion: Bool
        var branch: DebugBranch

        var isInsideDebugRegion: Bool {
            self.parentIsInsideDebugRegion || self.branch.isDebug
        }
    }

    private static func sourceLineHits(
        containing needle: String,
        under relativePath: String
    ) throws -> [SourceLineHit] {
        let worktree = StringLiteralGrepSupport.worktreeRoot()
        return try self.sourceFiles(under: relativePath).flatMap { file -> [SourceLineHit] in
            let text = try String(contentsOf: file, encoding: .utf8)
            let relativeFilePath = self.relativePath(for: file, under: worktree)
            return self.sourceLineHits(containing: needle, in: text, relativePath: relativeFilePath)
        }
    }

    private static func sourceLineHits(
        containing needle: String,
        in text: String,
        relativePath: String
    ) -> [SourceLineHit] {
        var debugStack: [DebugFrame] = []
        var hits: [SourceLineHit] = []

        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if self.isIfDirective(trimmed) {
                debugStack.append(DebugFrame(
                    parentIsInsideDebugRegion: self.isInsideDebugRegion(debugStack),
                    branch: self.debugBranch(for: trimmed)
                ))
            } else if self.isElseIfDirective(trimmed), !debugStack.isEmpty {
                debugStack[debugStack.count - 1].branch = self.debugBranch(for: trimmed)
            } else if self.isElseDirective(trimmed), !debugStack.isEmpty {
                debugStack[debugStack.count - 1].branch = debugStack[debugStack.count - 1].branch.inverted
            } else if self.isEndIfDirective(trimmed), !debugStack.isEmpty {
                _ = debugStack.removeLast()
            }

            if self.codeBeforeLineComment(in: line).range(of: needle) != nil {
                hits.append(SourceLineHit(
                    relativePath: relativePath,
                    lineNumber: offset + 1,
                    isInsideDebugRegion: self.isInsideDebugRegion(debugStack)
                ))
            }
        }

        return hits
    }

    private static func isInsideDebugRegion(_ debugStack: [DebugFrame]) -> Bool {
        debugStack.last?.isInsideDebugRegion == true
    }

    private static func isIfDirective(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#if ")
    }

    private static func isElseIfDirective(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("#elseif ")
    }

    private static func isElseDirective(_ trimmed: String) -> Bool {
        trimmed == "#else" || trimmed.hasPrefix("#else ")
    }

    private static func isEndIfDirective(_ trimmed: String) -> Bool {
        trimmed == "#endif" || trimmed.hasPrefix("#endif ")
    }

    private static func debugBranch(for trimmed: String) -> DebugBranch {
        let directive: String
        if trimmed.hasPrefix("#elseif ") {
            directive = "#elseif"
        } else if trimmed.hasPrefix("#if ") {
            directive = "#if"
        } else {
            return .unrelated
        }
        let condition = trimmed.dropFirst(directive.count).trimmingCharacters(in: .whitespaces)
        if condition.hasPrefix("!") {
            let inverted = condition.dropFirst().trimmingCharacters(in: .whitespaces)
            return self.hasLeadingDebugToken(inverted) ? .nonDebug : .unrelated
        }
        return self.hasLeadingDebugToken(condition) ? .debug : .unrelated
    }

    private static func hasLeadingDebugToken(_ condition: String) -> Bool {
        guard condition.hasPrefix("DEBUG") else { return false }
        let suffix = condition.dropFirst("DEBUG".count)
        guard let first = suffix.first else { return true }
        return !first.isLetter && !first.isNumber && first != "_"
    }

    private static func codeBeforeLineComment(in line: String) -> Substring {
        guard let comment = line.range(of: "//") else { return line[...] }
        return line[..<comment.lowerBound]
    }

    private static func relativePath(for file: URL, under worktree: URL) -> String {
        let root = worktree.path
        let path = file.path
        guard path.hasPrefix(root + "/") else { return path }
        return String(path.dropFirst(root.count + 1))
    }

    private static func describe(_ hits: [SourceLineHit]) -> String {
        hits.map { "\($0.relativePath):\($0.lineNumber)" }.joined(separator: ", ")
    }
}
