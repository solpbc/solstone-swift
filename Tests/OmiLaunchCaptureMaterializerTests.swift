// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation
import Opus
import XCTest

@MainActor
final class OmiLaunchCaptureMaterializerTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("OmiLaunchCaptureMaterializerTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: self.rootURL) }

    func testKnownSplitFramesAndMarkersMaterializeInSourceOrder() throws {
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        let frame = try Self.opusFrame()
        Self.append(Self.marker(packet: 0, epoch: 1_700_000_000), to: writer)
        clock.advance(by: 1)
        Self.append(Self.packet(1, index: 0, body: frame.prefix(8)), to: writer)
        clock.advance(by: 1)
        Self.append(Self.packet(2, index: 1, body: frame.dropFirst(8)), to: writer)
        clock.advance(by: 1)
        Self.append(Self.marker(packet: 3, epoch: 10), to: writer)
        let decoder = try OmiOpusAudioDecoder()
        let result = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { decoder.decode($0) }).materialize()

        XCTAssertEqual(result.markers.map(\.epoch), [1_700_000_000, 10])
        XCTAssertEqual(result.markers.map(\.acquiredAt), [Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_000_003)])
        let output = try XCTUnwrap(result.partitions.only)
        let envelope = try OmiPendingHandoffStore.read(from: output.envelopeURL)
        XCTAssertEqual(envelope.sidecar.startedAt, Date(timeIntervalSince1970: 1_800_000_001))
        let file = try AVAudioFile(forReading: output.audioURL)
        XCTAssertEqual(file.length, 320)
    }

    func testFractionalAcquisitionTimeReusesArtifactByteForByteWithoutQuarantine() throws {
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000.123_456))
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        Self.append(Self.packet(0, index: 0, body: try Self.opusFrame()), to: writer)

        let firstDecoder = try OmiOpusAudioDecoder()
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { firstDecoder.decode($0) }).materialize()
        let firstOutput = try XCTUnwrap(first.partitions.only)
        let audioBytes = try Data(contentsOf: firstOutput.audioURL)
        let envelopeBytes = try Data(contentsOf: firstOutput.envelopeURL)

        let secondDecoder = try OmiOpusAudioDecoder()
        let second = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { secondDecoder.decode($0) }).materialize()

        XCTAssertEqual(second.partitions.only?.itemID, firstOutput.itemID)
        XCTAssertEqual(try Data(contentsOf: firstOutput.audioURL), audioBytes)
        XCTAssertEqual(try Data(contentsOf: firstOutput.envelopeURL), envelopeBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName).path))
    }

    func testSampleCapRuleProducesMidFramePartitionsWithoutDroppedOrRepeatedSamples() {
        let generation = UUID()
        let clock = MockObserverClock()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        let samplesPerFrame = 1_000_003
        let frameCount = 15
        for packet in 0..<frameCount {
            Self.append(Self.packet(UInt16(packet), index: 0, body: Data([UInt8(packet)])), to: writer)
            clock.advance(by: 1)
        }
        let store = MaterializedSamples()
        // Synthetic PCM is required here because a tractable fixture must split a decoded frame across the sample cap.
        let decoder = PositionDerivedSamples(samplesPerFrame: samplesPerFrame)
        let materializer = OmiLaunchCaptureMaterializer(
            rootURL: rootURL,
            generationID: generation,
            makeWriter: { RecordingOmiAACChunkWriter(store: store) },
            decode: { _ in decoder.nextFrame() }
        )
        let result = materializer.materialize()

        let totalSamples = samplesPerFrame * frameCount
        XCTAssertLessThan(Double(frameCount - 1), OmiAudioChunkFormat.chunkDurationSeconds, "sample-cap fixture must not reach the acquisition-span rule")
        XCTAssertEqual(result.partitions.count, 4, "sample-cap rule must close mid-frame partitions")
        XCTAssertEqual(store.chunks.map(\.count), [OmiAudioChunkFormat.sampleLimit, OmiAudioChunkFormat.sampleLimit, OmiAudioChunkFormat.sampleLimit, totalSamples - (OmiAudioChunkFormat.sampleLimit * 3)])
        XCTAssertTrue(store.chunks.allSatisfy { $0.count <= OmiAudioChunkFormat.sampleLimit })
        XCTAssertEqual(store.chunkStartOffsets, [0, OmiAudioChunkFormat.sampleLimit, OmiAudioChunkFormat.sampleLimit * 2, OmiAudioChunkFormat.sampleLimit * 3])
        XCTAssertEqual(store.totalSampleCount, totalSamples)

        let cap = OmiAudioChunkFormat.sampleLimit
        let triggerStart = samplesPerFrame * 4
        let triggerEnd = triggerStart + samplesPerFrame
        XCTAssertLessThan(triggerStart, cap)
        XCTAssertGreaterThan(triggerEnd, cap)
        let triggerBeforeCap = Array(store.chunks[0].suffix(cap - triggerStart))
        let triggerAfterCap = Array(store.chunks[1].prefix(triggerEnd - cap))
        let expectedTrigger = (triggerStart..<triggerEnd).map(PositionDerivedSamples.sample(at:))
        XCTAssertEqual(triggerBeforeCap + triggerAfterCap, expectedTrigger, "the frame straddling the cap must remain contiguous across the rotation")
        XCTAssertEqual(triggerBeforeCap.last, PositionDerivedSamples.sample(at: cap - 1))
        XCTAssertEqual(triggerAfterCap.first, PositionDerivedSamples.sample(at: cap))

        var outputPosition = 0
        for chunk in store.chunks {
            let expected = (outputPosition..<(outputPosition + chunk.count)).map(PositionDerivedSamples.sample(at:))
            XCTAssertEqual(chunk, expected, "sample stream must contain every position exactly once, in order")
            outputPosition += chunk.count
        }
        XCTAssertEqual(outputPosition, totalSamples)
    }

    func testAcquisitionSpanRuleProducesThreePartitionsBelowSampleCap() {
        let generation = UUID()
        let clock = MockObserverClock()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        for packet in 0..<3 {
            Self.append(Self.packet(UInt16(packet), index: 0, body: Data([UInt8(packet)])), to: writer)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }
        let store = MaterializedSamples()
        // Synthetic PCM keeps this sparse acquisition-time fixture focused on rotation rather than Opus frame sizing.
        let result = OmiLaunchCaptureMaterializer(
            rootURL: rootURL,
            generationID: generation,
            makeWriter: { RecordingOmiAACChunkWriter(store: store) },
            decode: { frame in Array(repeating: Int16(frame.first ?? 0), count: 160) }
        ).materialize()

        XCTAssertEqual(result.partitions.count, 3, "acquisition-span rule must rotate sparse frames")
        XCTAssertEqual(store.chunks.map(\.count), [160, 160, 160])
        XCTAssertTrue(store.chunks.allSatisfy { $0.count < OmiAudioChunkFormat.sampleLimit })
    }

    func testFaultsAtEveryProtocolPointConvergeOnReopenWithStableIdentity() throws {
        for fault in OmiAACChunkWriterFault.allCases {
            let generation = UUID()
            let io = FaultInjectingOmiLaunchCaptureIO()
            let clock = MockObserverClock()
            let capture = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock, io: io)
            Self.append(Self.packet(0, index: 0, body: Data([1])), to: capture)
            let failingWriter = FaultInjectingOmiAACChunkWriter(io: io)
            failingWriter.failNext(fault)
            let failing = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, makeWriter: { failingWriter }, decode: { _ in [1, 2, 3] })
            XCTAssertTrue(failing.materialize().partitions.isEmpty)
            try io.restoreLastSynchronizedState()
            let store = MaterializedSamples()
            let recovered = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, makeWriter: { RecordingOmiAACChunkWriter(store: store) }, decode: { _ in [1, 2, 3] }).materialize()
            let output = try XCTUnwrap(recovered.partitions.only)
            let recoveredAudio = try Data(contentsOf: output.audioURL)
            let recoveredEnvelope = try Data(contentsOf: output.envelopeURL)
            let repeated = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, makeWriter: { RecordingOmiAACChunkWriter(store: store) }, decode: { _ in [1, 2, 3] }).materialize()
            XCTAssertEqual(repeated.partitions.map(\.itemID), [output.itemID])
            XCTAssertEqual(repeated.partitions.count, 1)
            XCTAssertEqual(try Data(contentsOf: output.audioURL), recoveredAudio)
            XCTAssertEqual(try Data(contentsOf: output.envelopeURL), recoveredEnvelope)
        }
    }

    func testReplaceAndEnvelopeFaultsConvergeOnReopen() throws {
        for fault in [OmiLaunchCaptureInjectedOperation.replace, .open] {
            let generation = UUID()
            let io = FaultInjectingOmiLaunchCaptureIO()
            let capture = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, io: io)
            Self.append(Self.packet(0, index: 0, body: Data([1])), to: capture)
            io.failNext(fault)
            let store = MaterializedSamples()
            XCTAssertTrue(OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, makeWriter: { RecordingOmiAACChunkWriter(store: store) }, decode: { _ in [1] }).materialize().partitions.isEmpty)
            try io.restoreLastSynchronizedState()
            let recovered = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, makeWriter: { RecordingOmiAACChunkWriter(store: store) }, decode: { _ in [1] }).materialize()
            XCTAssertEqual(recovered.partitions.count, 1)
        }
    }

    func testMaterializationFailureMatrixStopsAtSharedDurableFrontier() throws {
        enum FailurePoint: CaseIterable {
            case decode
            case reassembly
            case audioOpen
            case audioWrite
            case audioSync
            case replace
            case envelope

            var reason: String {
                switch self {
                case .decode: "decode"
                case .reassembly: "reassembly-discarded-frame"
                case .audioOpen: "audio-open"
                case .audioWrite: "audio-write"
                case .audioSync: "audio-sync"
                case .replace: "replace"
                case .envelope: "envelope"
                }
            }
        }

        let generation = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let baseRoot = rootURL.appendingPathComponent("durable-prefix", isDirectory: true)
        let baseClock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let baseCapture = OmiLaunchCaptureWriter(rootURL: baseRoot, generationID: generation, clock: baseClock)
        Self.append(Self.packet(0, index: 0, body: Data([0])), to: baseCapture)
        let prefix = OmiLaunchCaptureMaterializer(
            rootURL: baseRoot,
            generationID: generation,
            makeWriter: { RecordingOmiAACChunkWriter(store: MaterializedSamples()) },
            decode: { _ in [1] }
        ).materialize()
        let prefixOutput = try XCTUnwrap(prefix.partitions.only)
        let expectedAudio = try Data(contentsOf: prefixOutput.audioURL)
        let expectedEnvelope = try Data(contentsOf: prefixOutput.envelopeURL)

        for point in FailurePoint.allCases {
            let caseRoot = rootURL.appendingPathComponent("\(point)", isDirectory: true)
            try FileManager.default.copyItem(at: baseRoot, to: caseRoot)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
            let capture = OmiLaunchCaptureWriter(rootURL: caseRoot, generationID: generation, clock: clock, io: io)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
            for packet in 1..<4 {
                let packetNumber: UInt16 = point == .reassembly && packet == 3 ? 4 : UInt16(packet)
                Self.append(Self.packet(packetNumber, index: 0, body: Data([UInt8(packet)])), to: capture)
                clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
            }

            let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: caseRoot, generationID: generation, ordinal: 1)
            switch point {
            case .replace:
                io.failReplace(at: paths.audioURL, fromCall: 1)
            case .envelope:
                io.failReplace(at: paths.envelopeURL, fromCall: 1)
            default:
                break
            }

            let failingWriter = FaultInjectingOmiAACChunkWriter(io: io)
            switch point {
            case .audioOpen: failingWriter.failNext(.open)
            case .audioWrite: failingWriter.failNext(.write)
            case .audioSync: failingWriter.failNext(.synchronize)
            default: break
            }
            let samples = MaterializedSamples()
            var decodeCount = 0
            let result = OmiLaunchCaptureMaterializer(
                rootURL: caseRoot,
                generationID: generation,
                io: io,
                makeWriter: {
                    switch point {
                    case .audioOpen, .audioWrite, .audioSync: failingWriter
                    default: RecordingOmiAACChunkWriter(store: samples)
                    }
                },
                decode: { _ in
                    decodeCount += 1
                    return point == .decode && decodeCount == 3 ? nil : [1]
                }
            ).materialize()

            let output = try XCTUnwrap(result.partitions.only, "\(point)")
            XCTAssertEqual(result.coveredThroughSequence, 0, "\(point)")
            XCTAssertEqual(result.failure?.partitionOrdinal, 1, "\(point)")
            XCTAssertEqual(result.failure?.reason, point.reason, "\(point)")
            let audio = try Data(contentsOf: output.audioURL)
            let envelope = try Data(contentsOf: output.envelopeURL)
            XCTAssertEqual(audio, expectedAudio, "\(point)")
            XCTAssertEqual(envelope, expectedEnvelope, "\(point)")
        }
    }

    func testFailureStopsBeforeLaterRecordsAndDoesNotReplayLaterMarkers() {
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        Self.append(Self.packet(0, index: 0, body: Data([0])), to: writer)
        clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        Self.append(Self.marker(packet: 1, epoch: 1), to: writer)
        clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        Self.append(Self.packet(2, index: 0, body: Data([2])), to: writer)
        clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        Self.append(Self.packet(3, index: 0, body: Data([3])), to: writer)
        clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        Self.append(Self.packet(5, index: 0, body: Data([4])), to: writer)
        clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        Self.append(Self.marker(packet: 6, epoch: 2), to: writer)

        let result = OmiLaunchCaptureMaterializer(
            rootURL: rootURL,
            generationID: generation,
            makeWriter: { RecordingOmiAACChunkWriter(store: MaterializedSamples()) },
            decode: { _ in [1] }
        ).materialize()

        XCTAssertEqual(result.markers.map(\.epoch), [1])
        XCTAssertEqual(result.partitions.count, 1)
        XCTAssertEqual(result.failure?.reason, "reassembly-discarded-frame")
    }

    func testContinuationPacketGapStopsBeforeLaterFrame() {
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        for (packet, index) in [(0, UInt8(0)), (1, 0), (2, 0), (4, 1), (5, 0), (6, 0)] {
            Self.append(Self.packet(UInt16(packet), index: index, body: Data([UInt8(packet)])), to: writer)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }
        let store = MaterializedSamples()

        let result = OmiLaunchCaptureMaterializer(
            rootURL: rootURL,
            generationID: generation,
            makeWriter: { RecordingOmiAACChunkWriter(store: store) },
            decode: { _ in [1] }
        ).materialize()

        XCTAssertEqual(result.partitions.count, 1)
        XCTAssertEqual(result.coveredThroughSequence, 0)
        XCTAssertEqual(result.failure, OmiLaunchCaptureMaterializationFailure(partitionOrdinal: 1, reason: "reassembly-discarded-frame"))
        XCTAssertEqual(store.chunks, [[1]])
    }

    func testRemovingFailureReconvergesABCExactlyOnceWithStableIdentities() {
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        for packet in 0..<4 {
            Self.append(Self.packet(UInt16(packet), index: 0, body: Data([UInt8(packet)])), to: writer)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }
        var failedDecodeCount = 0
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, makeWriter: { RecordingOmiAACChunkWriter(store: MaterializedSamples()) }, decode: { _ in
            failedDecodeCount += 1
            return failedDecodeCount == 3 ? nil : [1]
        }).materialize()
        XCTAssertEqual(first.partitions.count, 1)
        XCTAssertEqual(first.coveredThroughSequence, 0)
        XCTAssertEqual(first.failure, OmiLaunchCaptureMaterializationFailure(partitionOrdinal: 1, reason: "decode"))

        let recovered = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, makeWriter: { RecordingOmiAACChunkWriter(store: MaterializedSamples()) }, decode: { _ in [1] }).materialize()
        XCTAssertEqual(recovered.partitions.count, 4)
        XCTAssertNil(recovered.failure)
        XCTAssertEqual(Set(recovered.partitions.map(\.itemID)).count, 4)
        XCTAssertEqual(Array(recovered.partitions.prefix(1).map(\.itemID)), first.partitions.map(\.itemID))
    }

    func testRestoredCrashRecomputesFailureFrontierAndReusesDurablePrefix() throws {
        let generation = UUID()
        let io = FaultInjectingOmiLaunchCaptureIO()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock, io: io)
        for packet in 0..<4 {
            Self.append(Self.packet(UInt16(packet), index: 0, body: Data([UInt8(packet)])), to: writer)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }
        var count = 0
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, decode: { _ in count += 1; return count == 3 ? nil : [1] }).materialize()
        XCTAssertEqual(first.partitions.count, 1)
        XCTAssertEqual(first.coveredThroughSequence, 0)
        XCTAssertEqual(first.failure, OmiLaunchCaptureMaterializationFailure(partitionOrdinal: 1, reason: "decode"))
        let prefix = try XCTUnwrap(first.partitions.first)
        let bytes = try Data(contentsOf: prefix.audioURL)
        try io.restoreLastSynchronizedState()
        count = 0
        let repeated = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, decode: { _ in count += 1; return count == 3 ? nil : [1] }).materialize()
        XCTAssertEqual(repeated.coveredThroughSequence, first.coveredThroughSequence)
        XCTAssertEqual(repeated.failure, first.failure)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(repeated.partitions.first).audioURL), bytes)
    }

    func testMidFrameDurablePartitionDoesNotAdvanceFailureFrontier() {
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        for packet in 0..<3 {
            Self.append(Self.packet(UInt16(packet), index: 0, body: Data([UInt8(packet)])), to: writer)
            clock.advance(by: OmiAudioChunkFormat.chunkDurationSeconds + 1)
        }

        let failingWriter = FaultInjectingOmiAACChunkWriter(io: FoundationOmiLaunchCaptureIO())
        failingWriter.failNext(.open)
        var writerCount = 0
        var decodeCount = 0
        let result = OmiLaunchCaptureMaterializer(
            rootURL: rootURL,
            generationID: generation,
            makeWriter: {
                writerCount += 1
                return writerCount == 3 ? failingWriter : RecordingOmiAACChunkWriter(store: MaterializedSamples())
            },
            decode: { _ in
                decodeCount += 1
                switch decodeCount {
                case 1, 3: return [1]
                case 2: return Array(repeating: 2, count: OmiAudioChunkFormat.sampleLimit + 1)
                default: return []
                }
            }
        ).materialize()

        XCTAssertEqual(result.partitions.count, 2)
        XCTAssertTrue(result.partitions[0].endsAtSourceFrameBoundary)
        XCTAssertFalse(result.partitions[1].endsAtSourceFrameBoundary)
        XCTAssertEqual(result.coveredThroughSequence, 0)
        XCTAssertEqual(result.failure?.partitionOrdinal, 2)
    }

    func testGapBoundaryPreservesEvidenceAndRefusesSuffix() throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation)
        Self.append(Self.packet(0, index: 0, body: Data([1])), to: writer)
        XCTAssertEqual(writer.reserveGap(), .visibleGap(sequence: 1, .intentionalGap))
        let captureBytes = try Data(contentsOf: writer.fileURL)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generation)
        let cursorBytes = try? Data(contentsOf: reader.cursorURL)
        let store = MaterializedSamples()
        let result = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, makeWriter: { RecordingOmiAACChunkWriter(store: store) }, decode: { _ in [1] }).materialize()

        XCTAssertEqual(result.partitions.count, 1)
        XCTAssertEqual(try Data(contentsOf: writer.fileURL), captureBytes)
        XCTAssertEqual(try? Data(contentsOf: reader.cursorURL), cursorBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Materialized").appendingPathComponent(generation.uuidString).appendingPathComponent(OmiSegmentWriter.chunkID(sessionID: generation, index: 1)).appendingPathExtension("m4a").path))
    }

    func testRestartSealsPersistedTrailingPartitionAndStartsDistinctSuccessor() throws {
        let generation = UUID()
        let clock = MockObserverClock()
        let capture = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: clock)
        Self.append(Self.packet(0, index: 0, body: try Self.opusFrame()), to: capture)
        let firstDecoder = try OmiOpusAudioDecoder()
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { firstDecoder.decode($0) }).materialize()
        let firstOutput = try XCTUnwrap(first.partitions.only)
        let originalEnvelope = try Data(contentsOf: firstOutput.envelopeURL)
        let repeatedDecoder = try OmiOpusAudioDecoder()
        let repeated = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { repeatedDecoder.decode($0) }).materialize()
        XCTAssertEqual(repeated.partitions.only?.itemID, firstOutput.itemID)
        XCTAssertEqual(try Data(contentsOf: firstOutput.envelopeURL), originalEnvelope)

        clock.advance(by: 1)
        Self.append(Self.packet(1, index: 0, body: try Self.opusFrame()), to: capture)
        let grownDecoder = try OmiOpusAudioDecoder()
        let grown = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { grownDecoder.decode($0) }).materialize()
        XCTAssertEqual(grown.partitions.first?.itemID, firstOutput.itemID)
        XCTAssertEqual(grown.partitions.count, 2)
        XCTAssertNotEqual(grown.partitions[1].itemID, firstOutput.itemID)
        let grownEnvelope = try OmiPendingHandoffStore.read(from: grown.partitions[1].envelopeURL)
        XCTAssertEqual(grownEnvelope.sidecar.durationS, 320 / OmiAudioChunkFormat.sampleRate)
    }

    func testDurableAcknowledgmentExcludesAcknowledgedSequencesFromNextMaterialization() throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock())
        Self.append(Self.packet(0, index: 0, body: try Self.opusFrame()), to: writer)
        let firstDecoder = try OmiOpusAudioDecoder()
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { firstDecoder.decode($0) }).materialize()
        let firstPartition = try XCTUnwrap(first.partitions.first)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generation)
        XCTAssertEqual(reader.acknowledge(throughSequence: 0), .advanced)

        let secondDecoder = try OmiOpusAudioDecoder()
        let second = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { secondDecoder.decode($0) }).materialize()
        XCTAssertTrue(second.partitions.isEmpty)
        XCTAssertFalse(second.partitions.contains { $0.coveredThroughSequence == firstPartition.coveredThroughSequence })
    }

    func testMarkerOnlyAppendReusesTrailingFrameWithSameIdentity() throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock())
        Self.append(Self.packet(0, index: 0, body: try Self.opusFrame()), to: writer)

        let firstDecoder = try OmiOpusAudioDecoder()
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { firstDecoder.decode($0) }).materialize()
        let firstOutput = try XCTUnwrap(first.partitions.only)
        let audioBytes = try Data(contentsOf: firstOutput.audioURL)
        let envelopeBytes = try Data(contentsOf: firstOutput.envelopeURL)

        Self.append(Self.marker(packet: 1, epoch: 1_700_000_000), to: writer)
        let secondDecoder = try OmiOpusAudioDecoder()
        let second = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { secondDecoder.decode($0) }).materialize()

        XCTAssertEqual(second.partitions.only?.itemID, firstOutput.itemID)
        XCTAssertEqual(try Data(contentsOf: firstOutput.audioURL), audioBytes)
        XCTAssertEqual(try Data(contentsOf: firstOutput.envelopeURL), envelopeBytes)
    }

    func testExistsFaultLeavesCompleteArtifactUntouched() throws {
        let generation = UUID()
        let io = FaultInjectingOmiLaunchCaptureIO()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock(), io: io)
        Self.append(Self.packet(0, index: 0, body: try Self.opusFrame()), to: writer)

        let firstDecoder = try OmiOpusAudioDecoder()
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, decode: { firstDecoder.decode($0) }).materialize()
        let firstOutput = try XCTUnwrap(first.partitions.only)
        let audioBytes = try Data(contentsOf: firstOutput.audioURL)
        let envelopeBytes = try Data(contentsOf: firstOutput.envelopeURL)

        var didScheduleExistsFault = false
        let diagnosticLog = DiagnosticLog()
        let secondDecoder = try OmiOpusAudioDecoder()
        let result = OmiLaunchCaptureMaterializer(
            rootURL: rootURL,
            generationID: generation,
            io: io,
            decode: { frame in
                if !didScheduleExistsFault {
                    io.failNext(.exists)
                    didScheduleExistsFault = true
                }
                return secondDecoder.decode(frame)
            },
            diagnosticLog: diagnosticLog
        ).materialize()

        XCTAssertTrue(result.partitions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: firstOutput.audioURL), audioBytes)
        XCTAssertEqual(try Data(contentsOf: firstOutput.envelopeURL), envelopeBytes)
        XCTAssertEqual(diagnosticLog.events.only?.detail, "generation=\(generation.uuidString.lowercased()) partition=0 reason=exists")
    }

    func testFlushFinalFrameProducesStableTrailingAACAndEnvelope() throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000)))
        let frame = try Self.opusFrame()
        Self.append(Self.packet(0, index: 0, body: frame), to: writer)
        let decoder = try OmiOpusAudioDecoder()
        let result = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { decoder.decode($0) }).materialize()
        let output = try XCTUnwrap(result.partitions.only)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.envelopeURL.path), "flushFinalFrame must make the final complete frame durable")
        XCTAssertEqual(try AVAudioFile(forReading: output.audioURL).length, 320)
    }

    func testFaultAttentionAndMemoryRemainBoundedByLeaseAndPartition() {
        let generation = UUID()
        let io = FaultInjectingOmiLaunchCaptureIO()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, io: io)
        for packet in 0..<12 { Self.append(Self.packet(UInt16(packet), index: 0, body: Data([UInt8(packet)])), to: writer) }
        let failingWriter = FaultInjectingOmiAACChunkWriter(io: io)
        failingWriter.failNext(.write)
        io.failNext(.remove)
        let diagnosticLog = DiagnosticLog()
        let materializer = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, makeWriter: { failingWriter }, decode: { _ in [1] }, diagnosticLog: diagnosticLog)
        XCTAssertTrue(materializer.materialize().partitions.isEmpty)
        XCTAssertLessThanOrEqual(materializer.peakLeaseResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)
        XCTAssertLessThanOrEqual(io.largestSingleReadCount, OmiLaunchCaptureFormat.readerBodyBufferByteCount)
        XCTAssertLessThanOrEqual(materializer.peakOpenPartitionSampleCount, OmiAudioChunkFormat.sampleLimit)
        XCTAssertEqual(diagnosticLog.events.only?.detail, "generation=\(generation.uuidString.lowercased()) partition=0 reason=cleanup")
        let decoderLog = DiagnosticLog()
        XCTAssertTrue(OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, makeWriter: { RecordingOmiAACChunkWriter(store: MaterializedSamples()) }, decode: { _ in nil }, diagnosticLog: decoderLog).materialize().partitions.isEmpty)
        XCTAssertEqual(decoderLog.events.only?.detail, "generation=\(generation.uuidString.lowercased()) partition=0 reason=decode")
    }

    func testMaterializationLeavesCursorAndLeaseUntouchedAndNeverEnqueues() throws {
        let generation = UUID()
        let io = FaultInjectingOmiLaunchCaptureIO()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock(), io: io)
        Self.append(Self.packet(0, index: 0, body: Data([1])), to: writer)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generation, io: io)
        let beforeLease = reader.lease()
        let beforeCursor = try? Data(contentsOf: reader.cursorURL)
        _ = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: io, makeWriter: { RecordingOmiAACChunkWriter(store: MaterializedSamples()) }, decode: { _ in [1] }).materialize()
        XCTAssertEqual(reader.lease(), beforeLease)
        XCTAssertEqual(try? Data(contentsOf: reader.cursorURL), beforeCursor)
    }

    private static func append(_ payload: Data, to writer: OmiLaunchCaptureWriter) {
        guard case .retained = writer.append(payload) else {
            XCTFail("launch capture fixture was not retained")
            return
        }
    }

    private static func packet(_ number: UInt16, index: UInt8, body: some DataProtocol) -> Data {
        var data = Data([UInt8(number & 0xff), UInt8(number >> 8), index])
        data.append(contentsOf: body)
        return data
    }

    private static func marker(packet: UInt16, epoch: UInt32) -> Data {
        Self.packet(packet, index: 0xff, body: Data([UInt8(epoch & 0xff), UInt8((epoch >> 8) & 0xff), UInt8((epoch >> 16) & 0xff), UInt8((epoch >> 24) & 0xff)]))
    }

    private static func opusFrame() throws -> Data {
        let format = try XCTUnwrap(AVAudioFormat(opusPCMFormat: .int16, sampleRate: OmiAudioChunkFormat.sampleRate, channels: OmiAudioChunkFormat.channelCount))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 320))
        buffer.frameLength = 320
        for index in 0..<320 { buffer.int16ChannelData![0][index] = Int16(index % 128) }
        let encoder = try Opus.Encoder(format: format)
        var encoded = Data(repeating: 0, count: 512)
        _ = try encoder.encode(buffer, to: &encoded)
        return encoded
    }
}

