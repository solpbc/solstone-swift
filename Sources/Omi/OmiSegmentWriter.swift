// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import os

@MainActor
final class OmiSegmentWriter {
    nonisolated static let cacheDirectoryName = "OmiObserver"

    private static let maxChunkOpenAttempts = 3

    private let transferEnqueuer: ObserverAudioTransferEnqueuer
    private let cacheRootURL: URL
    private let fileManager: FileManager
    private let clock: any ObserverClock
    private let sampleLimit: Int
    private let log = Logger(subsystem: "app.solstone.swift", category: "omi-writer")

    var onChunkFinalized: ((_ day: String, _ durationS: TimeInterval, _ identity: String) -> Void)?
    var onWriterFault: (() -> Void)?
    var freezeSegmentMetadata: (() -> OmiSegmentMetadataSnapshot?)?
    var acknowledgeSegmentMetadata: (([OmiSegmentMetadataToken]) -> Void)?
    var onHandoffDegradation: ((String) -> Void)?

    private(set) var droppedSamples = 0
    private(set) var failedOpens = 0

    private var sessionID: UUID?
    private var chunkIndex = 0
    private var currentChunkStart: Date?
    private var samplesWritten = 0
    private var currentFile: AVAudioFile?
    private var currentURL: URL?
    private var pendingChunkStart: Date?
    private var segmentationTask: Task<Void, Never>?
    private var consecutiveChunkOpenFailures = 0
    private var didNotifyWriterFaultForCurrentWedge = false

    init(
        transferEnqueuer: ObserverAudioTransferEnqueuer,
        cacheRootURL: URL? = nil,
        fileManager: FileManager = .default,
        clock: any ObserverClock = SystemObserverClock(),
        sampleLimit: Int = OmiAudioChunkFormat.sampleLimit
    ) {
        precondition(sampleLimit > 0)
        self.transferEnqueuer = transferEnqueuer
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
            ?? (try? AppGroupContainer.rootURL(fileManager: fileManager)
                .appendingPathComponent(Self.cacheDirectoryName, isDirectory: true))
            ?? fileManager.temporaryDirectory
                .appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        self.clock = clock
        self.sampleLimit = sampleLimit
    }

    func start() {
        guard self.sessionID == nil else { return }

        self.sessionID = UUID()
        self.chunkIndex = 0
        do {
            try self.openChunk()
            self.startSegmentationTimer()
            self.log.info("omi writer started")
        } catch {
            self.noteChunkOpenFailure(error, context: "start")
            self.clearState()
        }
    }

    var isRunning: Bool { self.sessionID != nil }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        guard self.sessionID != nil else { return }

        _ = self.rotateIfElapsed()
        let partitions = OmiSamplePartitioner.partitions(
            samples: samples,
            alreadyWritten: self.samplesWritten,
            sampleLimit: self.sampleLimit
        )

        for partition in partitions {
            self.rotateForSampleLimitIfNeeded()
            guard self.ensureCurrentChunk(droppedSampleCount: partition.count) else {
                continue
            }
            guard let audioFile = self.currentFile else { continue }
            guard let buffer = OmiAudioChunkFormat.makeBuffer(partition) else {
                self.log.error("omi writer buffer unavailable")
                continue
            }

            do {
                try audioFile.write(from: buffer)
                self.samplesWritten += partition.count
            } catch {
                self.log.error("omi writer write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func stop() {
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.finalizeCurrentChunk()
        self.clearState()
        self.log.info("omi writer stopped")
    }

    func finalizeOpenChunk() async {
        let hadOpenChunk = self.currentURL != nil
        await self.finalizeCurrentChunkAwaitingEnqueue()
        if hadOpenChunk {
            self.chunkIndex += 1
        }
    }

    func finalizeOpenChunkForDisconnect() {
        let hadOpenChunk = self.currentURL != nil
        self.finalizeCurrentChunk()
        if hadOpenChunk {
            self.chunkIndex += 1
        }
    }

    nonisolated static func chunkID(sessionID: UUID, index: Int) -> String {
        "\(sessionID.uuidString.lowercased())-\(index)"
    }
}

private extension OmiSegmentWriter {
    func startSegmentationTimer() {
        self.segmentationTask?.cancel()
        self.segmentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await self.clock.sleep(for: .seconds(OmiAudioChunkFormat.chunkDurationSeconds))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                _ = self.rotateIfElapsed()
            }
        }
    }

