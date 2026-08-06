// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated struct OmiLaunchCaptureMarkerObservation: Equatable, Sendable {
    let epoch: UInt32
    let acquiredAt: Date
}

nonisolated struct OmiLaunchCaptureMaterializedPartition: Equatable, Sendable {
    let itemID: UUID
    let ordinal: Int
    let audioURL: URL
    let envelopeURL: URL
}

nonisolated struct OmiLaunchCaptureMaterializationResult: Equatable, Sendable {
    let partitions: [OmiLaunchCaptureMaterializedPartition]
    let markers: [OmiLaunchCaptureMarkerObservation]
    let rebootEvents: [OmiDiagnosticsPayload.PendantRebootEvent]
}

@MainActor
final class OmiLaunchCaptureMaterializer {
    private static let materializedDirectoryName = "Materialized"

    private struct Partition {
        let ordinal: Int
        let startSequence: UInt64
        let startSampleOffset: UInt64
        let startedAt: Date
        var samples: [Int16]
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
        var position = OmiLaunchCaptureReadPosition(generationID: generationID, nextSequence: 0, offset: 0)
        var reassembler = OmiAudioReassembler()
        var current: Partition?
        var outputs: [OmiLaunchCaptureMaterializedPartition] = []
        var markers: [OmiLaunchCaptureMarkerObservation] = []
        var sampleOffset: UInt64 = 0
        var nextOrdinal = 0
        var decodeFailures: Set<Int> = []

        while case .lease(let lease) = reader.lease(from: position) {
            self.peakLeaseResidentPayloadBytes = max(self.peakLeaseResidentPayloadBytes, reader.peakLeaseResidentPayloadBytes)
            for record in lease.records {
                let acquiredAt = Date(timeIntervalSince1970: Double(record.acquiredAtUnixMicros) / 1_000_000)
                let output = reassembler.ingest(record.payload, acquiredAt: acquiredAt)
                markers.append(contentsOf: output.markers.map { OmiLaunchCaptureMarkerObservation(epoch: $0.epoch, acquiredAt: acquiredAt) })
                self.consume(output.completedFrames, sequence: record.sequence, current: &current, sampleOffset: &sampleOffset, nextOrdinal: &nextOrdinal, decodeFailures: &decodeFailures, outputs: &outputs)
            }
            position = OmiLaunchCaptureReadPosition(generationID: generationID, nextSequence: lease.throughSequence + 1, offset: lease.endOffset)
        }
        self.consume(reassembler.flushFinalFrame().completedFrames, sequence: position.nextSequence, current: &current, sampleOffset: &sampleOffset, nextOrdinal: &nextOrdinal, decodeFailures: &decodeFailures, outputs: &outputs)
        if let current, !current.samples.isEmpty, let output = self.persist(current) { outputs.append(output) }
        return OmiLaunchCaptureMaterializationResult(partitions: outputs, markers: markers, rebootEvents: OmiDiagnosticsLogic.pendantRebootEvents(from: markers.map { (observedAt: $0.acquiredAt, epoch: $0.epoch) }))
    }

    private func consume(_ frames: [OmiReassembledFrame], sequence: UInt64, current: inout Partition?, sampleOffset: inout UInt64, nextOrdinal: inout Int, decodeFailures: inout Set<Int>, outputs: inout [OmiLaunchCaptureMaterializedPartition]) {
        for frame in frames {
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
            let alreadyWritten = current?.samples.count ?? 0
            let slices = OmiSamplePartitioner.partitions(samples: decoded, alreadyWritten: alreadyWritten, sampleLimit: OmiAudioChunkFormat.sampleLimit)
            for slice in slices {
                if current == nil {
                    current = Partition(ordinal: nextOrdinal, startSequence: sequence, startSampleOffset: sampleOffset, startedAt: frame.acquiredAt, samples: [])
                    nextOrdinal += 1
                }
                current!.samples.append(contentsOf: slice)
                self.peakOpenPartitionSampleCount = max(self.peakOpenPartitionSampleCount, current!.samples.count)
                sampleOffset += UInt64(slice.count)
                if current!.samples.count == OmiAudioChunkFormat.sampleLimit {
                    let finished = current!
                    if let output = persist(finished) { outputs.append(output) }
                    let successor = finished.startedAt.addingTimeInterval(Double(finished.samples.count) / OmiAudioChunkFormat.sampleRate)
                    current = Partition(ordinal: nextOrdinal, startSequence: sequence, startSampleOffset: sampleOffset, startedAt: successor, samples: [])
                    nextOrdinal += 1
                }
            }
        }
    }

