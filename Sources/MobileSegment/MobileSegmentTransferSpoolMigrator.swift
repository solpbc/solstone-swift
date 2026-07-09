// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let mobileSegmentTransferMigrationLog = Logger(subsystem: "app.solstone.swift", category: "mobile-segment-transfer-migration")

@MainActor
enum MobileSegmentTransferSpoolMigrator {
    static let flagKey = "didMigrateMobileSegmentObserverToTransferV1"
    static let quarantineRelativePath = "TransferQuarantine/MobileSegmentObserver"

    static func quarantineRootURL(appGroupRootURL: URL) -> URL {
        appGroupRootURL.appendingPathComponent(self.quarantineRelativePath, isDirectory: true)
    }

    static func migrate(
        appGroupRootURL: URL,
        observerCacheRootURL: URL?,
        store: MobileSegmentStore,
        diagnosticLog: DiagnosticLog?,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) async {
        guard defaults.bool(forKey: self.flagKey) == false else { return }

        let quarantineRoot = self.quarantineRootURL(appGroupRootURL: appGroupRootURL)
        var unresolved = 0
        do {
            try store.ensureRoot()
        } catch {
            self.emit(diagnosticLog, detail: "source=\(store.rootURL.path) reason=ensure-root failed")
            return
        }

        unresolved += self.reclassifyFailedSegments(
            store: store,
            quarantineRootURL: quarantineRoot,
            diagnosticLog: diagnosticLog,
            fileManager: fileManager
        )

        if let observerCacheRootURL, fileManager.fileExists(atPath: observerCacheRootURL.path) {
            unresolved += self.deleteBackgroundBodies(
                observerCacheRootURL: observerCacheRootURL,
                diagnosticLog: diagnosticLog,
                fileManager: fileManager
            )
            unresolved += self.quarantineObserverResidue(
                observerCacheRootURL: observerCacheRootURL,
                quarantineRootURL: quarantineRoot,
                diagnosticLog: diagnosticLog,
                fileManager: fileManager
            )
            if unresolved == 0 {
                do {
                    try fileManager.removeItem(at: observerCacheRootURL)
                } catch {
                    unresolved += 1
                    self.emit(diagnosticLog, detail: "source=\(observerCacheRootURL.path) reason=remove-root failed")
                }
            }
        }

        if unresolved == 0 {
            defaults.set(true, forKey: self.flagKey)
        }
    }

    static func quarantine(
        _ sourceURL: URL,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        reason: String,
        fileManager: FileManager = .default
    ) -> Int {
        do {
            try fileManager.createDirectory(at: quarantineRootURL, withIntermediateDirectories: true)
            let destination = quarantineRootURL
                .appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)", isDirectory: false)
            try fileManager.moveItem(at: sourceURL, to: destination)
            self.emit(
                diagnosticLog,
                detail: "source=\(sourceURL.path) quarantine=\(destination.path) reason=\(reason)"
            )
            return 1
        } catch {
            self.emit(diagnosticLog, detail: "source=\(sourceURL.path) reason=quarantine failed")
            mobileSegmentTransferMigrationLog.error("mobile segment quarantine failed source=\(sourceURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return 0
        }
    }
}

private extension MobileSegmentTransferSpoolMigrator {
    static let finalizeFailureStages: Set<String> = [
        "source-finalize",
        "segment-finalize",
        "schedule-gate",
        "reconcile",
    ]

