// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchCaptureLeaseTests: XCTestCase {
    private var rootURL: URL!
    private static let captureScanReadsPerRecord = 2
    private static let captureLeaseReadsPerRecord = 2
    private static let captureLeaseFirstHeaderReadCount = 1

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureLeaseTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func testLeaseReadsVerifiedPrefixInBoundedOrderedBatches() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        for sequence in 0..<3 {
            XCTAssertEqual(writer.append(Data(repeating: UInt8(sequence), count: OmiLaunchCaptureFormat.maximumPayloadBytes)), .retained(sequence: UInt64(sequence), retriedPending: false))
        }

        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        guard case .lease(let lease) = reader.lease() else { return XCTFail("expected lease") }
        XCTAssertEqual(lease.records.map(\.sequence), [0, 1])
        XCTAssertEqual(lease.records.map(\.generationID), [generation, generation])
        XCTAssertEqual(lease.records.map(\.payload), [Data(repeating: 0, count: 512), Data(repeating: 1, count: 512)])
        XCTAssertEqual(lease.records.map(\.acquiredAtUnixMicros), [1_800_000_000_000_000, 1_800_000_000_000_000])
        XCTAssertLessThanOrEqual(reader.peakLeaseResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)
        XCTAssertLessThanOrEqual(io.largestSingleReadCount, OmiLaunchCaptureFormat.readerBodyBufferByteCount)
    }

    func testStalledLeaseReleasesIdenticallyAfterAppendAndRestart() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("one".utf8)), .retained(sequence: 0, retriedPending: false))
        XCTAssertEqual(writer.append(Data("two".utf8)), .retained(sequence: 1, retriedPending: false))
        let firstReader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        guard case .lease(let first) = firstReader.lease() else { return XCTFail("expected first lease") }
        XCTAssertEqual(writer.append(Data("three".utf8)), .retained(sequence: 2, retriedPending: false))

        let restarted = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        guard case .lease(let reopened) = restarted.lease() else { return XCTFail("expected reopened lease") }
        XCTAssertEqual(reopened.records, first.records)
        XCTAssertEqual(reopened.startSequence, first.startSequence)
        XCTAssertEqual(reopened.startOffset, first.startOffset)
        XCTAssertEqual(reopened.throughSequence, first.throughSequence)
        XCTAssertEqual(reopened.endOffset, first.endOffset)
        XCTAssertFalse(reopened.endsAtVerifiedPrefix, "growth intentionally changes this live lease property")
        XCTAssertEqual(restarted.acknowledge(throughSequence: first.throughSequence), .advanced)
        guard case .lease(let later) = restarted.lease() else { return XCTFail("expected later lease") }
        XCTAssertEqual(later.records.map(\.sequence), [2])
        XCTAssertEqual(later.records.map(\.payload), [Data("three".utf8)])
    }

    func testAcknowledgmentIsOrderedAndIdempotent() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        for sequence in 0..<5 {
            XCTAssertEqual(writer.append(Data("\(sequence)".utf8)), .retained(sequence: UInt64(sequence), retriedPending: false))
        }
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        XCTAssertEqual(reader.acknowledge(throughSequence: 1), .advanced)
        XCTAssertEqual(reader.acknowledge(throughSequence: 1), .noOp(.repeatedSequence))
        XCTAssertEqual(reader.acknowledge(throughSequence: 0), .noOp(.lowerSequence))
        XCTAssertEqual(reader.acknowledge(throughSequence: 4), .advanced)
        XCTAssertEqual(reader.acknowledge(throughSequence: 3, generationID: UUID()), .refused(.foreignGeneration))
        XCTAssertEqual(reader.acknowledge(throughSequence: 9), .refused(.pastVerifiedPrefix))
    }

    func testAcknowledgmentRefusesCursorThatDoesNotPointToItsNextSequence() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("zero".utf8)), .retained(sequence: 0, retriedPending: false))
        XCTAssertEqual(writer.append(Data("one".utf8)), .retained(sequence: 1, retriedPending: false))
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        let inconsistentCursor = OmiLaunchCaptureCursor(
            generationID: generation,
            acknowledgedPrefixNextSequence: 1,
            acknowledgedPrefixEndOffset: 0
        )
        let cursorData = inconsistentCursor.encoded()
        try cursorData.write(to: reader.cursorURL)

        XCTAssertEqual(reader.acknowledge(throughSequence: 1), .refused(.noncontiguousFutureSequence))
        XCTAssertEqual(try Data(contentsOf: reader.cursorURL), cursorData)
    }

    func testAcknowledgmentRefusesCursorOffsetPastVerifiedPrefix() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("prefix0".utf8)), .retained(sequence: 0, retriedPending: false))
        XCTAssertEqual(writer.append(Data("prefix1".utf8)), .retained(sequence: 1, retriedPending: false))
        io.failWrite(onCall: 2, afterBytes: 0)
        XCTAssertEqual(writer.append(Data("gap".utf8)), .visibleGap(sequence: 2, .payloadWriteFailed))

        let scan = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        let suffixHeader = OmiLaunchCaptureHeader(
            generationID: generation,
            sequence: 1,
            acquiredAtUnixMicros: 1_800_000_000_000_000,
            declaredPayloadBytes: 0
        ).encoded()
        let suffixFile = try FileHandle(forWritingTo: writer.fileURL)
        try suffixFile.seekToEnd()
        try suffixFile.write(contentsOf: suffixHeader)
        try suffixFile.close()

        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        let suffixCursor = OmiLaunchCaptureCursor(
            generationID: generation,
            acknowledgedPrefixNextSequence: 1,
            acknowledgedPrefixEndOffset: scan.verifiedPrefixEndOffset + OmiLaunchCaptureFormat.headerByteCount
        )
        let cursorData = suffixCursor.encoded()
        try cursorData.write(to: reader.cursorURL)

        XCTAssertEqual(reader.acknowledge(throughSequence: 1), .refused(.noncontiguousFutureSequence))
        XCTAssertEqual(try Data(contentsOf: reader.cursorURL), cursorData)
    }

    func testCursorFaultsPreserveUnacknowledgedLeaseAndConverge() throws {
        struct Fault {
            let name: String
            let inject: (FaultInjectingOmiLaunchCaptureIO) -> Void
            let expected: OmiLaunchCaptureAcknowledgmentRefusalReason
        }
        let faults = [
            Fault(name: "open", inject: { $0.failNext(.open) }, expected: .cursorWriteFailed),
            Fault(name: "write", inject: { $0.failNext(.write) }, expected: .cursorWriteFailed),
            Fault(name: "sync", inject: { $0.failNext(.barrier) }, expected: .cursorWriteFailed),
            Fault(name: "replace", inject: { $0.failNext(.replace) }, expected: .cursorReplaceFailed),
            Fault(name: "cleanup", inject: { io in
                io.failNext(.write)
                io.failNext(.remove)
            }, expected: .cursorWriteFailed),
        ]
        for fault in faults {
            let caseRoot = self.rootURL.appendingPathComponent(fault.name, isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = UUID()
            let writer = OmiLaunchCaptureWriter(rootURL: caseRoot, generationID: generation, clock: MockObserverClock(), io: io)
            XCTAssertEqual(writer.append(Data("one".utf8)), .retained(sequence: 0, retriedPending: false))
            XCTAssertEqual(writer.append(Data("two".utf8)), .retained(sequence: 1, retriedPending: false))
            let reader = OmiLaunchCaptureLeaseReader(rootURL: caseRoot, generationID: generation, io: io)
            guard case .lease(let before) = reader.lease() else { return XCTFail("expected lease \(fault.name)") }
            fault.inject(io)
            XCTAssertEqual(reader.acknowledge(throughSequence: before.throughSequence), .refused(fault.expected), fault.name)
            try io.restoreLastSynchronizedState()
            let restarted = OmiLaunchCaptureLeaseReader(rootURL: caseRoot, generationID: generation, io: io)
            XCTAssertEqual(restarted.lease(), .lease(before), fault.name)
            io.clearFaults()
            XCTAssertEqual(restarted.acknowledge(throughSequence: before.throughSequence), .advanced, fault.name)
            XCTAssertEqual(restarted.lease(), .empty, fault.name)
        }
    }

    func testCommittedAcknowledgmentSurvivesSynchronizedStateRestore() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("one".utf8)), .retained(sequence: 0, retriedPending: false))
        XCTAssertEqual(writer.append(Data("two".utf8)), .retained(sequence: 1, retriedPending: false))
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        guard case .lease(let lease) = reader.lease() else { return XCTFail("expected lease") }
        XCTAssertEqual(reader.acknowledge(throughSequence: lease.throughSequence), .advanced)
        try io.restoreLastSynchronizedState()
        let restarted = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        XCTAssertEqual(restarted.lease(), .empty)
    }

    func testMaterializedFrontierResumeReadsOnlySuffixAndKeepsCoordinatesStable() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        for value in 0..<4 {
            XCTAssertEqual(writer.append(Data([UInt8(value)])), .retained(sequence: UInt64(value), retriedPending: false))
        }

        let first = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        guard case .lease(let prefix) = first.lease() else { return XCTFail("expected prefix lease") }
        XCTAssertEqual(prefix.records.map(\.sequence), [0, 1])
        XCTAssertEqual(first.advanceMaterialized(
            throughSequence: prefix.throughSequence,
            endOffset: prefix.endOffset,
            nextPartitionOrdinal: 7,
            nextSampleOffset: 42
        ), .advanced)
        XCTAssertEqual(first.acknowledge(throughSequence: prefix.throughSequence), .advanced)
        let readsAfterCommit = io.readCallCount(at: writer.fileURL)

        let resumed = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        XCTAssertEqual(resumed.materializedPosition(), OmiLaunchCaptureReadPosition(generationID: generation, nextSequence: 2, offset: prefix.endOffset))
        guard case .lease(let suffix) = resumed.lease(from: try XCTUnwrap(resumed.materializedPosition())) else {
            return XCTFail("expected suffix lease")
        }
        XCTAssertEqual(suffix.records.map(\.sequence), [2, 3])
        XCTAssertEqual(resumed.cursor()?.nextPartitionOrdinal, 7)
        XCTAssertEqual(resumed.cursor()?.nextSampleOffset, 42)
        let suffixReadCeiling = suffix.records.count
            * (Self.captureScanReadsPerRecord + Self.captureLeaseReadsPerRecord)
            + Self.captureLeaseFirstHeaderReadCount
        XCTAssertLessThanOrEqual(
            io.readCallCount(at: writer.fileURL) - readsAfterCommit,
            suffixReadCeiling,
            "frontier-relative scan must not reread the committed prefix"
        )
        XCTAssertEqual(suffix.startOffset, prefix.endOffset, "resume must begin at the committed frontier, not byte zero")
    }

    func testAppendBehindFrozenLeaseKeepsBoundedOrderedSuccessors() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        for value in 0..<2 {
            XCTAssertEqual(writer.append(Data([UInt8(value)])), .retained(sequence: UInt64(value), retriedPending: false))
        }
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        guard case .lease(let frozen) = reader.lease() else { return XCTFail("expected frozen lease") }
        XCTAssertEqual(frozen.records.map(\.sequence), [0, 1])
        for value in 2..<9 {
            XCTAssertEqual(writer.append(Data([UInt8(value)])), .retained(sequence: UInt64(value), retriedPending: false))
        }
        XCTAssertEqual(reader.advanceMaterialized(
            throughSequence: frozen.throughSequence,
            endOffset: frozen.endOffset,
            nextPartitionOrdinal: 0,
            nextSampleOffset: 0
        ), .advanced)
        XCTAssertEqual(reader.acknowledge(throughSequence: frozen.throughSequence), .advanced)

        var sequences: [UInt64] = []
        var position = try XCTUnwrap(reader.materializedPosition())
        while case .lease(let lease) = reader.lease(from: position) {
            XCTAssertLessThanOrEqual(lease.records.count, OmiLaunchCaptureFormat.maximumRecordsPerLease)
            XCTAssertLessThanOrEqual(reader.peakLeaseResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)
            sequences.append(contentsOf: lease.records.map(\.sequence))
            position = OmiLaunchCaptureReadPosition(generationID: generation, nextSequence: lease.throughSequence + 1, offset: lease.endOffset)
        }
        XCTAssertEqual(sequences, Array(2..<9))
        XCTAssertEqual(frozen.endOffset, try XCTUnwrap(reader.materializedPosition()).offset)
    }

    func testBoundaryPrefixIsLeasableThenQuarantinedOnlyAfterAcknowledgment() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("prefix0".utf8)), .retained(sequence: 0, retriedPending: false))
        XCTAssertEqual(writer.append(Data("prefix1".utf8)), .retained(sequence: 1, retriedPending: false))
        XCTAssertEqual(writer.append(Data("prefix2".utf8)), .retained(sequence: 2, retriedPending: false))
        io.failWrite(onCall: 2, afterBytes: 0)
        XCTAssertEqual(writer.append(Data("gap".utf8)), .visibleGap(sequence: 3, .payloadWriteFailed))
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        guard case .lease(let lease) = reader.lease() else { return XCTFail("expected prefix lease") }
        XCTAssertEqual(lease.records.map(\.payload), [Data("prefix0".utf8), Data("prefix1".utf8)])
        XCTAssertEqual(reader.acknowledge(throughSequence: lease.throughSequence), .advanced)
        XCTAssertEqual(reader.retireIfEligible(activeGenerationID: nil), .refusedUnacknowledgedPrefix)
        guard case .lease(let finalLease) = reader.lease() else { return XCTFail("expected final prefix") }
        XCTAssertEqual(finalLease.records.map(\.sequence), [2])
        XCTAssertEqual(reader.acknowledge(throughSequence: finalLease.throughSequence), .advanced)
        XCTAssertEqual(reader.retireIfEligible(activeGenerationID: nil), .quarantined)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
        XCTAssertEqual(reader.lease(), .empty)
    }

    func testCursorDefectFixtureMatrixFailsClosedWithoutChangingEvidence() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("one".utf8)), .retained(sequence: 0, retriedPending: false))
        XCTAssertEqual(writer.append(Data("two".utf8)), .retained(sequence: 1, retriedPending: false))
        let firstEndOffset = OmiLaunchCaptureFormat.headerByteCount + Data("one".utf8).count + OmiLaunchCaptureFormat.recordTagByteCount
        let controlCursor = OmiLaunchCaptureCursor(
            generationID: generation,
            acknowledgedPrefixNextSequence: 1,
            acknowledgedPrefixEndOffset: firstEndOffset
        )
        let controlData = controlCursor.encoded()
        let reader = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
        let captureData = try Data(contentsOf: writer.fileURL)

        XCTAssertNil(reader.cursorDefect())
        XCTAssertEqual(reader.acknowledgedPosition(), OmiLaunchCaptureReadPosition(generationID: generation, nextSequence: 0, offset: 0))

        try controlData.write(to: reader.cursorURL)
        XCTAssertNil(reader.cursorDefect())
        guard case .lease(let controlLease) = reader.lease() else { return XCTFail("expected valid control lease") }
        XCTAssertEqual(controlLease.records.map(\.sequence), [1])

        let foreignGeneration = UUID()
        let magicRange = 0..<OmiLaunchCaptureCursorFormat.magic.count
        let versionRange = magicRange.upperBound..<(magicRange.upperBound + OmiLaunchCaptureCursorFormat.versionByteCount)
        let generationRange = versionRange.upperBound..<(versionRange.upperBound + OmiLaunchCaptureFormat.generationIDByteCount)
        let sequenceRange = generationRange.upperBound..<(generationRange.upperBound + OmiLaunchCaptureCursorFormat.sequenceByteCount)
        let acknowledgedEndRange = sequenceRange.upperBound..<(sequenceRange.upperBound + OmiLaunchCaptureCursorFormat.offsetByteCount)
        let digestRange = (controlData.count - OmiLaunchCaptureCursorFormat.digestByteCount)..<controlData.count
        enum FixtureDifference {
            case length
            case field(Range<Int>)
            case digest
        }
        let fixtures: [(name: String, data: Data, reason: OmiLaunchCaptureCursorDefectReason, difference: FixtureDifference)] = [
            ("truncated", Data(controlData.dropLast()), .invalidLength, .length),
            ("extended", controlData + Data([0]), .invalidLength, .length),
            ("invalid_magic", Self.recomputingCursorDigest(Self.replacingByte(in: controlData, at: magicRange.lowerBound, with: controlData[magicRange.lowerBound] ^ 0x01)), .invalidMagic, .field(magicRange)),
            ("cursor_checksum", Self.replacingByte(in: controlData, at: digestRange.upperBound - 1, with: controlData[digestRange.upperBound - 1] ^ 0x01), .cursorChecksumMismatch, .digest),
            ("unsupported_version", Self.recomputingCursorDigest(Self.replacingByte(in: controlData, at: versionRange.lowerBound, with: 1)), .unsupportedVersion, .field(versionRange)),
            ("foreign_generation", Self.recomputingCursorDigest(Self.replacingUUID(in: controlData, at: generationRange.lowerBound, with: foreignGeneration)), .generationMismatch, .field(generationRange)),
            ("offset_out_of_range", Self.recomputingCursorDigest(Self.replacingAcknowledgedEnd(in: controlData, with: UInt64(Int.max) + 1)), .offsetOutOfRange, .field(acknowledgedEndRange)),
        ]

        for fixture in fixtures {
            try fixture.data.write(to: reader.cursorURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: reader.cursorURL.path), fixture.name)
            XCTAssertEqual(try Data(contentsOf: writer.fileURL), captureData, fixture.name)
            switch fixture.difference {
            case .length:
                Self.assertOnlyCursorLengthDiffers(control: controlData, fixture: fixture.data, message: fixture.name)
            case .field(let range):
                Self.assertOnlyCursorFieldDiffers(control: controlData, fixture: fixture.data, mutatedRange: range, digestRange: digestRange, message: fixture.name)
            case .digest:
                Self.assertOnlyCursorDigestDiffers(control: controlData, fixture: fixture.data, digestRange: digestRange, message: fixture.name)
            }

            let reopened = OmiLaunchCaptureLeaseReader(rootURL: self.rootURL, generationID: generation, io: io)
            XCTAssertEqual(reopened.cursorDefect()?.reason, fixture.reason, fixture.name)
            XCTAssertEqual(reopened.lease(), .unavailable(.cursorUnreadable), fixture.name)
            XCTAssertNil(reopened.acknowledgedPosition(), fixture.name)
            XCTAssertFalse(reopened.hasDurableAcknowledgment(), fixture.name)
            XCTAssertEqual(reopened.retireIfEligible(activeGenerationID: nil), .refusedInvalidCursor, fixture.name)
            XCTAssertEqual(reopened.acknowledge(throughSequence: 1), .refused(.cursorUnreadable), fixture.name)
            let result = OmiLaunchCaptureMaterializer(
                rootURL: self.rootURL,
                generationID: generation,
                io: io,
                decode: { _ in [1] }
            ).materializeForTests()
            XCTAssertTrue(result.partitions.isEmpty, fixture.name)
            XCTAssertTrue(result.markers.isEmpty, fixture.name)
            XCTAssertEqual(try Data(contentsOf: reader.cursorURL), fixture.data, fixture.name)
            XCTAssertEqual(try Data(contentsOf: writer.fileURL), captureData, fixture.name)
        }
    }

    func testCursorReadIOFailuresAreNamedAndFailClosed() throws {
        for name in ["open", "read"] {
            let caseRoot = self.rootURL.appendingPathComponent(name, isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = UUID()
            let writer = OmiLaunchCaptureWriter(rootURL: caseRoot, generationID: generation, clock: MockObserverClock(), io: io)
            XCTAssertEqual(writer.append(Data("one".utf8)), .retained(sequence: 0, retriedPending: false))
            let reader = OmiLaunchCaptureLeaseReader(rootURL: caseRoot, generationID: generation, io: io)
            try OmiLaunchCaptureCursor(generationID: generation, acknowledgedPrefixNextSequence: 0, acknowledgedPrefixEndOffset: 0).encoded().write(to: reader.cursorURL)
            if name == "open" {
                io.failOpenForReading(at: reader.cursorURL, fromCall: 1)
            } else {
                io.failRead(at: reader.cursorURL, fromCall: 1)
            }

            XCTAssertEqual(reader.lease(), .unavailable(.cursorUnreadable), name)
            XCTAssertEqual(reader.cursorDefect()?.reason, .readFailed, name)
            XCTAssertNil(reader.acknowledgedPosition(), name)
            XCTAssertFalse(reader.hasDurableAcknowledgment(), name)
            XCTAssertEqual(reader.acknowledge(throughSequence: 0), .refused(.cursorUnreadable), name)
        }
    }

    private func writer(generation: UUID, io: FaultInjectingOmiLaunchCaptureIO) -> OmiLaunchCaptureWriter {
        OmiLaunchCaptureWriter(
            rootURL: self.rootURL,
            generationID: generation,
            clock: MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000)),
            io: io
        )
    }

    private static func replacingByte(in data: Data, at offset: Int, with value: UInt8) -> Data {
        var result = data
        result[result.startIndex + offset] = value
        return result
    }

    private static func replacingUUID(in data: Data, at offset: Int, with value: UUID) -> Data {
        var result = data
        var uuidBytes = Data()
        uuidBytes.append(uuidBytes: value)
        result.replaceSubrange(offset..<(offset + OmiLaunchCaptureFormat.generationIDByteCount), with: uuidBytes)
        return result
    }

    private static func replacingAcknowledgedEnd(in data: Data, with value: UInt64) -> Data {
        let sequenceOffset = OmiLaunchCaptureCursorFormat.magic.count
            + OmiLaunchCaptureCursorFormat.versionByteCount
            + OmiLaunchCaptureFormat.generationIDByteCount
        let endOffset = sequenceOffset + OmiLaunchCaptureCursorFormat.sequenceByteCount
        var bytes = Data()
        bytes.appendLittleEndian(value)
        var result = data
        result.replaceSubrange(endOffset..<(endOffset + OmiLaunchCaptureCursorFormat.offsetByteCount), with: bytes)
        return result
    }

    private static func recomputingCursorDigest(_ data: Data) -> Data {
        let digestOffset = data.count - OmiLaunchCaptureCursorFormat.digestByteCount
        var result = data
        result.replaceSubrange(digestOffset..<result.count, with: OmiLaunchCaptureDigest.truncated(result.prefix(digestOffset)))
        return result
    }

    private static func assertOnlyCursorLengthDiffers(control: Data, fixture: Data, message: String) {
        XCTAssertNotEqual(fixture.count, control.count, message)
        let sharedCount = min(fixture.count, control.count)
        XCTAssertEqual(Data(fixture.prefix(sharedCount)), Data(control.prefix(sharedCount)), message)
    }

    private static func assertOnlyCursorFieldDiffers(
        control: Data,
        fixture: Data,
        mutatedRange: Range<Int>,
        digestRange: Range<Int>,
        message: String
    ) {
        XCTAssertEqual(fixture.count, control.count, message)
        XCTAssertNotEqual(
            Data(fixture[fixture.startIndex + mutatedRange.lowerBound..<fixture.startIndex + mutatedRange.upperBound]),
            Data(control[control.startIndex + mutatedRange.lowerBound..<control.startIndex + mutatedRange.upperBound]),
            message
        )
        for offset in 0..<control.count where !mutatedRange.contains(offset) && !digestRange.contains(offset) {
            XCTAssertEqual(fixture[fixture.startIndex + offset], control[control.startIndex + offset], "\(message) offset=\(offset)")
        }
    }

    private static func assertOnlyCursorDigestDiffers(control: Data, fixture: Data, digestRange: Range<Int>, message: String) {
        XCTAssertEqual(fixture.count, control.count, message)
        XCTAssertEqual(Data(fixture.prefix(digestRange.lowerBound)), Data(control.prefix(digestRange.lowerBound)), message)
        let differingBytes = digestRange.filter { fixture[fixture.startIndex + $0] != control[control.startIndex + $0] }
        XCTAssertEqual(differingBytes.count, 1, message)
        if let offset = differingBytes.first {
            XCTAssertEqual((fixture[fixture.startIndex + offset] ^ control[control.startIndex + offset]).nonzeroBitCount, 1, message)
        }
    }
}
