// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OmiLaunchCaptureMarkerObservation: Equatable, Sendable {
    let epoch: UInt32
    let acquiredAt: Date
    let sequence: UInt64?
}

nonisolated struct OmiLaunchCaptureMaterializedPartition: Equatable, Sendable {
    let itemID: UUID
    let audioURL: URL
    let envelopeURL: URL
    let coveredThroughSequence: UInt64?
    let endsAtSourceFrameBoundary: Bool
    let isExistingOwner: Bool
}

nonisolated struct OmiLaunchCaptureOrphanRepairFailure: Equatable, Sendable {
    let ordinal: Int
    let itemID: UUID
}

nonisolated struct OmiLaunchCaptureMaterializationFailure: Equatable, Sendable {
    let partitionOrdinal: Int
    let reason: String
}

nonisolated struct OmiLaunchCaptureMaterializationResult: Equatable, Sendable {
    let partitions: [OmiLaunchCaptureMaterializedPartition]
    let coveredThroughSequence: UInt64?
    let failure: OmiLaunchCaptureMaterializationFailure?
    let markers: [OmiLaunchCaptureMarkerObservation]
    let verifiedPrefixEndOffset: Int
    let orphanRepairFailures: [OmiLaunchCaptureOrphanRepairFailure]
}

@MainActor
final class OmiLaunchCaptureMaterializer {
    private struct Partition {
        let ordinal: Int
        let startSequence: UInt64
        let startSampleOffset: UInt64
        let startedAt: Date
        var samples: [Int16]
        var terminalSequence: UInt64?
        var endsAtSourceFrameBoundary = false
        let sealedSampleCount: Int?
        let isRecognizedOrphan: Bool
    }

    private struct ExistingOutput {
        let hasAudio: Bool
        let hasEnvelope: Bool
    }

    private struct PersistedBoundary {
        let sampleCount: Int
        let hasAudio: Bool
    }

    private enum GrowthOutput {
        case fresh
        case persisted(PersistedBoundary)
        case recognizedOrphan
    }

    private enum OrphanRecognition: Equatable {
        case recognized
        case mismatch
        case ioFailure
    }

    private enum PersistOutcome {
        case output(OmiLaunchCaptureMaterializedPartition)
        case failure(OmiLaunchCaptureMaterializationFailure)
    }

    private enum PartitionOutcome {
        case partition(Partition)
        case failure(OmiLaunchCaptureMaterializationFailure)
    }

    private let rootURL: URL
    private let generationID: UUID
    private let io: any OmiLaunchCaptureIO
    private let reader: OmiLaunchCaptureLeaseReader
    private let makeWriter: () -> any OmiAACChunkWriting
    private let decode: @MainActor @Sendable (Data) -> [Int16]?
    private let diagnosticLog: DiagnosticLog?

    private(set) var peakLeaseResidentPayloadBytes = 0
    private(set) var peakOpenPartitionSampleCount = 0
    private var orphanRepairFailures: [OmiLaunchCaptureOrphanRepairFailure] = []

