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
        acknowledgeTokens: @escaping ([OmiSegmentMetadataToken]) -> Void,
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
                acknowledgeTokens: acknowledgeTokens,
                fileManager: fileManager
            )
        }

        if unresolved == 0 {
            defaults.set(true, forKey: self.flagKey)
        }
    }
}

enum OmiOwnershipDiagnosticReason {
    static func forUnownedVerdict(_ verdict: TransferOwnershipVerdict) -> String {
        switch verdict {
        case .ownedInQueued, .ownedInAttention:
            preconditionFailure("owned transfer verdict has no unresolved diagnostic reason")
        case .conflict(let reason):
            switch reason {
            case .ownerConflict: "owner conflict"
            case .manifestMismatch: "manifest mismatch"
            case .manifestUndecodable: "manifest undecodable"
            case .payloadMismatch: "payload mismatch"
            case .payloadUnreadable: "payload unreadable"
            }
        case .stagingOnly: "item in staging"
        case .salvageOnly: "item in salvage"
        case .notFound: "item not found"
        }
    }
}

private extension OmiTransferSpoolMigrator {
    static func migrateRoot(
        rootURL: URL,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        acknowledgeTokens: @escaping ([OmiSegmentMetadataToken]) -> Void,
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
                    acknowledgeTokens: acknowledgeTokens,
                    fileManager: fileManager
                )
            }
        }
        if unresolved == 0 {
            do {
                if try self.hasRemainingArtifacts(in: rootURL, fileManager: fileManager) {
                    unresolved += 1
                } else {
                    try fileManager.removeItem(at: rootURL)
                }
            } catch {
                unresolved += 1
                self.emit(diagnosticLog, detail: "source=\(rootURL.path) reason=list failed")
            }
        }
        return unresolved
    }

    static func migrateDirectory(
        directoryURL: URL,
        sessionID: UUID,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        acknowledgeTokens: @escaping ([OmiSegmentMetadataToken]) -> Void,
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

        let names = Set(entries.compactMap { entry -> String? in
            switch entry.pathExtension {
            case "m4a", OmiPendingHandoffEnvelope.pathExtension, "json", "upload", "failure":
                return entry.deletingPathExtension().lastPathComponent
            default:
                return nil
            }
        })

        var unresolved = 0
        for chunkID in names {
            let audioURL = directoryURL.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
            let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
            let sidecarURL = directoryURL.appendingPathComponent("\(chunkID).json", isDirectory: false)
            let hasAudio = fileManager.fileExists(atPath: audioURL.path)
            let hasEnvelope = fileManager.fileExists(atPath: envelopeURL.path)
            let envelope = OmiInProgressRecovery.loadEnvelope(
                at: envelopeURL,
                diagnosticLog: diagnosticLog,
                fileManager: fileManager
            )

            if hasEnvelope && envelope == nil {
                unresolved += 1
                continue
            }
            guard hasAudio || hasEnvelope else {
                unresolved += 1
                self.emit(diagnosticLog, detail: "source=\(directoryURL.path) reason=item not found")
                continue
            }

            let sidecar = envelope?.sidecar
                ?? self.loadSidecar(sidecarURL, fileManager: fileManager)
                ?? (hasAudio ? OmiInProgressRecovery.rebuildSidecar(
                    audioURL: audioURL,
                    chunkID: chunkID,
                    sessionID: sessionID,
                    fileManager: fileManager
                ) : nil)

            guard let sidecar else {
                if hasAudio {
                    let quarantined = OmiInProgressRecovery.quarantine(
                        audioURL,
                        quarantineRootURL: quarantineRootURL,
                        diagnosticLog: diagnosticLog,
                        reason: "probe failed",
                        fileManager: fileManager
                    )
                    if quarantined == 0 {
                        unresolved += 1
                    } else {
                        try? fileManager.removeItem(at: sidecarURL)
                        try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).upload", isDirectory: false))
                        try? fileManager.removeItem(at: directoryURL.appendingPathComponent("\(chunkID).failure", isDirectory: false))
                    }
                } else {
                    unresolved += 1
                }
                continue
            }

            guard let envelope else {
                guard hasAudio else {
                    unresolved += 1
                    continue
                }
                do {
                    let tempURL = try self.copyToTemp(audioURL, fileManager: fileManager)
                    _ = try await transferEnqueuer.enqueueOmiChunkMovingFile(chunkURL: tempURL, sidecar: sidecar)
                    if !self.cleanup(
                        audioURL: audioURL,
                        chunkID: chunkID,
                        envelopeURL: envelopeURL,
                        envelope: nil,
                        acknowledgeTokens: acknowledgeTokens,
                        diagnosticLog: diagnosticLog,
                        fileManager: fileManager
                    ) {
                        unresolved += 1
                    }
                } catch {
                    unresolved += 1
                    self.emit(diagnosticLog, detail: "source=\(audioURL.path) reason=enqueue failed")
                    omiTransferMigrationLog.error("omi migration enqueue failed source=\(audioURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                continue
            }

            let sourceURLs = hasAudio ? ["audio": audioURL] : [:]
            let verdict: TransferOwnershipVerdict
            do {
                verdict = try await transferEnqueuer.verifyOmiOwnership(
                    itemID: envelope.itemID,
                    sidecar: sidecar,
                    metadata: envelope.metadata,
                    expectedPayloadSourceURLs: sourceURLs
                )
            } catch {
                unresolved += 1
                self.emit(diagnosticLog, detail: "source=\(envelopeURL.path) reason=item lookup failed")
                continue
            }

            switch verdict {
            case .ownedInQueued, .ownedInAttention:
                if !self.cleanup(
                    audioURL: hasAudio ? audioURL : nil,
                    chunkID: chunkID,
                    envelopeURL: envelopeURL,
                    envelope: envelope,
                    acknowledgeTokens: acknowledgeTokens,
                    diagnosticLog: diagnosticLog,
                    fileManager: fileManager
                ) {
                    unresolved += 1
                }
            case .notFound where hasAudio:
                do {
                    let tempURL = try self.copyToTemp(audioURL, fileManager: fileManager)
                    _ = try await transferEnqueuer.enqueueOmiChunkMovingFile(
                        itemID: envelope.itemID,
                        chunkURL: tempURL,
                        sidecar: sidecar,
                        metadata: envelope.metadata
                    )
                    let postEnqueue = try await transferEnqueuer.verifyOmiOwnership(
                        itemID: envelope.itemID,
                        sidecar: sidecar,
                        metadata: envelope.metadata,
                        expectedPayloadSourceURLs: ["audio": audioURL]
                    )
                    guard case .ownedInQueued = postEnqueue else {
                        unresolved += 1
                        self.emit(diagnosticLog, detail: "source=\(envelopeURL.path) reason=\(OmiOwnershipDiagnosticReason.forUnownedVerdict(postEnqueue))")
                        continue
                    }
                    if !self.cleanup(
                        audioURL: audioURL,
                        chunkID: chunkID,
                        envelopeURL: envelopeURL,
                        envelope: envelope,
                        acknowledgeTokens: acknowledgeTokens,
                        diagnosticLog: diagnosticLog,
                        fileManager: fileManager
                    ) {
                        unresolved += 1
                    }
                } catch {
                    unresolved += 1
                    self.emit(diagnosticLog, detail: "source=\(audioURL.path) reason=enqueue failed")
                    omiTransferMigrationLog.error("omi migration enqueue failed source=\(audioURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            default:
                unresolved += 1
                self.emit(diagnosticLog, detail: "source=\(envelopeURL.path) reason=\(OmiOwnershipDiagnosticReason.forUnownedVerdict(verdict))")
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

    static func cleanup(
        audioURL: URL?,
        chunkID: String,
        envelopeURL: URL,
        envelope: OmiPendingHandoffEnvelope?,
        acknowledgeTokens: ([OmiSegmentMetadataToken]) -> Void,
        diagnosticLog: DiagnosticLog?,
        fileManager: FileManager
    ) -> Bool {
        if let envelope, !envelope.frozenTokens.isEmpty {
            acknowledgeTokens(envelope.frozenTokens)
        }
        do {
            if let audioURL, fileManager.fileExists(atPath: audioURL.path) {
                try fileManager.removeItem(at: audioURL)
            }
            let directoryURL = envelopeURL.deletingLastPathComponent()
            for pathExtension in ["json", "upload", "failure"] {
                let url = directoryURL.appendingPathComponent("\(chunkID).\(pathExtension)", isDirectory: false)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        } catch {
            return false
        }
        guard envelope == nil || OmiPendingHandoffStore.remove(at: envelopeURL, fileManager: fileManager) else {
            self.emit(diagnosticLog, detail: "source=\(envelopeURL.path) reason=envelope removal failed")
            return false
        }
        return true
    }

    static func hasRemainingArtifacts(in rootURL: URL, fileManager: FileManager) throws -> Bool {
        guard let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: nil) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let url as URL in enumerator {
            switch url.pathExtension {
            case "m4a", OmiPendingHandoffEnvelope.pathExtension, "json", "upload", "failure":
                return true
            default:
                continue
            }
        }
        return false
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
