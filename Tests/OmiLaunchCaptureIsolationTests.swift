// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchCaptureIsolationTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureIsolationTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func testLaunchCaptureSiblingIsIgnoredByExistingOmiScanners() async throws {
        let appGroupRoot = self.rootURL.appendingPathComponent("app-group", isDirectory: true)
        let generation = UUID()
        let launchURL = OmiLaunchCaptureFormat.fileURL(
            rootURL: appGroupRoot.appendingPathComponent(OmiLaunchCaptureFormat.rootDirectoryName, isDirectory: true),
            generationID: generation
        )
        try FileManager.default.createDirectory(at: launchURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("launch evidence".utf8).write(to: launchURL)
        let cursorURL = OmiLaunchCaptureCursorFormat.fileURL(
            rootURL: launchURL.deletingLastPathComponent(),
            generationID: generation
        )
        try Data("cursor evidence".utf8).write(to: cursorURL)
        let materializedAudio = launchURL.deletingLastPathComponent()
            .appendingPathComponent("Materialized", isDirectory: true)
            .appendingPathComponent(generation.uuidString, isDirectory: true)
            .appendingPathComponent("\(generation.uuidString.lowercased())-0.m4a", isDirectory: false)
        try FileManager.default.createDirectory(at: materializedAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("materialized audio".utf8).write(to: materializedAudio)
        try Data("materialized envelope".utf8).write(to: OmiPendingHandoffStore.url(for: materializedAudio))
        XCTAssertEqual(launchURL.deletingLastPathComponent().deletingLastPathComponent(), appGroupRoot)
        XCTAssertNotEqual(launchURL.deletingLastPathComponent().lastPathComponent, OmiSegmentWriter.cacheDirectoryName)

        let harness = makeTransferCutoverHarness(
            rootURL: appGroupRoot.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        )
        let suiteName = "OmiLaunchCaptureIsolationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await OmiTransferSpoolMigrator.migrate(
            appGroupRootURL: appGroupRoot,
            legacyCachesRootURL: nil,
            transferEnqueuer: harness.enqueuer,
            diagnosticLog: nil,
            acknowledgeTokens: { _ in },
            registerDispatchHold: { _ in },
            defaults: defaults
        )
        let recovery = await OmiInProgressRecovery.recoverInProgressFiles(
            sessionID: UUID(),
            rootURL: appGroupRoot.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
            transferEnqueuer: harness.enqueuer,
            acknowledgeTokens: { _ in },
            registerDispatchHold: { _ in },
            quarantineRootURL: OmiTransferSpoolMigrator.quarantineRootURL(appGroupRootURL: appGroupRoot),
            diagnosticLog: nil
        )
        XCTAssertEqual(recovery, OmiInProgressRecovery.Result())
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cursorURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: materializedAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: OmiPendingHandoffStore.url(for: materializedAudio).path))
    }

    func testLaunchCaptureSourcesHaveNoUnsafeOrSensitiveDiagnostics() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Omi", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("OmiLaunchCapture") && $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)

        for file in files {
            let sourceText = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(sourceText.contains("print("), file.lastPathComponent)
            XCTAssertFalse(sourceText.contains("NSLog"), file.lastPathComponent)
            XCTAssertFalse(sourceText.contains("nonisolated(unsafe)"), file.lastPathComponent)

            for call in Self.logOrDiagnosticCallBodies(in: sourceText) {
                for sensitive in Self.sensitiveInterpolationTokens {
                    XCTAssertFalse(
                        call.contains("\\(") && call.localizedCaseInsensitiveContains(sensitive),
                        "sensitive diagnostic interpolation \(sensitive) in \(file.lastPathComponent)"
                    )
                }
            }
        }
    }

    private static let sensitiveInterpolationTokens = [
        "url", "path", "payload", "header", "hash", "error", "bytes",
    ]

    private static let logOrDiagnosticPrefixes = [
        ".debug(", ".info(", ".notice(", ".error(", "emitDiagnostic(",
    ]

    private static func logOrDiagnosticCallBodies(in source: String) -> [String] {
        self.logOrDiagnosticPrefixes.flatMap { prefix in
            var calls: [String] = []
            var searchRange = source.startIndex..<source.endIndex
            while let match = source.range(of: prefix, range: searchRange) {
                if let body = self.parenthesizedBody(in: source, openingParenthesis: source.index(before: match.upperBound)) {
                    calls.append(body)
                }
                searchRange = match.upperBound..<source.endIndex
            }
            return calls
        }
    }

    private static func parenthesizedBody(in source: String, openingParenthesis: String.Index) -> String? {
        var depth = 0
        var index = openingParenthesis
        while index < source.endIndex {
            switch source[index] {
            case "(":
                depth += 1
            case ")":
                depth -= 1
                if depth == 0 {
                    return String(source[openingParenthesis...index])
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }
}
