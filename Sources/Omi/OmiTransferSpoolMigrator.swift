// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os

private let omiTransferMigrationLog = Logger(subsystem: "app.solstone.swift", category: "omi-transfer-migration")

@MainActor
enum OmiTransferSpoolMigrator {
    static let flagKey = "didMigrateOmiObserverToTransferV1"
    static let quarantineRelativePath = "TransferQuarantine/OmiObserver"

    static func quarantineRootURL(appGroupRootURL: URL) -> URL {
        appGroupRootURL.appendingPathComponent(self.quarantineRelativePath, isDirectory: true)
    }

    static func migrate(
        appGroupRootURL: URL,
        legacyCachesRootURL: URL?,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        diagnosticLog: DiagnosticLog?,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) async {
        guard defaults.bool(forKey: self.flagKey) == false else { return }

        let quarantineRoot = self.quarantineRootURL(appGroupRootURL: appGroupRootURL)
        let roots = [
            appGroupRootURL.appendingPathComponent(OmiSegmentWriter.cacheDirectoryName, isDirectory: true),
            legacyCachesRootURL,
        ].compactMap { $0 }

        var unresolved = 0
        for root in roots where fileManager.fileExists(atPath: root.path) {
            unresolved += await self.migrateRoot(
                rootURL: root,
                transferEnqueuer: transferEnqueuer,
                quarantineRootURL: quarantineRoot,
                diagnosticLog: diagnosticLog,
                fileManager: fileManager
            )
        }

        if unresolved == 0 {
            defaults.set(true, forKey: self.flagKey)
        }
    }
}

private extension OmiTransferSpoolMigrator {
    static func migrateRoot(
        rootURL: URL,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        fileManager: FileManager
    ) async -> Int {
        let sessions: [URL]
        do {
            sessions = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            self.emit(diagnosticLog, detail: "source=\(rootURL.path) reason=list failed")
            return 1
        }

        var unresolved = 0
        for sessionURL in sessions where self.isDirectory(sessionURL, fileManager: fileManager) {
            guard let sessionID = UUID(uuidString: sessionURL.lastPathComponent) else { continue }
            for directoryName in ["in-progress", "pending", "failed"] {
                let directory = sessionURL.appendingPathComponent(directoryName, isDirectory: true)
                guard fileManager.fileExists(atPath: directory.path) else { continue }
                unresolved += await self.migrateDirectory(
                    directoryURL: directory,
                    sessionID: sessionID,
                    transferEnqueuer: transferEnqueuer,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    fileManager: fileManager
                )
            }
        }
        if unresolved == 0 {
            try? fileManager.removeItem(at: rootURL)
        }
        return unresolved
    }

    static func migrateDirectory(
        directoryURL: URL,
        sessionID: UUID,
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
            let sidecar = self.loadSidecar(sidecarURL, fileManager: fileManager)
                ?? OmiInProgressRecovery.rebuildSidecar(
                    audioURL: audioURL,
                    chunkID: chunkID,
                    sessionID: sessionID,
                    fileManager: fileManager
                )
            guard let sidecar else {
                _ = OmiInProgressRecovery.quarantine(
                    audioURL,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "probe failed",
                    fileManager: fileManager
                )
                try? fileManager.removeItem(at: sidecarURL)
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).upload", isDirectory: false))
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).failure", isDirectory: false))
                continue
            }

            do {
                let tempURL = try self.copyToTemp(audioURL, fileManager: fileManager)
                _ = try await transferEnqueuer.enqueueOmiChunkMovingFile(chunkURL: tempURL, sidecar: sidecar)
                try fileManager.removeItem(at: audioURL)
                try? fileManager.removeItem(at: sidecarURL)
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).upload", isDirectory: false))
                try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).failure", isDirectory: false))
            } catch {
                unresolved += 1
                self.emit(diagnosticLog, detail: "source=\(audioURL.path) reason=enqueue failed")
                omiTransferMigrationLog.error("omi migration enqueue failed source=\(audioURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return unresolved
    }

    static func copyToTemp(_ sourceURL: URL, fileManager: FileManager) throws -> URL {
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("omi-transfer-migration", isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let tempURL = tempDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(sourceURL.pathExtension)
        try fileManager.copyItem(at: sourceURL, to: tempURL)
        guard try Data(contentsOf: sourceURL) == Data(contentsOf: tempURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return tempURL
    }

    static func loadSidecar(_ url: URL, fileManager: FileManager) -> ChunkSidecar? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChunkSidecar.self, from: Data(contentsOf: url))
    }

    static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    static func emit(_ diagnosticLog: DiagnosticLog?, detail: String) {
        diagnosticLog?.append(category: .upload, severity: .warning, message: "needs attention", detail: detail)
    }
}
