// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

nonisolated enum ObserverSpoolRootMigrator {
    static let omiAppGroupRootMigrationFlag = "didMigrateOmiObserverRootToAppGroupV1"

    static func migrateSpoolRoot(
        fromLegacyCachesRoot legacyRoot: URL,
        toAppGroupRoot appGroupRoot: URL,
        flagKey: String,
        defaults: UserDefaults? = .standard,
        fileManager: FileManager = .default,
        logger: Logger = Logger(subsystem: "app.solstone.swift", category: "uploader")
    ) -> [String] {
        guard defaults?.bool(forKey: flagKey) != true else { return [] }

        var diagnostics: [String] = []
        guard fileManager.fileExists(atPath: legacyRoot.path) else {
            defaults?.set(true, forKey: flagKey)
            return diagnostics
        }

        do {
            try fileManager.createDirectory(at: appGroupRoot, withIntermediateDirectories: true)
        } catch {
            let diagnostic = "observer spool root migration failed stage=ensure-root"
            diagnostics.append(diagnostic)
            logger.error("\(diagnostic, privacy: .public)")
            return diagnostics
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            let diagnostic = "observer spool root migration failed stage=list-root"
            diagnostics.append(diagnostic)
            logger.error("\(diagnostic, privacy: .public)")
            return diagnostics
        }

        for sourceURL in entries {
            let destinationURL = appGroupRoot.appendingPathComponent(
                sourceURL.lastPathComponent,
                isDirectory: Self.isDirectory(sourceURL, fileManager: fileManager)
            )
            diagnostics.append(contentsOf: Self.migrateRootItem(
                from: sourceURL,
                to: destinationURL,
                label: "item=\(sourceURL.lastPathComponent)",
                fileManager: fileManager,
                logger: logger
            ))
        }

        if diagnostics.isEmpty {
            defaults?.set(true, forKey: flagKey)
        }
        return diagnostics
    }
}

private extension ObserverSpoolRootMigrator {
    nonisolated static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    nonisolated static func migrateRootItem(
        from sourceURL: URL,
        to destinationURL: URL,
        label: String,
        fileManager: FileManager,
        logger: Logger
    ) -> [String] {
        var diagnostics: [String] = []
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                if try self.contentsEqual(sourceURL, destinationURL, fileManager: fileManager) {
                    try fileManager.removeItem(at: sourceURL)
                } else {
                    let diagnostic = "observer spool root migration collision \(label)"
                    diagnostics.append(diagnostic)
                    logger.error("\(diagnostic, privacy: .public)")
                }
                return diagnostics
            }

            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stagingURL = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(".\(destinationURL.lastPathComponent).migrating", isDirectory: self.isDirectory(sourceURL, fileManager: fileManager))
            if fileManager.fileExists(atPath: stagingURL.path) {
                try fileManager.removeItem(at: stagingURL)
            }
            try fileManager.copyItem(at: sourceURL, to: stagingURL)
            guard try self.contentsEqual(sourceURL, stagingURL, fileManager: fileManager) else {
                let diagnostic = "observer spool root migration verify-failed \(label)"
                diagnostics.append(diagnostic)
                logger.error("\(diagnostic, privacy: .public)")
                return diagnostics
            }
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            guard try self.contentsEqual(sourceURL, destinationURL, fileManager: fileManager) else {
                let diagnostic = "observer spool root migration verify-failed \(label)"
                diagnostics.append(diagnostic)
                logger.error("\(diagnostic, privacy: .public)")
                return diagnostics
            }
            try fileManager.removeItem(at: sourceURL)
        } catch {
            let diagnostic = "observer spool root migration failed \(label)"
            diagnostics.append(diagnostic)
            logger.error("\(diagnostic, privacy: .public)")
        }
        return diagnostics
    }

    struct FileSnapshotEntry: Equatable {
        let isDirectory: Bool
        let data: Data?
    }

    nonisolated static func contentsEqual(_ lhs: URL, _ rhs: URL, fileManager: FileManager) throws -> Bool {
        try self.snapshot(lhs, fileManager: fileManager) == self.snapshot(rhs, fileManager: fileManager)
    }

    nonisolated static func snapshot(_ url: URL, fileManager: FileManager) throws -> [String: FileSnapshotEntry] {
        if !self.isDirectory(url, fileManager: fileManager) {
            return [
                "": FileSnapshotEntry(
                    isDirectory: false,
                    data: try Data(contentsOf: url)
                ),
            ]
        }

        var snapshot: [String: FileSnapshotEntry] = ["": FileSnapshotEntry(isDirectory: true, data: nil)]
        let entries = try fileManager.subpathsOfDirectory(atPath: url.path)
        for relativePath in entries.sorted() {
            let entryURL = url.appendingPathComponent(relativePath)
            let isDirectory = self.isDirectory(entryURL, fileManager: fileManager)
            snapshot[relativePath] = FileSnapshotEntry(
                isDirectory: isDirectory,
                data: isDirectory ? nil : try Data(contentsOf: entryURL)
            )
        }
        return snapshot
    }
}