    static func reclassifyFailedSegments(
        store: MobileSegmentStore,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        fileManager: FileManager
    ) -> Int {
        let failed: [URL]
        do {
            failed = try store.list(.failed)
        } catch {
            self.emit(diagnosticLog, detail: "source=\(store.directoryURL(.failed).path) reason=list failed")
            return 1
        }

        var unresolved = 0
        for directory in failed {
            guard let segmentID = UUID(uuidString: directory.lastPathComponent) else { continue }
            let manifest: MobileSegmentManifest
            do {
                manifest = try store.readManifest(in: directory)
            } catch {
                let quarantined = self.quarantine(
                    directory,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "manifest unreadable",
                    fileManager: fileManager
                )
                if quarantined == 0 {
                    unresolved += 1
                }
                continue
            }

            let stage = store.loadFailure(in: directory)?.stage
            if let stage, self.finalizeFailureStages.contains(stage) {
                continue
            }

            do {
                var updated = manifest
                updated.upload = .pending
                updated.updatedAt = Date()
                try store.writeManifest(updated, in: directory)
                try store.removeFailure(in: directory)
                _ = try store.move(segmentID: segmentID, from: .failed, to: .pending)
            } catch {
                unresolved += 1
                self.emit(diagnosticLog, detail: "source=\(directory.path) reason=reclassify failed")
                mobileSegmentTransferMigrationLog.error("mobile segment failed-dir reclassify failed source=\(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return unresolved
    }

    static func deleteBackgroundBodies(
        observerCacheRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        fileManager: FileManager
    ) -> Int {
        let directory = observerCacheRootURL
            .appendingPathComponent("MobileSegmentBackgroundBodies", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        do {
            try fileManager.removeItem(at: directory)
            return 0
        } catch {
            self.emit(diagnosticLog, detail: "source=\(directory.path) reason=remove failed")
            return 1
        }
    }

    static func quarantineObserverResidue(
        observerCacheRootURL: URL,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        fileManager: FileManager
    ) -> Int {
        guard let enumerator = fileManager.enumerator(
            at: observerCacheRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            self.emit(diagnosticLog, detail: "source=\(observerCacheRootURL.path) reason=list failed")
            return 1
        }

        var unresolved = 0
        for case let audioURL as URL in enumerator where audioURL.pathExtension == "m4a" {
            guard !Task.isCancelled else { return unresolved + 1 }
            guard let byteCount = OmiInProgressRecovery.byteCountIfAvailable(at: audioURL, fileManager: fileManager) else {
                let quarantined = self.quarantine(
                    audioURL,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "size unavailable",
                    fileManager: fileManager
                )
                if quarantined == 0 {
                    unresolved += 1
                }
                continue
            }
            if byteCount == 0 {
                do {
                    try fileManager.removeItem(at: audioURL)
                } catch {
                    unresolved += 1
                    self.emit(diagnosticLog, detail: "source=\(audioURL.path) reason=zero-byte discard failed")
                }
                continue
            }
            let reason = self.canProbe(audioURL, fileManager: fileManager) ? "stray chunk" : "probe failed"
            let quarantined = self.quarantine(
                audioURL,
                quarantineRootURL: quarantineRootURL,
                diagnosticLog: diagnosticLog,
                reason: reason,
                fileManager: fileManager
            )
            if quarantined == 0 {
                unresolved += 1
            } else {
                let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("json")
                let uploadURL = audioURL.deletingPathExtension().appendingPathExtension("upload")
                let failureURL = audioURL.deletingPathExtension().appendingPathExtension("failure")
                try? fileManager.removeItem(at: sidecarURL)
                try? fileManager.removeItem(at: uploadURL)
                try? fileManager.removeItem(at: failureURL)
            }
        }
        return unresolved
    }

    static func canProbe(_ audioURL: URL, fileManager: FileManager) -> Bool {
        let chunkID = audioURL.deletingPathExtension().lastPathComponent
        let sessionIDString = audioURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .lastPathComponent
        guard let sessionID = UUID(uuidString: sessionIDString) else { return false }
        return OmiInProgressRecovery.rebuildSidecar(
            audioURL: audioURL,
            chunkID: chunkID,
            sessionID: sessionID,
            fileManager: fileManager
        ) != nil
    }

    static func emit(_ diagnosticLog: DiagnosticLog?, detail: String) {
        diagnosticLog?.append(category: .upload, severity: .warning, message: "needs attention", detail: detail)
    }
}
