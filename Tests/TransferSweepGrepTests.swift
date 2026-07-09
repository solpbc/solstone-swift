// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import XCTest

nonisolated final class TransferSweepGrepTests: XCTestCase {
    func testRetiredImportQueueSourceDirectoryDoesNotExist() {
        let directory = StringLiteralGrepSupport.worktreeRoot()
            .appendingPathComponent("Sources/ImportQueue", isDirectory: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRetiredObserverUploaderTokenDoesNotAppearUnderSources() throws {
        XCTAssertEqual(try self.sourceHits(containing: "ObserverUploader"), [])
    }

    func testRetiredBackgroundSessionIdentifierTokenDoesNotAppearUnderSources() throws {
        XCTAssertEqual(try self.sourceHits(containing: "backgroundSessionIdentifier"), [])
    }

    func testRetiredImportQueueSwiftTokenOnlyAppearsInTransferOutcomeRationaleComments() throws {
        let hits = try self.sourceHits(containing: "ImportQueue.swift")

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits.map(\.relativePath), [
            "Sources/Transfer/TransferOutcome.swift",
            "Sources/Transfer/TransferOutcome.swift",
        ])
        XCTAssertTrue(hits.allSatisfy { $0.trimmedLine.hasPrefix("//") })
        XCTAssertTrue(hits.contains { $0.trimmedLine.hasPrefix("// The old path had an uncounted benign re-drive") })
        XCTAssertTrue(hits.contains { $0.trimmedLine.hasPrefix("// The old background-session path guarded") })
    }

    func testBareImportQueueTokenIsNotRetired() throws {
        // Do not gate bare `ImportQueue`: it is still the live ShareImportStore
        // disk root and also appears in deferred-rename identifiers.
        let shareStore = try Self.sourceText("Sources/ShareImport/ShareImportStore.swift")
        let launchMaintenance = try Self.sourceText("Sources/Background/LaunchMaintenanceCoordinator.swift")
        let shareCoordinator = try Self.sourceText("Sources/ShareImport/ShareImportCoordinator.swift")

        XCTAssertTrue(shareStore.contains(#""ImportQueue""#))
        XCTAssertTrue(launchMaintenance.contains("resumeImportQueue"))
        XCTAssertTrue(shareCoordinator.contains("ShareImportQueueing"))
    }

    private func sourceHits(containing token: String) throws -> [SourceHit] {
        try Self.sourceFiles().flatMap { file -> [SourceHit] in
            let text = try String(contentsOf: file, encoding: .utf8)
            let root = StringLiteralGrepSupport.worktreeRoot()
            let relativePath = file.path.replacingOccurrences(of: root.path + "/", with: "")
            return text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .compactMap { line in
                    line.contains(token)
                        ? SourceHit(relativePath: relativePath, trimmedLine: line.trimmingCharacters(in: .whitespaces))
                        : nil
                }
        }
    }

    private static func sourceText(_ relativePath: String) throws -> String {
        let url = StringLiteralGrepSupport.worktreeRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func sourceFiles() throws -> [URL] {
        try StringLiteralGrepSupport.swiftFiles(
            under: StringLiteralGrepSupport.worktreeRoot().appendingPathComponent("Sources", isDirectory: true)
        ).sorted { $0.path < $1.path }
    }
}

private struct SourceHit: Equatable {
    var relativePath: String
    var trimmedLine: String
}
