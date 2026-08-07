// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Crypto
import Foundation
import Opus
import XCTest

@MainActor
final class OmiLaunchCaptureOrphanRepairTests: XCTestCase {
    private enum RepairFault: CaseIterable {
        case isolation
        case provenance
        case temporaryCreate
        case write
        case synchronize
        case finalReplace
        case envelope
    }

    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureOrphanRepairTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func testRecognizedOrphanRepairsWithStableIdentityAndUntouchedCapture() throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock())
        Self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
        let captureDigest = Self.digest(at: writer.fileURL)
        let reader = OmiLaunchCaptureLeaseReader(rootURL: rootURL, generationID: generation)
        let cursorBytes = try? Data(contentsOf: reader.cursorURL)
        let seeded = try self.seedPostReplaceOrphan(generation: generation)

        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.paths.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.paths.provenanceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.paths.envelopeURL.path))

        let decoder = try OmiOpusAudioDecoder()
        let repaired = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { decoder.decode($0) }).materialize()

        XCTAssertEqual(repaired.partitions.map(\.itemID), [seeded.itemID])
        XCTAssertTrue(repaired.orphanRepairFailures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.paths.audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.paths.envelopeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.paths.provenanceURL.path))
        XCTAssertEqual(Self.digest(at: writer.fileURL), captureDigest)
        XCTAssertEqual(try? Data(contentsOf: reader.cursorURL), cursorBytes)

        let repairedAudio = try Data(contentsOf: seeded.paths.audioURL)
        let repairedEnvelope = try Data(contentsOf: seeded.paths.envelopeURL)
        let restartedDecoder = try OmiOpusAudioDecoder()
        let restarted = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { restartedDecoder.decode($0) }).materialize()
        XCTAssertEqual(restarted.partitions.map(\.itemID), [seeded.itemID])
        XCTAssertEqual(try Data(contentsOf: seeded.paths.audioURL), repairedAudio)
        XCTAssertEqual(try Data(contentsOf: seeded.paths.envelopeURL), repairedEnvelope)
    }

    func testMismatchedProvenanceCandidateRemainsUntouched() throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock())
        Self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
        let seeded = try self.seedPostReplaceOrphan(generation: generation)

        let mismatched = OmiLaunchCaptureMaterializationProvenance(
            generationID: generation,
            partitionOrdinal: 0,
            startSequence: 1,
            startSampleOffset: 0,
            itemID: seeded.itemID
        )
        try OmiLaunchCaptureMaterializationProvenanceStore.write(
            try OmiLaunchCaptureMaterializationProvenanceStore.encode(mismatched),
            to: seeded.paths.provenanceURL,
            io: FoundationOmiLaunchCaptureIO()
        )
        let mismatchedBefore = try self.tree(at: seeded.paths.audioURL.deletingLastPathComponent())
        let diagnosticLog = DiagnosticLog()
        let decoder = try OmiOpusAudioDecoder()
        let result = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { decoder.decode($0) }, diagnosticLog: diagnosticLog).materialize()

        XCTAssertTrue(result.partitions.isEmpty)
        XCTAssertTrue(result.orphanRepairFailures.isEmpty)
        XCTAssertEqual(try self.tree(at: seeded.paths.audioURL.deletingLastPathComponent()), mismatchedBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName).path))
    }

    func testRecognizedOrphanRepairFaultsConvergeWithoutChangingCapture() throws {
        for fault in RepairFault.allCases {
            let caseRoot = rootURL.appendingPathComponent("\(fault)", isDirectory: true)
            let generation = UUID()
            let frame = try Self.opusFrame()
            let sourceDecoder = try OmiOpusAudioDecoder()
            let expectedSamples = try XCTUnwrap(sourceDecoder.decode(frame)?.count)
            let capture = OmiLaunchCaptureWriter(rootURL: caseRoot, generationID: generation, clock: MockObserverClock())
            Self.append(Self.packet(0, body: frame), to: capture)
            let captureDigest = Self.digest(at: capture.fileURL)
            let reader = OmiLaunchCaptureLeaseReader(rootURL: caseRoot, generationID: generation)
            let cursorBytes = try? Data(contentsOf: reader.cursorURL)
            let seeded = try self.seedPostReplaceOrphan(rootURL: caseRoot, generation: generation)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let failingWriter = FaultInjectingOmiAACChunkWriter(io: io)

            switch fault {
            case .isolation:
                io.failNext(.move)
            case .provenance:
                io.failNext(.write)
            case .temporaryCreate:
                failingWriter.failNext(.open)
            case .write:
                failingWriter.failNext(.write)
            case .synchronize:
                failingWriter.failNext(.synchronize)
            case .finalReplace:
                io.failReplace(at: seeded.paths.audioURL, fromCall: 1)
            case .envelope:
                io.failReplace(at: seeded.paths.envelopeURL, fromCall: 1)
            }

            let failingDecoder = try OmiOpusAudioDecoder()
            let failed = OmiLaunchCaptureMaterializer(
                rootURL: caseRoot,
                generationID: generation,
                io: io,
                makeWriter: { failingWriter },
                decode: { failingDecoder.decode($0) }
            ).materialize()

            XCTAssertTrue(failed.partitions.isEmpty, "\(fault)")
            XCTAssertEqual(failed.orphanRepairFailures, [OmiLaunchCaptureOrphanRepairFailure(ordinal: 0, itemID: seeded.itemID)], "\(fault)")
            XCTAssertEqual(Self.digest(at: capture.fileURL), captureDigest, "\(fault)")
            XCTAssertEqual(try? Data(contentsOf: reader.cursorURL), cursorBytes, "\(fault)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: seeded.paths.envelopeURL.path), "\(fault)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: seeded.paths.audioURL.path) || self.hasQuarantinedAudio(named: seeded.paths.audioURL.lastPathComponent, rootURL: caseRoot),
                "\(fault)"
            )

            io.clearFaults()
            let recoveredDecoder = try OmiOpusAudioDecoder()
            let recovered = OmiLaunchCaptureMaterializer(
                rootURL: caseRoot,
                generationID: generation,
                io: io,
                decode: { recoveredDecoder.decode($0) }
            ).materialize()
            let output = try XCTUnwrap(recovered.partitions.only, "\(fault)")
            XCTAssertEqual(output.itemID, seeded.itemID, "\(fault)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.paths.audioURL.path), "\(fault)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: seeded.paths.envelopeURL.path), "\(fault)")
            let envelope = try OmiPendingHandoffStore.read(from: seeded.paths.envelopeURL)
            XCTAssertEqual(Int((envelope.sidecar.durationS * OmiAudioChunkFormat.sampleRate).rounded()), expectedSamples, "\(fault)")
            XCTAssertEqual(Self.digest(at: capture.fileURL), captureDigest, "\(fault)")
            XCTAssertEqual(try? Data(contentsOf: reader.cursorURL), cursorBytes, "\(fault)")
        }
    }

    func testValidPairReuseTouchesNoBytesAndCreatesNoQuarantine() throws {
        let generation = UUID()
        let writer = OmiLaunchCaptureWriter(rootURL: rootURL, generationID: generation, clock: MockObserverClock())
        Self.append(Self.packet(0, body: try Self.opusFrame()), to: writer)
        let firstDecoder = try OmiOpusAudioDecoder()
        let first = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { firstDecoder.decode($0) }).materialize()
        let output = try XCTUnwrap(first.partitions.only)
        let audioBytes = try Data(contentsOf: output.audioURL)
        let envelopeBytes = try Data(contentsOf: output.envelopeURL)

        let secondDecoder = try OmiOpusAudioDecoder()
        let repeated = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, decode: { secondDecoder.decode($0) }).materialize()

        XCTAssertEqual(repeated.partitions.map(\.itemID), [output.itemID])
        XCTAssertEqual(try Data(contentsOf: output.audioURL), audioBytes)
        XCTAssertEqual(try Data(contentsOf: output.envelopeURL), envelopeBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName).path))
    }

    private func seedPostReplaceOrphan(rootURL: URL? = nil, generation: UUID) throws -> (paths: OmiLaunchCaptureMaterializedArtifactPaths, itemID: UUID) {
        let rootURL = rootURL ?? self.rootURL!
        let crashIO = CrashAfterFinalAudioReplaceIO()
        let decoder = try OmiOpusAudioDecoder()
        let materializer = OmiLaunchCaptureMaterializer(rootURL: rootURL, generationID: generation, io: crashIO, decode: { decoder.decode($0) })
        XCTAssertTrue(materializer.materialize().partitions.isEmpty)
        let paths = OmiLaunchCaptureMaterializedArtifactPaths(rootURL: rootURL, generationID: generation, ordinal: 0)
        let itemID = OmiLaunchCaptureMaterializationIdentity.itemID(generationID: generation, partitionOrdinal: 0, startSequence: 0, startSampleOffset: 0)
        return (paths, itemID)
    }

    private func hasQuarantinedAudio(named name: String, rootURL: URL) -> Bool {
        let directory = rootURL
            .appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName, isDirectory: true)
            .appendingPathComponent(OmiLaunchCaptureFormat.materializedDirectoryName, isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.contains { $0.lastPathComponent.hasSuffix(name) } == true
    }

    private func tree(at directory: URL) throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).map { url in
            (url.lastPathComponent, try Data(contentsOf: url))
        })
    }

    private static func digest(at url: URL) -> Data {
        Data(SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()))
    }

    private static func append(_ payload: Data, to writer: OmiLaunchCaptureWriter) {
        guard case .retained = writer.append(payload) else { XCTFail("launch capture fixture was not retained"); return }
    }

    private static func packet(_ number: UInt16, body: Data) -> Data {
        Data([UInt8(number & 0xff), UInt8(number >> 8), 0]) + body
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

private extension Collection {
    var only: Element? { self.count == 1 ? self.first : nil }
}
