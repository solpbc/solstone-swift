// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

private let omiRecoveryLog = Logger(subsystem: "app.solstone.swift", category: "omi-recovery")

@MainActor
enum OmiInProgressRecovery {
    struct Result: Equatable, Sendable {
        var recoveredCount: Int = 0
        var zeroByteRemovedCount: Int = 0
        var quarantinedCount: Int = 0
        var unresolvedCount: Int = 0
    }

    static func recoverInProgressFiles(
        sessionID: UUID,
        rootURL: URL,
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        quarantineRootURL: URL,
        diagnosticLog: DiagnosticLog?,
        fileManager: FileManager = .default,
        cooperator: MaintenanceCooperator = MaintenanceCooperator()
    ) async -> Result {
        let inProgressDirectory = rootURL
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent("in-progress", isDirectory: true)
        guard fileManager.fileExists(atPath: inProgressDirectory.path) else {
            return Result()
        }

        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: inProgressDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            self.emitDiagnostic(
                diagnosticLog: diagnosticLog,
                message: "needs attention",
                detail: "source=\(inProgressDirectory.path) reason=list failed"
            )
            return Result(unresolvedCount: 1)
        }

        var result = Result()
        for audioURL in entries where audioURL.pathExtension == "m4a" {
            guard !Task.isCancelled else { return result }
            await cooperator.step()
            guard !Task.isCancelled else { return result }

            let chunkID = audioURL.deletingPathExtension().lastPathComponent
            guard let byteCount = self.byteCountIfAvailable(at: audioURL, fileManager: fileManager) else {
                result.quarantinedCount += self.quarantine(
                    audioURL,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "size unavailable",
                    fileManager: fileManager
                )
                continue
            }
            if byteCount == 0 {
                try? fileManager.removeItem(at: audioURL)
                result.zeroByteRemovedCount += 1
                continue
            }

            guard let sidecar = self.rebuildSidecar(
                audioURL: audioURL,
                chunkID: chunkID,
                sessionID: sessionID,
                fileManager: fileManager
            ) else {
                result.quarantinedCount += self.quarantine(
                    audioURL,
                    quarantineRootURL: quarantineRootURL,
                    diagnosticLog: diagnosticLog,
                    reason: "probe failed",
                    fileManager: fileManager
                )
                continue
            }

            do {
                _ = try await transferEnqueuer.enqueueOmiChunkMovingFile(chunkURL: audioURL, sidecar: sidecar)
                result.recoveredCount += 1
            } catch {
                result.unresolvedCount += 1
                self.emitDiagnostic(
                    diagnosticLog: diagnosticLog,
                    message: "needs attention",
                    detail: "source=\(audioURL.path) reason=enqueue failed"
                )
                omiRecoveryLog.error("omi in-progress enqueue failed source=\(audioURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if result != Result() {
            omiRecoveryLog.notice(
                "omi in-progress recovery session=\(sessionID.uuidString, privacy: .public) recovered=\(result.recoveredCount, privacy: .public) zero=\(result.zeroByteRemovedCount, privacy: .public) quarantine=\(result.quarantinedCount, privacy: .public) unresolved=\(result.unresolvedCount, privacy: .public)"
            )
        }
        return result
    }

    nonisolated static func rebuildSidecar(
        audioURL: URL,
        chunkID: String,
        sessionID: UUID,
        fileManager: FileManager = .default
    ) -> ChunkSidecar? {
        guard let chunkIndex = self.chunkIndex(fromChunkID: chunkID, sessionID: sessionID),
              let duration = self.decodableAudioDuration(at: audioURL),
              let startedAt = self.startedAtForRecoveredChunk(
                at: audioURL,
                duration: duration,
                fileManager: fileManager
              )
        else {
            return nil
        }

        return ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: duration),
            day: ObserverSegmentNaming.dayString(for: startedAt),
            chunkIndex: chunkIndex,
            startedAt: startedAt,
            durationS: duration,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
    }

    nonisolated static func chunkIndex(fromChunkID chunkID: String, sessionID: UUID) -> Int? {
        let prefix = "\(sessionID.uuidString.lowercased())-"
        guard chunkID.hasPrefix(prefix) else { return nil }
        return Int(chunkID.dropFirst(prefix.count))
    }

    nonisolated static func decodableAudioDuration(at url: URL) -> Double? {
        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let frameCount = file.length
            guard sampleRate > 0, frameCount > 0 else { return nil }
            return Double(frameCount) / sampleRate
        } catch {
            return nil
        }
    }

    nonisolated static func startedAtForRecoveredChunk(
        at url: URL,
        duration: TimeInterval,
        fileManager: FileManager = .default
    ) -> Date? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return nil
        }
        if let creationDate = attributes[.creationDate] as? Date {
            return creationDate
        }
        if let modificationDate = attributes[.modificationDate] as? Date {
            return modificationDate.addingTimeInterval(-duration)
        }
        return nil
    }

    @discardableResult
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
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: sourceURL, to: destination)
            self.emitDiagnostic(
                diagnosticLog: diagnosticLog,
                message: "needs attention",
                detail: "source=\(sourceURL.path) quarantine=\(destination.path) reason=\(reason)"
            )
            omiRecoveryLog.notice("omi file quarantined source=\(sourceURL.path, privacy: .public) reason=\(reason, privacy: .public)")
            return 1
        } catch {
            self.emitDiagnostic(
                diagnosticLog: diagnosticLog,
                message: "needs attention",
                detail: "source=\(sourceURL.path) reason=quarantine failed"
            )
            omiRecoveryLog.error("omi quarantine failed source=\(sourceURL.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    nonisolated static func byteCountIfAvailable(at url: URL, fileManager: FileManager = .default) -> Int? {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return nil
        }
        return size.intValue
    }

    private static func emitDiagnostic(
        diagnosticLog: DiagnosticLog?,
        message: String,
        detail: String
    ) {
        diagnosticLog?.append(category: .upload, severity: .warning, message: message, detail: detail)
    }
}