    private func persist(_ partition: Partition) -> OmiLaunchCaptureMaterializedPartition? {
        let chunkID = OmiSegmentWriter.chunkID(sessionID: generationID, index: partition.ordinal)
        let directory = rootURL.appendingPathComponent(Self.materializedDirectoryName, isDirectory: true).appendingPathComponent(generationID.uuidString, isDirectory: true)
        let audioURL = directory.appendingPathComponent(chunkID).appendingPathExtension("m4a")
        let envelopeURL = OmiPendingHandoffStore.url(for: audioURL)
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generationID, partitionOrdinal: partition.ordinal, startSequence: partition.startSequence, startSampleOffset: partition.startSampleOffset)
        let sidecar = self.sidecar(for: partition)
        if self.isReusable(audioURL: audioURL, envelopeURL: envelopeURL, itemID: itemID, sidecar: sidecar) {
            return OmiLaunchCaptureMaterializedPartition(itemID: itemID, ordinal: partition.ordinal, audioURL: audioURL, envelopeURL: envelopeURL)
        }
        guard self.quarantineExistingOutput(audioURL: audioURL, envelopeURL: envelopeURL) else {
            self.noteAttention(partition.ordinal, reason: "quarantine")
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
            if self.quarantineExistingOutput(audioURL: audioURL, envelopeURL: envelopeURL) {
                self.noteAttention(partition.ordinal, reason: "envelope")
            } else {
                self.noteAttention(partition.ordinal, reason: "quarantine")
            }
            return nil
        }
        return OmiLaunchCaptureMaterializedPartition(itemID: itemID, ordinal: partition.ordinal, audioURL: audioURL, envelopeURL: envelopeURL)
    }

    private func sidecar(for partition: Partition) -> ChunkSidecar {
        let duration = Double(partition.samples.count) / OmiAudioChunkFormat.sampleRate
        return ChunkSidecar(segment: ObserverSegmentNaming.segmentString(for: partition.startedAt, durationSeconds: duration), day: ObserverSegmentNaming.dayString(for: partition.startedAt), chunkIndex: partition.ordinal, startedAt: partition.startedAt, durationS: duration, sessionID: generationID, mode: .meeting, locationJSONL: nil)
    }

    private func isReusable(audioURL: URL, envelopeURL: URL, itemID: UUID, sidecar: ChunkSidecar) -> Bool {
        guard (try? io.fileExists(at: audioURL)) == true, (try? io.fileExists(at: envelopeURL)) == true else { return false }
        guard let envelope = try? OmiPendingHandoffStore.read(from: envelopeURL) else { return false }
        return envelope.isSupported && envelope.itemID == itemID && envelope.sidecar.chunkIndex == sidecar.chunkIndex && envelope.sidecar.startedAt == sidecar.startedAt && envelope.sidecar.durationS == sidecar.durationS
    }

    private func quarantineExistingOutput(audioURL: URL, envelopeURL: URL) -> Bool {
        self.quarantineIfPresent(audioURL) && self.quarantineIfPresent(envelopeURL)
    }

    private func quarantineIfPresent(_ url: URL) -> Bool {
        guard (try? io.fileExists(at: url)) == true else { return true }
        let root = rootURL.appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName, isDirectory: true).appendingPathComponent(Self.materializedDirectoryName, isDirectory: true)
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