@MainActor
private final class MaterializedSamples {
    var chunks: [[Int16]] = []
    var chunkStartOffsets: [Int] = []
    var totalSampleCount = 0

    func append(_ samples: ArraySlice<Int16>) {
        self.chunkStartOffsets.append(self.totalSampleCount)
        self.chunks.append(Array(samples))
        self.totalSampleCount += samples.count
    }
}

@MainActor
private final class RecordingOmiAACChunkWriter: OmiAACChunkWriting {
    private let store: MaterializedSamples

    init(store: MaterializedSamples) { self.store = store }

    func open(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0]).write(to: url)
    }

    func write(samples: ArraySlice<Int16>) throws { self.store.append(samples) }
    func close() throws {}
    func synchronize(at url: URL) throws {}
}

@MainActor
private final class PositionDerivedSamples {
    private let samplesPerFrame: Int
    private var nextPosition = 0

    init(samplesPerFrame: Int) { self.samplesPerFrame = samplesPerFrame }

    func nextFrame() -> [Int16] {
        let start = self.nextPosition
        self.nextPosition += self.samplesPerFrame
        return (start..<(start + self.samplesPerFrame)).map(Self.sample(at:))
    }

    static func sample(at position: Int) -> Int16 {
        let logicalPosition = UInt32(position / 2)
        let bits: UInt16 = position.isMultiple(of: 2)
            ? UInt16(truncatingIfNeeded: logicalPosition >> 16)
            : UInt16(truncatingIfNeeded: logicalPosition)
        return Int16(bitPattern: bits)
    }
}

private extension Collection {
    var only: Element? { self.count == 1 ? self.first : nil }
}

private extension OmiAACChunkWriterFault {
    static let allCases: [Self] = [.open, .write, .close, .synchronize]
}
