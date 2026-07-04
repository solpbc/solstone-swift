// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import os
import XCTest

nonisolated final class ObserverSpoolRootMigratorTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaultsSuites: [String] = []

    override func setUp() {
        super.setUp()
        self.tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObserverSpoolRootMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for suite in self.defaultsSuites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        self.defaultsSuites = []
        try? FileManager.default.removeItem(at: self.tempDirectory)
        self.tempDirectory = nil
        super.tearDown()
    }

    func testOmiMigrationCleanPassMovesAllLegacyItemsAndSetsFlag() throws {
        let legacyRoot = self.tempDirectory.appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("OmiObserver", isDirectory: true)
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroup", isDirectory: true)
            .appendingPathComponent("OmiObserver", isDirectory: true)
        let defaults = try self.makeDefaults()
        let sessionID = UUID()
        let chunkID = "\(sessionID.uuidString.lowercased())-0"
        let legacyAudio = legacyRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(chunkID).m4a", isDirectory: false)
        let legacySidecar = legacyAudio.deletingPathExtension().appendingPathExtension("json")
        try FileManager.default.createDirectory(at: legacyAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: legacyAudio, options: .atomic)
        try Data("sidecar".utf8).write(to: legacySidecar, options: .atomic)

        let diagnostics = ObserverSpoolRootMigrator.migrateSpoolRoot(
            fromLegacyCachesRoot: legacyRoot,
            toAppGroupRoot: appGroupRoot,
            flagKey: ObserverSpoolRootMigrator.omiAppGroupRootMigrationFlag,
            defaults: defaults,
            logger: self.logger
        )

        XCTAssertEqual(diagnostics, [])
        XCTAssertTrue(defaults.bool(forKey: ObserverSpoolRootMigrator.omiAppGroupRootMigrationFlag))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacySidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appGroupRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(chunkID).m4a", isDirectory: false)
            .path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: appGroupRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(chunkID).json", isDirectory: false)
            .path))
    }

    func testOmiMigrationCollisionLeavesBothCopiesAndDoesNotSetFlag() throws {
        let legacyRoot = self.tempDirectory.appendingPathComponent("LegacyOmiObserver", isDirectory: true)
        let appGroupRoot = self.tempDirectory.appendingPathComponent("AppGroupOmiObserver", isDirectory: true)
        let defaults = try self.makeDefaults()
        let sessionID = UUID()
        let legacyAudio = legacyRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString.lowercased())-0.m4a", isDirectory: false)
        let appGroupAudio = appGroupRoot
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("pending", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString.lowercased())-0.m4a", isDirectory: false)
        try FileManager.default.createDirectory(at: legacyAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appGroupAudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacyAudio, options: .atomic)
        try Data("app-group".utf8).write(to: appGroupAudio, options: .atomic)

        let diagnostics = ObserverSpoolRootMigrator.migrateSpoolRoot(
            fromLegacyCachesRoot: legacyRoot,
            toAppGroupRoot: appGroupRoot,
            flagKey: ObserverSpoolRootMigrator.omiAppGroupRootMigrationFlag,
            defaults: defaults,
            logger: self.logger
        )

        XCTAssertEqual(diagnostics, ["observer spool root migration collision item=\(sessionID.uuidString)"])
        XCTAssertFalse(defaults.bool(forKey: ObserverSpoolRootMigrator.omiAppGroupRootMigrationFlag))
        XCTAssertEqual(try String(contentsOf: legacyAudio, encoding: .utf8), "legacy")
        XCTAssertEqual(try String(contentsOf: appGroupAudio, encoding: .utf8), "app-group")

        let rerunDiagnostics = ObserverSpoolRootMigrator.migrateSpoolRoot(
            fromLegacyCachesRoot: legacyRoot,
            toAppGroupRoot: appGroupRoot,
            flagKey: ObserverSpoolRootMigrator.omiAppGroupRootMigrationFlag,
            defaults: defaults,
            logger: self.logger
        )
        XCTAssertEqual(rerunDiagnostics, diagnostics)
        XCTAssertFalse(defaults.bool(forKey: ObserverSpoolRootMigrator.omiAppGroupRootMigrationFlag))
        XCTAssertEqual(try String(contentsOf: legacyAudio, encoding: .utf8), "legacy")
        XCTAssertEqual(try String(contentsOf: appGroupAudio, encoding: .utf8), "app-group")
    }
}

private extension ObserverSpoolRootMigratorTests {
    var logger: Logger {
        Logger(subsystem: "app.solstone.swift", category: "observer-spool-migration-tests")
    }

    func makeDefaults() throws -> UserDefaults {
        let suite = "ObserverSpoolRootMigratorTests-\(UUID().uuidString)"
        self.defaultsSuites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
