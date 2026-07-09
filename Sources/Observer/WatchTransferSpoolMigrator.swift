// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let watchTransferMigrationLog = Logger(subsystem: "app.solstone.swift", category: "watch-transfer-migration")

@MainActor
enum WatchTransferSpoolMigrator {
    static let legacyCacheDirectoryName = "WatchObserver"
    static let flagKey = "didMigrateWatchObserverToTransferV1"
    static let quarantineRelativePath = "TransferQuarantine/WatchObserver"

    static func quarantineRootURL(appGroupRootURL: URL) -> URL {
        appGroupRootURL.appendingPathComponent(self.quarantineRelativePath, isDirectory: true)
    }

    static func migrate(
        appGroupRootURL: URL,
        legacyRootURL: URL,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        diagnosticLog: DiagnosticLog?,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) async {
        guard defaults.bool(forKey: self.flagKey) == false else { return }
        guard fileManager.fileExists(atPath: legacyRootURL.path) else {
            defaults.set(true, forKey: self.flagKey)
            return
        }

        let quarantineRoot = self.quarantineRootURL(appGroupRootURL: appGroupRootURL)
        var unresolved = 0
        let roots: [URL]
        do {
            roots = try self.migrationRoots(legacyRootURL: legacyRootURL, fileManager: fileManager)
        } catch {
            self.emit(diagnosticLog, detail: "source=\(legacyRootURL.path) reason=list failed")
            return
        }
        for root in roots {
            for directoryName in ["pending", "failed"] {
                let directory = root.appendingPathComponent(directoryName, isDirectory: true)
                guard fileManager.fileExists(atPath: directory.path) else { continue }
                unresolved += await self.migrateDirectory(
                    directoryURL: directory,
                    transferEnqueuer: transferEnqueuer,
                    quarantineRootURL: quarantineRoot,
                    diagnosticLog: diagnosticLog,
                    fileManager: fileManager
                )
            }
        }

        if unresolved == 0 {
            defaults.set(true, forKey: self.flagKey)
            try? fileManager.removeItem(at: legacyRootURL)
        }
    }
}

private extension WatchTransferSpoolMigrator {
    static func migrationRoots(legacyRootURL: URL, fileManager: FileManager) throws -> [URL] {
        var roots = [legacyRootURL]
        let entries = try fileManager.contentsOfDirectory(
            at: legacyRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries where self.isDirectory(entry) && UUID(uuidString: entry.lastPathComponent) != nil {
            roots.append(entry)
        }
        return roots
    }

    static func migrateDirectory(
        directoryURL: URL,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        fileManager: FileManager
    ) async -> Int {
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            self.emit(diagnosticLog, detail: "source=\(directoryURL.path) reason=list failed")
            return 1
        }

        var unresolved = 0
        for audioURL in entries where audioURL.pathExtension == "m4a" {
            let chunkID = audioURL.deletingPathExtension().lastPathComponent
            let sidecarURL = directoryURL.appendingPathComponent("\(chunkID).json", isDirectory: false)
            guard let sidecar = self.loadSidecar(sidecarURL, fileManager: fileManager) else {
                let quarantined = self.quarantine(
                    audioURL,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "sidecar unavailable",
                    fileManager: fileManager
                )
                if quarantined == 0 {
                    unresolved += 1
                } else {
                    try? fileManager.removeItem(at: sidecarURL)
                    try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).upload", isDirectory: false))
                    try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).failure", isDirectory: false))
                }
                continue
            }

            do {
                let tempDirectory = try self.copyPayloadsToTemp(
                    audioURL: audioURL,
                    sidecar: sidecar,
                    fileManager: fileManager
                )
                let tempAudioURL = tempDirectory.appendingPathComponent("audio.m4a", isDirectory: false)
                let tempLocationURL = sidecar.locationJSONL == nil
                    ? nil
                    : tempDirectory.appendingPathComponent("location.jsonl", isDirectory: false)
                _ = try await transferEnqueuer.enqueueWatchChunkMovingFiles(
                    audioURL: tempAudioURL,
                    locationURL: tempLocationURL,
                    sidecar: sidecar
                )
                try fileManager.removeItem(at: audioURL)
                try? fileManager.removeItem(at: sidecarURL)
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).upload", isDirectory: false))
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).failure", isDirectory: false))
            } catch {
                unresolved += 1
                self.emit(diagnosticLog, detail: "source=\(audioURL.path) reason=enqueue failed")
                watchTransferMigrationLog.error("watch migration enqueue failed source=\(audioURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return unresolved
    }

    static func copyPayloadsToTemp(
        audioURL: URL,
        sidecar: ChunkSidecar,
        fileManager: FileManager
    ) throws -> URL {
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("watch-transfer-migration", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let tempAudioURL = tempDirectory.appendingPathComponent("audio.m4a", isDirectory: false)
        try fileManager.copyItem(at: audioURL, to: tempAudioURL)
        guard try Data(contentsOf: audioURL) == Data(contentsOf: tempAudioURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let locationJSONL = sidecar.locationJSONL {
            try locationJSONL.write(
                to: tempDirectory.appendingPathComponent("location.jsonl", isDirectory: false),
                options: .atomic
            )
        }
        return tempDirectory
    }

    static func loadSidecar(_ url: URL, fileManager: FileManager) -> ChunkSidecar? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChunkSidecar.self, from: Data(contentsOf: url))
    }

    static func quarantine(
        _ sourceURL: URL,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        reason: String,
        fileManager: FileManager
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
            return 0
        }
    }

    static func emit(_ diagnosticLog: DiagnosticLog?, detail: String) {
        diagnosticLog?.append(category: .upload, severity: .warning, message: "needs attention", detail: detail)
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
