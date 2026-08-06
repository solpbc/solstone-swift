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

nonisolated struct OmiLaunchCaptureMaterializationResult: Equatable, Sendable {
    let partitions: [OmiLaunchCaptureMaterializedPartition]
    let markers: [OmiLaunchCaptureMarkerObservation]
    let verifiedPrefixEndOffset: Int
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
    }

    private struct ExistingOutput {
        let hasAudio: Bool
        let hasEnvelope: Bool
    }

    private struct PersistedBoundary {
        let sampleCount: Int
        let hasAudio: Bool
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
        guard let initialPosition = self.reader.acknowledgedPosition() else {
            return OmiLaunchCaptureMaterializationResult(partitions: [], markers: [], verifiedPrefixEndOffset: 0)
        }
        var position = initialPosition
        var reassembler = OmiAudioReassembler()
        var current: Partition?
        var outputs: [OmiLaunchCaptureMaterializedPartition] = []
        var markers: [OmiLaunchCaptureMarkerObservation] = []
        var sampleOffset: UInt64 = 0
        var nextOrdinal = 0
        var decodeFailures: Set<Int> = []
        var verifiedPrefixEndOffset = position.offset

        while case .lease(let lease) = reader.lease(from: position) {
            self.peakLeaseResidentPayloadBytes = max(self.peakLeaseResidentPayloadBytes, reader.peakLeaseResidentPayloadBytes)
            for record in lease.records {
                let acquiredAt = Date(timeIntervalSince1970: Double(record.acquiredAtUnixMicros) / 1_000_000)
                let output = reassembler.ingest(record.payload, acquiredAt: acquiredAt, recordSequence: record.sequence)
                markers.append(contentsOf: output.markers.map { OmiLaunchCaptureMarkerObservation(epoch: $0.epoch, acquiredAt: acquiredAt, sequence: record.sequence) })
                self.consume(output.completedFrames, current: &current, sampleOffset: &sampleOffset, nextOrdinal: &nextOrdinal, decodeFailures: &decodeFailures, outputs: &outputs)
            }
            position = OmiLaunchCaptureReadPosition(generationID: generationID, nextSequence: lease.throughSequence + 1, offset: lease.endOffset)
            verifiedPrefixEndOffset = lease.endOffset
        }
        self.consume(reassembler.flushFinalFrame().completedFrames, current: &current, sampleOffset: &sampleOffset, nextOrdinal: &nextOrdinal, decodeFailures: &decodeFailures, outputs: &outputs)
        if let current, !current.samples.isEmpty, let output = self.persist(current) { outputs.append(output) }
        return OmiLaunchCaptureMaterializationResult(partitions: outputs, markers: markers, verifiedPrefixEndOffset: verifiedPrefixEndOffset)
    }

    private func consume(_ frames: [OmiReassembledFrame], current: inout Partition?, sampleOffset: inout UInt64, nextOrdinal: inout Int, decodeFailures: inout Set<Int>, outputs: inout [OmiLaunchCaptureMaterializedPartition]) {
        for frame in frames {
            guard let startSequence = frame.startSequence else { continue }
            guard let decoded = decode(frame.data), !decoded.isEmpty else {
                let ordinal = current?.ordinal ?? nextOrdinal
                if decodeFailures.insert(ordinal).inserted { self.noteAttention(ordinal, reason: "decode") }
                continue
            }
            if let currentPartition = current,
               !currentPartition.samples.isEmpty,
               frame.acquiredAt.timeIntervalSince(currentPartition.startedAt) >= OmiAudioChunkFormat.chunkDurationSeconds {
                if let output = persist(currentPartition) { outputs.append(output) }
                current = nil
            }
            var remaining = ArraySlice(decoded)
            while !remaining.isEmpty {
                if let currentPartition = current, currentPartition.samples.isEmpty {
                    current = Partition(ordinal: currentPartition.ordinal, startSequence: startSequence, startSampleOffset: currentPartition.startSampleOffset, startedAt: currentPartition.startedAt, samples: [], terminalSequence: nil, sealedSampleCount: currentPartition.sealedSampleCount)
                }
                if current == nil {
                    guard let partition = self.makePartition(ordinal: nextOrdinal, startSequence: startSequence, startSampleOffset: sampleOffset, startedAt: frame.acquiredAt) else { return }
                    current = partition
                    nextOrdinal += 1
                }
                let limit = current!.sealedSampleCount ?? OmiAudioChunkFormat.sampleLimit
                let available = limit - current!.samples.count
                guard available > 0 else { return }
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
                    if let output = persist(finished) { outputs.append(output) }
                    if remaining.isEmpty {
                        current = nil
                    } else {
                        let successor = finished.startedAt.addingTimeInterval(Double(finished.samples.count) / OmiAudioChunkFormat.sampleRate)
                        guard let partition = self.makePartition(ordinal: nextOrdinal, startSequence: finished.startSequence, startSampleOffset: sampleOffset, startedAt: successor) else { return }
                        current = partition
                        nextOrdinal += 1
                    }
                }
            }
        }
    }

    private func persist(_ partition: Partition) -> OmiLaunchCaptureMaterializedPartition? {
        let chunkID = OmiSegmentWriter.chunkID(sessionID: generationID, index: partition.ordinal)
        let directory = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true).appendingPathComponent(generationID.uuidString, isDirectory: true)
        let audioURL = directory.appendingPathComponent(chunkID).appendingPathExtension("m4a")
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generationID, partitionOrdinal: partition.ordinal, startSequence: partition.startSequence, startSampleOffset: partition.startSampleOffset)
        let sidecar = self.sidecar(for: partition)
        let existingOutput: ExistingOutput
        do {
            existingOutput = try self.existingOutput(audioURL: audioURL, envelopeURL: envelopeURL)
        } catch {
            self.noteAttention(partition.ordinal, reason: "exists")
            return nil
        }
        if let boundary = self.persistedBoundary(
            itemID: itemID,
            ordinal: partition.ordinal,
            envelopeURL: envelopeURL,
            hasAudio: existingOutput.hasAudio
        ) {
            guard boundary.sampleCount == partition.samples.count else {
                self.noteAttention(partition.ordinal, reason: "sealed")
                return nil
            }
            if boundary.hasAudio, !self.isReusable(existingOutput: existingOutput, envelopeURL: envelopeURL, itemID: itemID, sidecar: sidecar) {
                self.noteAttention(partition.ordinal, reason: "sealed")
                return nil
            }
            return self.output(
                itemID: itemID,
                partition: partition,
                audioURL: audioURL,
                envelopeURL: envelopeURL,
                isExistingOwner: !boundary.hasAudio
            )
        }
        guard !existingOutput.hasAudio, !existingOutput.hasEnvelope else {
            self.noteAttention(partition.ordinal, reason: "sealed")
            return nil
        }
        let temporaryURL = directory.appendingPathComponent(".\(chunkID)-\(UUID().uuidString.lowercased()).tmp.m4a")
        do { try io.ensureDirectory(at: directory) } catch { self.noteAttention(partition.ordinal, reason: "audio-open"); return nil }
        let writer = makeWriter()
        do { try writer.open(at: temporaryURL) } catch { self.noteAttention(partition.ordinal, reason: "audio-open"); return nil }
        do { try writer.write(samples: partition.samples[...]) } catch {
            try? writer.close()
            self.reportAfterCleanup(temporaryURL, partition: partition.ordinal, reason: "audio-write")
            return nil
        }
        do { try writer.close() } catch {
            self.reportAfterCleanup(temporaryURL, partition: partition.ordinal, reason: "audio-sync")
            return nil
        }
        do { try writer.synchronize(at: temporaryURL) } catch {
            self.reportAfterCleanup(temporaryURL, partition: partition.ordinal, reason: "audio-sync")
            return nil
        }
        do { try io.atomicReplaceItem(at: temporaryURL, with: audioURL) } catch {
            self.reportAfterCleanup(temporaryURL, partition: partition.ordinal, reason: "replace")
            return nil
        }
        do {
            let envelope = OmiPendingHandoffEnvelope(itemID: itemID, sidecar: sidecar, metadata: nil, frozenTokens: [])
            try OmiPendingHandoffStore.write(try OmiPendingHandoffStore.encode(envelope), to: envelopeURL, io: io)
        } catch {
            let existingOutput: ExistingOutput
            do {
                existingOutput = try self.existingOutput(audioURL: audioURL, envelopeURL: envelopeURL)
            } catch {
                self.noteAttention(partition.ordinal, reason: "exists")
                return nil
            }
            if self.quarantineExistingOutput(audioURL: audioURL, envelopeURL: envelopeURL, existingOutput: existingOutput) {
                self.noteAttention(partition.ordinal, reason: "envelope")
            } else {
                self.noteAttention(partition.ordinal, reason: "quarantine")
            }
            return nil
        }
        return self.output(itemID: itemID, partition: partition, audioURL: audioURL, envelopeURL: envelopeURL, isExistingOwner: false)
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

    private func makePartition(ordinal: Int, startSequence: UInt64, startSampleOffset: UInt64, startedAt: Date) -> Partition? {
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generationID, partitionOrdinal: ordinal, startSequence: startSequence, startSampleOffset: startSampleOffset)
        let chunkID = OmiSegmentWriter.chunkID(sessionID: generationID, index: ordinal)
        let directory = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true).appendingPathComponent(generationID.uuidString, isDirectory: true)
        let audioURL = directory.appendingPathComponent(chunkID).appendingPathExtension("m4a")
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        let boundary: PersistedBoundary?
        do {
            boundary = try self.persistedBoundaryForGrowth(itemID: itemID, ordinal: ordinal, envelopeURL: envelopeURL, audioURL: audioURL)
        } catch {
            self.noteAttention(ordinal, reason: "exists")
            return nil
        }
        return Partition(ordinal: ordinal, startSequence: startSequence, startSampleOffset: startSampleOffset, startedAt: startedAt, samples: [], terminalSequence: nil, sealedSampleCount: boundary?.sampleCount)
    }

    private func persistedBoundaryForGrowth(itemID: UUID, ordinal: Int, envelopeURL: URL, audioURL: URL) throws -> PersistedBoundary? {
        let hasEnvelope = try io.fileExists(at: envelopeURL)
        let hasAudio = try io.fileExists(at: audioURL)
        guard hasEnvelope else {
            guard !hasAudio else { throw CocoaError(.fileReadCorruptFile) }
            return nil
        }
        guard let boundary = self.persistedBoundary(itemID: itemID, ordinal: ordinal, envelopeURL: envelopeURL, hasAudio: hasAudio) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return boundary
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

    private func reportAfterCleanup(_ url: URL, partition: Int, reason: String) {
        do {
            try io.removeItem(at: url)
            self.noteAttention(partition, reason: reason)
        } catch {
            self.noteAttention(partition, reason: "cleanup")
        }
    }

    private func noteAttention(_ partition: Int, reason: String) {
        diagnosticLog?.append(category: .diagnostics, severity: .warning, message: "needs attention", detail: "generation=\(generationID.uuidString.lowercased()) partition=\(partition) reason=\(reason)")
    }
}
