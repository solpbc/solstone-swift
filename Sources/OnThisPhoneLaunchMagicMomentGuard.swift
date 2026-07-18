// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated func shouldMarkMagicMomentFirstSeenOnLaunch(
    magicMomentFirstSeen: Bool,
    hasExistingOnThisPhoneItems: Bool,
    isUITest: Bool
) -> Bool {
    !isUITest && !magicMomentFirstSeen && hasExistingOnThisPhoneItems
}

@MainActor
enum OnThisPhoneLaunchMagicMomentStoreProbe {
    static func hasExistingOnThisPhoneItems(
        mobileSegmentStore: MobileSegmentStore,
        appGroupRootURL: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        if self.hasMobileSegmentItems(store: mobileSegmentStore) {
            return true
        }
        guard let appGroupRootURL else {
            return false
        }
        if self.hasShareImportItems(appGroupRootURL: appGroupRootURL, fileManager: fileManager) {
            return true
        }
        // Omi/watch enqueue directly to transfer at OmiSegmentWriter.swift:209 and WatchSegmentDrain.swift:113.
        return self.hasTransferSpoolEntries(appGroupRootURL: appGroupRootURL, fileManager: fileManager)
    }

    private static func hasMobileSegmentItems(store: MobileSegmentStore) -> Bool {
        do {
            for lifecycle in [MobileSegmentLifecycle.active, .pending, .failed] {
                let items = try store.list(lifecycle)
                if !items.isEmpty {
                    return true
                }
            }
            return false
        } catch {
            return true
        }
    }

    private static func hasShareImportItems(appGroupRootURL: URL, fileManager: FileManager) -> Bool {
        let rootURL = appGroupRootURL.appendingPathComponent("ImportQueue", isDirectory: true)
        if self.directoryContainsEntries(
            rootURL.appendingPathComponent("pending", isDirectory: true),
            fileManager: fileManager
        ) {
            return true
        }
        if self.directoryContainsEntries(
            rootURL.appendingPathComponent("failed", isDirectory: true),
            fileManager: fileManager
        ) {
            return true
        }
        return self.shareLedgerHasEntries(
            rootURL.appendingPathComponent("ledger.json", isDirectory: false),
            fileManager: fileManager
        )
    }

    private static func hasTransferSpoolEntries(appGroupRootURL: URL, fileManager: FileManager) -> Bool {
        let rootURL = appGroupRootURL.appendingPathComponent(TransferSpool.rootDirectoryName, isDirectory: true)
        return [
            TransferSpool.stagingDirectoryName,
            TransferSpool.queuedDirectoryName,
            TransferSpool.attentionDirectoryName,
        ].contains { directoryName in
            self.directoryContainsEntries(
                rootURL.appendingPathComponent(directoryName, isDirectory: true),
                fileManager: fileManager
            )
        }
    }

    private static func directoryContainsEntries(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        guard let entries = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return true
        }
        return !entries.isEmpty
    }

    private static func shareLedgerHasEntries(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return false
        }
        if let ledger = try? JSONDecoder().decode([String: ShareImportStore.LedgerEntry].self, from: data) {
            return !ledger.isEmpty
        }
        return true
    }
}