    func openChunk(startedAt: Date? = nil) throws {
        guard let sessionID = self.sessionID else {
            return
        }

        let chunkStart = startedAt ?? self.pendingChunkStart ?? self.clock.now()
        let chunkID = Self.chunkID(sessionID: sessionID, index: self.chunkIndex)
        let url = try self.inProgressChunkURL(sessionID: sessionID, chunkID: chunkID)
        let file = try AVAudioFile(
            forWriting: url,
            settings: OmiAudioChunkFormat.aacSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
        self.currentFile = file
        self.currentURL = url
        self.currentChunkStart = chunkStart
        self.samplesWritten = 0
        self.pendingChunkStart = nil
        self.resetChunkOpenFailureState()
    }

    func rotateIfElapsed() -> Bool {
        guard self.currentFile != nil,
              let currentChunkStart,
              self.clock.now().timeIntervalSince(currentChunkStart) >= OmiAudioChunkFormat.chunkDurationSeconds
        else {
            return true
        }

        self.finalizeCurrentChunk()
        self.chunkIndex += 1

        do {
            try self.openChunk()
            return true
        } catch {
            self.noteChunkOpenFailure(error, context: "rotate")
            return false
        }
    }

    func rotateForSampleLimitIfNeeded() {
        guard self.currentFile != nil,
              let currentChunkStart,
              self.samplesWritten >= self.sampleLimit
        else {
            return
        }

        let successorStart = currentChunkStart.addingTimeInterval(
            Double(self.samplesWritten) / OmiAudioChunkFormat.sampleRate
        )
        self.finalizeCurrentChunk()
        self.chunkIndex += 1
        self.pendingChunkStart = successorStart
    }

    func finalizeCurrentChunk() {
        guard let handoff = self.preparePendingHandoff() else { return }
        let transferEnqueuer = self.transferEnqueuer
        Task { @MainActor [weak self, transferEnqueuer, handoff] in
            await self?.completePendingHandoff(handoff, transferEnqueuer: transferEnqueuer)
        }
    }

    func finalizeCurrentChunkAwaitingEnqueue() async {
        guard let handoff = self.preparePendingHandoff() else { return }
        await self.completePendingHandoff(handoff, transferEnqueuer: self.transferEnqueuer)
    }

    func completePendingHandoff(
        _ handoff: OmiPendingHandoff,
        transferEnqueuer: ObserverAudioTransferEnqueuer
    ) async {
        do {
            _ = try await transferEnqueuer.enqueueOmiChunkMovingFile(
                itemID: handoff.envelope.itemID,
                chunkURL: handoff.finalizedChunk.url,
                sidecar: handoff.envelope.sidecar,
                metadata: handoff.envelope.metadata
            )
            let canAcknowledge: Bool
            if handoff.envelopeWasPersisted {
                canAcknowledge = OmiPendingHandoffStore.remove(
                    at: handoff.envelopeURL,
                    fileManager: self.fileManager
                )
                if !canAcknowledge {
                    self.noteHandoffDegradation(
                        "source=\(handoff.envelopeURL.path) reason=envelope removal failed"
                    )
                }
            } else {
                canAcknowledge = true
            }
            if canAcknowledge, !handoff.envelope.frozenTokens.isEmpty {
                self.acknowledgeSegmentMetadata?(handoff.envelope.frozenTokens)
            }
            self.notifyChunkFinalized(handoff.finalizedChunk)
        } catch {
            self.log.error("omi writer enqueue failed: \(String(describing: error), privacy: .public)")
        }
    }

    func preparePendingHandoff() -> OmiPendingHandoff? {
        guard let sessionID = self.sessionID,
              let url = self.currentURL,
              let startedAt = self.currentChunkStart
        else {
            self.currentFile?.close()
            self.clearCurrentChunk()
            return nil
        }

        let chunkIndex = self.chunkIndex
        let samplesWritten = self.samplesWritten
        let duration = Double(samplesWritten) / OmiAudioChunkFormat.sampleRate
        guard samplesWritten > 0, duration >= OmiAudioChunkFormat.minChunkDurationSeconds else {
            self.currentFile?.close()
            self.clearCurrentChunk()
            try? FileManager.default.removeItem(at: url)
            return nil
        }

        let snapshot = self.freezeSegmentMetadata?()
        let itemID = UUID()
        let day = ObserverSegmentNaming.dayString(for: startedAt)
        let sidecar = ChunkSidecar(
            segment: ObserverSegmentNaming.segmentString(for: startedAt, durationSeconds: duration),
            day: day,
            chunkIndex: chunkIndex,
            startedAt: startedAt,
            durationS: duration,
            sessionID: sessionID,
            mode: .meeting,
            locationJSONL: nil
        )
        let finalizedChunk = FinalizedChunk(
            url: url,
            sidecar: sidecar,
            day: day,
            durationS: duration,
            identity: Self.chunkID(sessionID: sessionID, index: chunkIndex)
        )
        let envelope = OmiPendingHandoffEnvelope(
            itemID: itemID,
            sidecar: sidecar,
            metadata: snapshot?.metadata,
            frozenTokens: snapshot?.frozenTokens ?? []
        )
        let envelopeURL = OmiPendingHandoffStore.url(for: url)
        let envelopeWasPersisted: Bool
        do {
            let data = try OmiPendingHandoffStore.encode(envelope)
            do {
                try OmiPendingHandoffStore.write(data, to: envelopeURL)
                envelopeWasPersisted = true
            } catch {
                envelopeWasPersisted = false
                self.noteHandoffDegradation(
                    "source=\(envelopeURL.path) reason=envelope write failed",
                    error: error
                )
            }
        } catch {
            envelopeWasPersisted = false
            self.noteHandoffDegradation(
                "source=\(envelopeURL.path) reason=envelope encode failed",
                error: error
            )
        }
        self.currentFile?.close()
        self.clearCurrentChunk()
        return OmiPendingHandoff(
            finalizedChunk: finalizedChunk,
            envelope: envelope,
            envelopeURL: envelopeURL,
            envelopeWasPersisted: envelopeWasPersisted
        )
    }

    func noteHandoffDegradation(_ detail: String, error: (any Error)? = nil) {
        if let error {
            self.log.error("omi handoff degradation \(detail, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            self.log.error("omi handoff degradation \(detail, privacy: .public)")
        }
        self.onHandoffDegradation?(detail)
    }

    func notifyChunkFinalized(_ finalizedChunk: FinalizedChunk) {
        self.onChunkFinalized?(
            finalizedChunk.day,
            finalizedChunk.durationS,
            finalizedChunk.identity
        )
    }

    func clearCurrentChunk() {
        self.currentFile = nil
        self.currentURL = nil
        self.currentChunkStart = nil
        self.samplesWritten = 0
    }

    func clearState() {
        self.segmentationTask?.cancel()
        self.segmentationTask = nil
        self.currentFile?.close()
        self.sessionID = nil
        self.chunkIndex = 0
        self.pendingChunkStart = nil
        self.resetChunkOpenFailureState()
        self.clearCurrentChunk()
    }

    func ensureCurrentChunk(droppedSampleCount: Int) -> Bool {
        guard self.currentFile == nil else {
            return true
        }
        while self.currentFile == nil && self.consecutiveChunkOpenFailures < Self.maxChunkOpenAttempts {
            do {
                try self.openChunk()
                return true
            } catch {
                self.noteChunkOpenFailure(error, context: "append")
            }
        }
        self.droppedSamples += droppedSampleCount
        return false
    }

    func noteChunkOpenFailure(_ error: any Error, context: String) {
        self.failedOpens += 1
        self.consecutiveChunkOpenFailures += 1
        self.log.error("omi writer \(context, privacy: .public) open failed: \(String(describing: error), privacy: .public)")
        guard self.consecutiveChunkOpenFailures >= Self.maxChunkOpenAttempts,
              !self.didNotifyWriterFaultForCurrentWedge
        else {
            return
        }
        self.didNotifyWriterFaultForCurrentWedge = true
        self.onWriterFault?()
    }

    func resetChunkOpenFailureState() {
        self.consecutiveChunkOpenFailures = 0
        self.didNotifyWriterFaultForCurrentWedge = false
    }

    func sessionDirectoryURL(sessionID: UUID) -> URL {
        self.cacheRootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func inProgressDirectoryURL(sessionID: UUID) -> URL {
        self.sessionDirectoryURL(sessionID: sessionID).appendingPathComponent("in-progress", isDirectory: true)
    }

    func inProgressChunkURL(sessionID: UUID, chunkID: String) throws -> URL {
        let directory = self.inProgressDirectoryURL(sessionID: sessionID)
        try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(chunkID).m4a", isDirectory: false)
    }
}

private struct FinalizedChunk: Sendable {
    let url: URL
    let sidecar: ChunkSidecar
    let day: String
    let durationS: TimeInterval
    let identity: String
}

private struct OmiPendingHandoff: Sendable {
    let finalizedChunk: FinalizedChunk
    let envelope: OmiPendingHandoffEnvelope
    let envelopeURL: URL
    let envelopeWasPersisted: Bool
}
