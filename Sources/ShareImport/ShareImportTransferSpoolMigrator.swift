// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let shareImportMigrationLog = Logger(subsystem: "app.solstone.swift", category: "share-import-transfer-migration")

@MainActor
enum ShareImportTransferSpoolMigrator {
    static let flagKey = "didMigrateShareImportToTransferV1"
    static let quarantineRelativePath = "TransferQuarantine/ShareImport"

    static func quarantineRootURL(appGroupRootURL: URL) -> URL {
        appGroupRootURL.appendingPathComponent(self.quarantineRelativePath, isDirectory: true)
    }

    static func migrate(
        appGroupRootURL: URL,
        store: ShareImportStore,
        transferEngine: TransferEngine,
        diagnosticLog: DiagnosticLog?,
        defaults: UserDefaults = .standard
    ) async {
        guard defaults.bool(forKey: self.flagKey) == false else { return }
        let quarantineRoot = self.quarantineRootURL(appGroupRootURL: appGroupRootURL)
        let unresolved = await store.adoptToTransfer(
            engine: transferEngine,
            diagnosticLog: diagnosticLog,
            quarantineRootURL: quarantineRoot
        )
        if unresolved == 0 {
            defaults.set(true, forKey: self.flagKey)
        } else {
            let detail = "source=\(store.cacheRootURL.path) unresolved=\(unresolved)"
            diagnosticLog?.append(category: .upload, severity: .warning, message: "needs attention", detail: detail)
            shareImportMigrationLog.error("share import migration unresolved \(unresolved, privacy: .public)")
        }
    }
}