    init(rootURL: URL, generationID: UUID, io: any OmiLaunchCaptureIO = FoundationOmiLaunchCaptureIO(), makeWriter: (() -> any OmiAACChunkWriting)? = nil, decode: @escaping @MainActor @Sendable (Data) -> [Int16]?, diagnosticLog: DiagnosticLog? = nil) {
        self.rootURL = rootURL
        self.generationID = generationID
        self.io = io
        self.reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generationID, io: io)
        self.makeWriter = makeWriter ?? { AVFoundationOmiAACChunkWriter(io: io) }
        self.decode = decode
        self.diagnosticLog = diagnosticLog
    }

    func materialize() -> OmiLaunchCaptureMaterializationResult {
        self.peakLeaseResidentPayloadBytes = 0
        self.peakOpenPartitionSampleCount = 0
        self.orphanRepairFailures = []
        guard let initialPosition = self.reader.acknowledgedPosition() else {
            return OmiLaunchCaptureMaterializationResult(partitions: [], coveredThroughSequence: nil, failure: nil, markers: [], verifiedPrefixEndOffset: 0, orphanRepairFailures: [])
        }
        var position = initialPosition
        var reassembler = OmiAudioReassembler()
        var current: Partition?
        var outputs: [OmiLaunchCaptureMaterializedPartition] = []
        var markers: [OmiLaunchCaptureMarkerObservation] = []
        var sampleOffset: UInt64 = 0
        var nextOrdinal = 0
        var verifiedPrefixEndOffset = position.offset
        var coveredThroughSequence: UInt64?
        var failure: OmiLaunchCaptureMaterializationFailure?

        materialization: while case .lease(let lease) = reader.lease(from: position) {
            self.peakLeaseResidentPayloadBytes = max(self.peakLeaseResidentPayloadBytes, reader.peakLeaseResidentPayloadBytes)
            for record in lease.records {
                let acquiredAt = Date(timeIntervalSince1970: Double(record.acquiredAtUnixMicros) / 1_000_000)
                let output = reassembler.ingest(record.payload, acquiredAt: acquiredAt, recordSequence: record.sequence)
                if output.discardedStartedFrame {
                    failure = OmiLaunchCaptureMaterializationFailure(partitionOrdinal: current?.ordinal ?? nextOrdinal, reason: "reassembly-discarded-frame")
                    self.noteAttention(current?.ordinal ?? nextOrdinal, reason: "reassembly-discarded-frame")
                    break materialization
                }
                markers.append(contentsOf: output.markers.map { OmiLaunchCaptureMarkerObservation(epoch: $0.epoch, acquiredAt: acquiredAt, sequence: record.sequence) })
                if let consumeFailure = self.consume(output.completedFrames, current: &current, sampleOffset: &sampleOffset, nextOrdinal: &nextOrdinal, outputs: &outputs, coveredThroughSequence: &coveredThroughSequence) {
                    failure = consumeFailure
                    break materialization
                }
            }
            position = OmiLaunchCaptureReadPosition(generationID: generationID, nextSequence: lease.throughSequence + 1, offset: lease.endOffset)
            verifiedPrefixEndOffset = lease.endOffset
        }
        if failure == nil {
            failure = self.consume(reassembler.flushFinalFrame().completedFrames, current: &current, sampleOffset: &sampleOffset, nextOrdinal: &nextOrdinal, outputs: &outputs, coveredThroughSequence: &coveredThroughSequence)
        }
        if failure == nil, let current, !current.samples.isEmpty {
            switch self.persist(current) {
            case .output(let output):
                self.append(output, to: &outputs, coveredThroughSequence: &coveredThroughSequence)
            case .failure(let persistFailure):
                failure = persistFailure
            }
        }
        return OmiLaunchCaptureMaterializationResult(partitions: outputs, coveredThroughSequence: coveredThroughSequence, failure: failure, markers: markers, verifiedPrefixEndOffset: verifiedPrefixEndOffset, orphanRepairFailures: self.orphanRepairFailures)
    }

    private func consume(_ frames: [OmiReassembledFrame], current: inout Partition?, sampleOffset: inout UInt64, nextOrdinal: inout Int, outputs: inout [OmiLaunchCaptureMaterializedPartition], coveredThroughSequence: inout UInt64?) -> OmiLaunchCaptureMaterializationFailure? {
        for frame in frames {
            guard let startSequence = frame.startSequence else { continue }
            guard let decoded = decode(frame.data), !decoded.isEmpty else {
                let ordinal = current?.ordinal ?? nextOrdinal
                self.noteAttention(ordinal, reason: "decode")
                return OmiLaunchCaptureMaterializationFailure(partitionOrdinal: ordinal, reason: "decode")
            }
            if let currentPartition = current,
               !currentPartition.samples.isEmpty,
               frame.acquiredAt.timeIntervalSince(currentPartition.startedAt) >= OmiAudioChunkFormat.chunkDurationSeconds {
                switch self.persist(currentPartition) {
                case .output(let output):
                    self.append(output, to: &outputs, coveredThroughSequence: &coveredThroughSequence)
                case .failure(let failure):
                    return failure
                }
                current = nil
            }
            var remaining = ArraySlice(decoded)
            while !remaining.isEmpty {
                if let currentPartition = current, currentPartition.samples.isEmpty {
                    current = Partition(ordinal: currentPartition.ordinal, startSequence: startSequence, startSampleOffset: currentPartition.startSampleOffset, startedAt: currentPartition.startedAt, samples: [], terminalSequence: nil, sealedSampleCount: currentPartition.sealedSampleCount, isRecognizedOrphan: currentPartition.isRecognizedOrphan)
                }
                if current == nil {
                    switch self.makePartition(ordinal: nextOrdinal, startSequence: startSequence, startSampleOffset: sampleOffset, startedAt: frame.acquiredAt) {
                    case .partition(let partition):
                        current = partition
                        nextOrdinal += 1
                    case .failure(let failure):
                        return failure
                    }
                }
                let limit = current!.sealedSampleCount ?? OmiAudioChunkFormat.sampleLimit
                let available = limit - current!.samples.count
                guard available > 0 else {
                    let failure = OmiLaunchCaptureMaterializationFailure(partitionOrdinal: current!.ordinal, reason: "sealed")
                    self.noteAttention(current!.ordinal, reason: "sealed")
                    return failure
                }
                let count = min(available, remaining.count)
                let slice = remaining.prefix(count)
                remaining = remaining.dropFirst(count)
                current!.samples.append(contentsOf: slice)
                current!.terminalSequence = frame.endSequence
                current!.endsAtSourceFrameBoundary = remaining.isEmpty
                self.peakOpenPartitionSampleCount = max(self.peakOpenPartitionSampleCount, current!.samples.count)
                sampleOffset += UInt64(slice.count)
                if current!.samples.count == limit {
                    let finished = current!
                    switch self.persist(finished) {
                    case .output(let output):
                        self.append(output, to: &outputs, coveredThroughSequence: &coveredThroughSequence)
                    case .failure(let failure):
                        return failure
                    }
                    if remaining.isEmpty {
                        current = nil
                    } else {
                        let successor = finished.startedAt.addingTimeInterval(Double(finished.samples.count) / OmiAudioChunkFormat.sampleRate)
                        switch self.makePartition(ordinal: nextOrdinal, startSequence: finished.startSequence, startSampleOffset: sampleOffset, startedAt: successor) {
                        case .partition(let partition):
                            current = partition
                            nextOrdinal += 1
                        case .failure(let failure):
                            return failure
                        }
                    }
                }
            }
        }
        return nil
    }

    private func persist(_ partition: Partition) -> PersistOutcome {
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: rootURL, generationID: generationID, ordinal: partition.ordinal)
        let audioURL = paths.audioURL
        let envelopeURL = paths.envelopeURL
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generationID, partitionOrdinal: partition.ordinal, startSequence: partition.startSequence, startSampleOffset: partition.startSampleOffset)
        let sidecar = self.sidecar(for: partition)
        let isRepair = partition.isRecognizedOrphan
        let existingOutput: ExistingOutput
        do {
            existingOutput = try self.existingOutput(audioURL: audioURL, envelopeURL: envelopeURL)
        } catch {
            return .failure(self.persistFailure(partition, isRepair: isRepair, reason: "exists"))
        }
        if !isRepair, let boundary = self.persistedBoundary(
            itemID: itemID,
            ordinal: partition.ordinal,
            envelopeURL: envelopeURL,
            hasAudio: existingOutput.hasAudio
        ) {
            guard boundary.sampleCount == partition.samples.count else {
                self.noteAttention(partition.ordinal, reason: "sealed")
                return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: "sealed"))
            }
            if boundary.hasAudio, !self.isReusable(existingOutput: existingOutput, envelopeURL: envelopeURL, itemID: itemID, sidecar: sidecar) {
                self.noteAttention(partition.ordinal, reason: "sealed")
                return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: "sealed"))
            }
            return .output(self.output(
                itemID: itemID,
                partition: partition,
                audioURL: audioURL,
                envelopeURL: envelopeURL,
                isExistingOwner: !boundary.hasAudio
            ))
        }
        if isRepair {
            switch self.orphanRecognition(paths: paths, itemID: itemID, partition: partition, existingOutput: existingOutput) {
            case .recognized:
                break
            case .mismatch:
                self.noteAttention(partition.ordinal, reason: "sealed")
                return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: "sealed"))
            case .ioFailure:
                return .failure(self.persistFailure(partition, isRepair: true, reason: "provenance"))
            }
            guard self.quarantineIfPresent(audioURL, isPresent: true) else {
                return .failure(self.persistFailure(partition, isRepair: true, reason: "quarantine"))
            }
        } else if existingOutput.hasAudio || existingOutput.hasEnvelope {
            self.noteAttention(partition.ordinal, reason: "sealed")
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: "sealed"))
        }

        let directory = audioURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".\(audioURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.lowercased()).tmp.m4a")
        do { try io.ensureDirectory(at: directory) } catch { return .failure(self.persistFailure(partition, isRepair: isRepair, reason: "audio-open")) }
        let writer = makeWriter()
        do { try writer.open(at: temporaryURL) } catch { return .failure(self.persistFailure(partition, isRepair: isRepair, reason: "audio-open")) }
        do { try writer.write(samples: partition.samples[...]) } catch {
            try? writer.close()
            let reason = self.reportAfterCleanup(temporaryURL, partition: partition, isRepair: isRepair, reason: "audio-write")
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: reason))
        }
        do { try writer.close() } catch {
            let reason = self.reportAfterCleanup(temporaryURL, partition: partition, isRepair: isRepair, reason: "audio-sync")
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: reason))
        }
        do { try writer.synchronize(at: temporaryURL) } catch {
            let reason = self.reportAfterCleanup(temporaryURL, partition: partition, isRepair: isRepair, reason: "audio-sync")
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: reason))
        }
        let provenance = OmiLaunchCaptureMaterializationProvenance(generationID: generationID, partitionOrdinal: partition.ordinal, startSequence: partition.startSequence, startSampleOffset: partition.startSampleOffset, itemID: itemID)
        do {
            // The record must be durable before its artifact can exist, so this crash window remains recognizable.
            try OmiLaunchCaptureMaterializationProvenanceStore.write(
                try OmiLaunchCaptureMaterializationProvenanceStore.encode(provenance),
                to: paths.provenanceURL,
                io: io
            )
        } catch {
            let reason = self.reportAfterCleanup(temporaryURL, partition: partition, isRepair: isRepair, reason: "provenance")
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: reason))
        }
        do { try io.atomicReplaceItem(at: temporaryURL, with: audioURL) } catch {
            let reason = self.reportAfterCleanup(temporaryURL, partition: partition, isRepair: isRepair, reason: "replace")
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: reason))
        }
        do {
            let envelope = OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [])
            try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: envelopeURL, io: io)
        } catch {
            if isRepair {
                return .failure(self.persistFailure(partition, isRepair: true, reason: "envelope"))
            }
            let existingOutput: ExistingOutput
            do {
                existingOutput = try self.existingOutput(audioURL: audioURL, envelopeURL: envelopeURL)
            } catch {
                self.noteAttention(partition.ordinal, reason: "exists")
                return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: "exists"))
            }
            let reason: String
            if self.quarantineExistingOutput(audioURL: audioURL, envelopeURL: envelopeURL, existingOutput: existingOutput) {
                self.noteAttention(partition.ordinal, reason: "envelope")
                reason = "envelope"
            } else {
                self.noteAttention(partition.ordinal, reason: "quarantine")
                reason = "quarantine"
            }
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: reason))
        }
        // The retained record is inert because recognition requires an absent envelope; deleting it consumed injected remove faults and changed convergence.
        return .output(self.output(itemID: itemID, partition: partition, audioURL: audioURL, envelopeURL: envelopeURL, isExistingOwner: false))
    }

    private func output(itemID: UUID, partition: Partition, audioURL: URL, envelopeURL: URL, isExistingOwner: Bool) -> OmiLaunchCaptureMaterializedPartition {
        OmiLaunchCaptureMaterializedPartition(
            itemID: itemID,
            audioURL: audioURL,
            envelopeURL: envelopeURL,
            coveredThroughSequence: partition.endsAtSourceFrameBoundary ? partition.terminalSequence : nil,
            endsAtSourceFrameBoundary: partition.endsAtSourceFrameBoundary,
            isExistingOwner: isExistingOwner
        )
    }

    private func makePartition(ordinal: Int, startSequence: UInt64, startSampleOffset: UInt64, startedAt: Date) -> PartitionOutcome {
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generationID, partitionOrdinal: ordinal, startSequence: startSequence, startSampleOffset: startSampleOffset)
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: rootURL, generationID: generationID, ordinal: ordinal)
        let growth: GrowthOutput
        do {
            growth = try self.persistedBoundaryForGrowth(itemID: itemID, partition: ordinal, startSequence: startSequence, startSampleOffset: startSampleOffset, paths: paths)
        } catch {
            self.noteAttention(ordinal, reason: "exists")
            return .failure(OmiLaunchCaptureMaterializationFailure(partitionOrdinal: ordinal, reason: "exists"))
        }
        switch growth {
        case .fresh:
            return .partition(Partition(ordinal: ordinal, startSequence: startSequence, startSampleOffset: startSampleOffset, startedAt: startedAt, samples: [], terminalSequence: nil, sealedSampleCount: nil, isRecognizedOrphan: false))
        case .persisted(let boundary):
            return .partition(Partition(ordinal: ordinal, startSequence: startSequence, startSampleOffset: startSampleOffset, startedAt: startedAt, samples: [], terminalSequence: nil, sealedSampleCount: boundary.sampleCount, isRecognizedOrphan: false))
        case .recognizedOrphan:
            return .partition(Partition(ordinal: ordinal, startSequence: startSequence, startSampleOffset: startSampleOffset, startedAt: startedAt, samples: [], terminalSequence: nil, sealedSampleCount: nil, isRecognizedOrphan: true))
        }
    }

    private func persistedBoundaryForGrowth(itemID: UUID, partition ordinal: Int, startSequence: UInt64, startSampleOffset: UInt64, paths: OmiLaunchCaptureMaterializedArtifactPaths) throws -> GrowthOutput {
        let hasEnvelope = try io.fileExists(at: paths.envelopeURL)
        let hasAudio = try io.fileExists(at: paths.audioURL)
        guard hasEnvelope else {
            guard hasAudio else { return .fresh }
            guard self.orphanRecognition(
                paths: paths,
                itemID: itemID,
                ordinal: ordinal,
                startSequence: startSequence,
                startSampleOffset: startSampleOffset,
                existingOutput: ExistingOutput(hasAudio: hasAudio, hasEnvelope: hasEnvelope)
            ) == .recognized else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return .recognizedOrphan
        }
        guard let boundary = self.persistedBoundary(itemID: itemID, ordinal: ordinal, envelopeURL: paths.envelopeURL, hasAudio: hasAudio) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return .persisted(boundary)
    }

    private func persistedBoundary(itemID: UUID, ordinal: Int, envelopeURL: URL, hasAudio: Bool) -> PersistedBoundary? {
        guard let envelope = try? OmiPendingHandoffStore.read(from: envelopeURL),
              envelope.isSupported,
              envelope.itemID == itemID,
              envelope.sidecar.chunkIndex == ordinal
        else { return nil }
        let samples = envelope.sidecar.durationS * OmiAudioChunkFormat.sampleRate
        let rounded = samples.rounded()
        guard samples > 0,
              abs(samples - rounded) <= Double.ulpOfOne * 8,
              rounded <= Double(OmiAudioChunkFormat.sampleLimit)
        else { return nil }
        return PersistedBoundary(sampleCount: Int(rounded), hasAudio: hasAudio)
    }

    private func sidecar(for partition: Partition) -> ChunkSidecar {
        let duration = Double(partition.samples.count) / OmiAudioChunkFormat.sampleRate
        return ChunkSidecar(segment: ObserverSegmentNaming.segmentString(for: partition.startedAt, durationSeconds: duration), day: ObserverSegmentNaming.dayString(for: partition.startedAt), chunkIndex: partition.ordinal, startedAt: partition.startedAt, durationS: duration, sessionID: generationID, mode: .meeting, locationJSONL: nil)
    }

    private func existingOutput(audioURL: URL, envelopeURL: URL) throws -> ExistingOutput {
        ExistingOutput(hasAudio: try io.fileExists(at: audioURL), hasEnvelope: try io.fileExists(at: envelopeURL))
    }

    private func orphanRecognition(paths: OmiLaunchCaptureMaterializedArtifactPaths, itemID: UUID, partition: Partition, existingOutput: ExistingOutput) -> OrphanRecognition {
        self.orphanRecognition(
            paths: paths,
            itemID: itemID,
            ordinal: partition.ordinal,
            startSequence: partition.startSequence,
            startSampleOffset: partition.startSampleOffset,
            existingOutput: existingOutput
        )
    }

    private func orphanRecognition(paths: OmiLaunchCaptureMaterializedArtifactPaths, itemID: UUID, ordinal: Int, startSequence: UInt64, startSampleOffset: UInt64, existingOutput: ExistingOutput) -> OrphanRecognition {
        guard existingOutput.hasAudio, !existingOutput.hasEnvelope else { return .mismatch }
        let hasProvenance: Bool
        do {
            hasProvenance = try io.fileExists(at: paths.provenanceURL)
        } catch {
            return .ioFailure
        }
        guard hasProvenance else { return .mismatch }
        let provenance: OmiLaunchCaptureMaterializationProvenance
        do {
            provenance = try OmiLaunchCaptureMaterializationProvenanceStore.read(from: paths.provenanceURL)
        } catch is DecodingError {
            return .mismatch
        } catch {
            return .ioFailure
        }
        guard provenance.isSupported
            && provenance.generationID == generationID
            && provenance.partitionOrdinal == ordinal
            && provenance.startSequence == startSequence
            && provenance.startSampleOffset == startSampleOffset
            && provenance.itemID == itemID
        else { return .mismatch }
        return .recognized
    }

    private func isReusable(existingOutput: ExistingOutput, envelopeURL: URL, itemID: UUID, sidecar: ChunkSidecar) -> Bool {
        guard existingOutput.hasAudio, existingOutput.hasEnvelope else { return false }
        guard let envelope = try? OmiPendingHandoffStore.read(from: envelopeURL) else { return false }
        return envelope.isSupported && envelope.itemID == itemID && envelope.sidecar.chunkIndex == sidecar.chunkIndex && envelope.sidecar.durationS == sidecar.durationS
    }

    private func quarantineExistingOutput(audioURL: URL, envelopeURL: URL, existingOutput: ExistingOutput) -> Bool {
        self.quarantineIfPresent(audioURL, isPresent: existingOutput.hasAudio) && self.quarantineIfPresent(envelopeURL, isPresent: existingOutput.hasEnvelope)
    }

    private func quarantineIfPresent(_ url: URL, isPresent: Bool) -> Bool {
        guard isPresent else { return true }
        let root = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName, isDirectory: true).appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
        let destination = root.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        do {
            try io.moveItem(at: url, to: destination)
            return true
        } catch {
            return false
        }
    }

    private func reportAfterCleanup(_ url: URL, partition: Partition, isRepair: Bool, reason: String) -> String {
        do {
            try io.removeItem(at: url)
            self.failPersist(partition, isRepair: isRepair, reason: reason)
            return reason
        } catch {
            self.failPersist(partition, isRepair: isRepair, reason: "cleanup")
            return "cleanup"
        }
    }

    private func persistFailure(_ partition: Partition, isRepair: Bool, reason: String) -> OmiLaunchCaptureMaterializationFailure {
        self.failPersist(partition, isRepair: isRepair, reason: reason)
        return OmiLaunchCaptureMaterializationFailure(partitionOrdinal: partition.ordinal, reason: reason)
    }

    private func append(_ output: OmiLaunchCaptureMaterializedPartition, to outputs: inout [OmiLaunchCaptureMaterializedPartition], coveredThroughSequence: inout UInt64?) {
        outputs.append(output)
        if let sequence = output.coveredThroughSequence {
            coveredThroughSequence = sequence
        }
    }

    private func failPersist(_ partition: Partition, isRepair: Bool, reason: String) {
        self.noteAttention(partition.ordinal, reason: reason)
        if isRepair { self.noteRepairFailure(partition) }
    }

    private func noteRepairFailure(_ partition: Partition) {
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generationID, partitionOrdinal: partition.ordinal, startSequence: partition.startSequence, startSampleOffset: partition.startSampleOffset)
        let failure = OmiLaunchCaptureOrphanRepairFailure(ordinal: partition.ordinal, itemID: itemID)
        if !self.orphanRepairFailures.contains(failure) {
            self.orphanRepairFailures.append(failure)
        }
    }

    private func noteAttention(_ partition: Int, reason: String) {
        diagnosticLog?.append(category: .diagnostics, severity: .warning, message: "needs attention", detail: "generation=\(generationID.uuidString.lowercased()) partition=\(partition) reason=\(reason)")
    }
}
