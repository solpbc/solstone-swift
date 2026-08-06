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
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("print("), file.lastPathComponent)
            XCTAssertFalse(text.contains("NSLog"), file.lastPathComponent)
            XCTAssertFalse(text.contains("nonisolated(unsafe)"), file.lastPathComponent)
        }

        let recoveryText = try String(
            contentsOf: root.appendingPathComponent("OmiLaunchCaptureRecovery.swift"),
            encoding: .utf8
        )
        let logLine = try XCTUnwrap(recoveryText.split(separator: "\n").first { $0.contains("launch capture recovery boundary") })
        XCTAssertFalse(logLine.contains("fileURL"))
        XCTAssertFalse(logLine.contains("path"))
        XCTAssertFalse(logLine.contains("payload"))
    }
}
