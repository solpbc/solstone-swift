// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchCaptureRecoveryTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureRecoveryTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func testNoDurableReservationMakesNoClaim() throws {
        let generation = UUID()
        let io = FaultInjectingOmiLaunchCaptureIO()
        let writer = self.writer(generation: generation, io: io)
        io.failNext(.open)
        XCTAssertEqual(writer.append(Data("absent".utf8)), .notRetained(.openFailed))
        let absent = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertTrue(absent.verifiedRecords.isEmpty)
        XCTAssertEqual(absent.verifiedPrefixNextSequence, 0)
        XCTAssertNil(absent.boundarySequence)
        XCTAssertNil(absent.boundaryReason)

        let fileURL = OmiLaunchCaptureFormat.fileURL(rootURL: self.rootURL, generationID: generation)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: fileURL)
        let emptyWriter = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 1, afterBytes: 0)
        XCTAssertEqual(emptyWriter.append(Data("empty".utf8)), .notRetained(.headerWriteFailed))
        let empty = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertTrue(empty.verifiedRecords.isEmpty)
        XCTAssertEqual(empty.verifiedPrefixNextSequence, 0)
        XCTAssertNil(empty.boundarySequence)
        XCTAssertNil(empty.boundaryReason)

        try Data().write(to: fileURL)
        let partialWriter = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 1, afterBytes: OmiLaunchCaptureFormat.headerByteCount - 1)
        XCTAssertEqual(partialWriter.append(Data("partial".utf8)), .notRetained(.headerWriteFailed))
        try Data(repeating: 0, count: OmiLaunchCaptureFormat.headerByteCount - 1).write(to: fileURL)
        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io)
        let partial = recovery.recover()
        XCTAssertTrue(partial.verifiedRecords.isEmpty)
        XCTAssertEqual(partial.verifiedPrefixNextSequence, 0)
        XCTAssertNil(partial.boundarySequence)
        XCTAssertEqual(partial.boundaryReason, .incompleteHeader)
        XCTAssertEqual(recovery.emittedBoundaryDiagnosticCount, 1)
    }

    func testCrashAfterHeaderReportsVisibleGap() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 2, afterBytes: 0)
        XCTAssertEqual(writer.append(Data("payload".utf8)), .visibleGap(sequence: 0, .payloadWriteFailed))

        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io)
        let result = recovery.recover()
        XCTAssertTrue(result.verifiedRecords.isEmpty)
        XCTAssertEqual(result.boundarySequence, 0)
        XCTAssertEqual(result.boundaryReason, .incompleteReservedRecord)
        XCTAssertEqual(recovery.emittedBoundaryDiagnosticCount, 1)
    }

    func testCrashMidPayloadReportsVisibleGap() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 2, afterBytes: 2)
        XCTAssertEqual(writer.append(Data("payload".utf8)), .visibleGap(sequence: 0, .payloadWriteFailed))

        let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertEqual(result.boundarySequence, 0)
        XCTAssertEqual(result.boundaryReason, .incompleteReservedRecord)
    }

    func testCrashAfterPayloadBeforeTagReportsVisibleGap() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let payload = Data("payload".utf8)
        let writer = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 3, afterBytes: 0)
        XCTAssertEqual(writer.append(payload), .visibleGap(sequence: 0, .recordTagWriteFailed))

        let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertEqual(result.boundarySequence, 0)
        XCTAssertEqual(result.boundaryReason, .incompleteReservedRecord)
    }

    func testCrashBeforeFinalBarrierRestoresLastSyncedPrefixAndReportsVisibleGap() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        io.failBarrier(onCall: 2)
        XCTAssertEqual(writer.append(Data("payload".utf8)), .visibleGap(sequence: 0, .commitBarrierFailed))
        try io.restoreLastSynchronizedPrefix(at: writer.fileURL)

        let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertEqual(result.boundarySequence, 0)
        XCTAssertEqual(result.boundaryReason, .incompleteReservedRecord)
    }

    func testCompleteValidBytesRemainReadableAfterFinalBarrierFailure() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        io.failBarrier(onCall: 2)
        XCTAssertEqual(writer.append(Data("payload".utf8)), .visibleGap(sequence: 0, .commitBarrierFailed))

        let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertEqual(result.verifiedRecords.map(\.payload), [Data("payload".utf8)])
        XCTAssertNil(result.boundaryReason)
    }

    func testCorruptionMatrixStopsAtVerifiedPrefix() throws {
        struct Mutation {
            let name: String
            let hasVisibleGap: Bool
            let expectedReason: OmiLaunchCaptureBoundaryReason
            let mutate: (inout Data, Int, Int) -> Void
        }
        // These offsets intentionally encode the external wire format so the test can catch a
        // product-side layout drift instead of inheriting it through shared constants.
        let mutations: [Mutation] = [
            Mutation(name: "magic", hasVisibleGap: false, expectedReason: .invalidMagic) { data, offset, _ in data[offset] ^= 0x01 },
            Mutation(name: "version", hasVisibleGap: false, expectedReason: .unsupportedVersion) { data, offset, _ in data[offset + 8] ^= 0x01 },
            Mutation(name: "generation", hasVisibleGap: false, expectedReason: .headerChecksumMismatch) { data, offset, _ in data[offset + 10] ^= 0x01 },
            Mutation(name: "sequence", hasVisibleGap: false, expectedReason: .headerChecksumMismatch) { data, offset, _ in data[offset + 26] ^= 0x01 },
            Mutation(name: "declared-length", hasVisibleGap: false, expectedReason: .headerChecksumMismatch) { data, offset, _ in data[offset + 42] = 0xFF; data[offset + 43] = 0xFF },
            Mutation(name: "acquisition-time", hasVisibleGap: false, expectedReason: .headerChecksumMismatch) { data, offset, _ in data[offset + 34] ^= 0x01 },
            Mutation(name: "record-tag", hasVisibleGap: true, expectedReason: .recordTagMismatch) { data, offset, payloadBytes in data[offset + OmiLaunchCaptureFormat.headerByteCount + payloadBytes] ^= 0x01 },
            Mutation(name: "payload", hasVisibleGap: true, expectedReason: .recordTagMismatch) { data, offset, _ in data[offset + OmiLaunchCaptureFormat.headerByteCount] ^= 0x01 },
            Mutation(name: "tail-truncation", hasVisibleGap: true, expectedReason: .incompleteReservedRecord) { data, offset, _ in data.removeSubrange((offset + OmiLaunchCaptureFormat.headerByteCount + 1)..<data.count) },
            Mutation(name: "middle-framing", hasVisibleGap: false, expectedReason: .invalidMagic) { data, offset, _ in data.insert(0xFF, at: offset) },
        ]

        for mutation in mutations {
            let caseRoot = self.rootURL.appendingPathComponent(mutation.name, isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = UUID()
            let payload = Data("payload".utf8)
            let writer = OmiLaunchCaptureWriter(rootURL: caseRoot, generationID: generation, clock: MockObserverClock(), io: io)
            for sequence in 0..<3 {
                XCTAssertEqual(writer.append(Data(payload + Data([UInt8(sequence)]))), .retained(sequence: UInt64(sequence), retriedPending: false), mutation.name)
            }
            let fileURL = writer.fileURL
            var data = try Data(contentsOf: fileURL)
            let recordByteCount = OmiLaunchCaptureFormat.headerByteCount + payload.count + 1 + OmiLaunchCaptureFormat.recordTagByteCount
            let targetOffset = recordByteCount
            mutation.mutate(&data, targetOffset, payload.count + 1)
            try data.write(to: fileURL)

            let recovery = OmiLaunchCaptureRecovery(rootURL: caseRoot, generationID: generation, io: io)
            let result = recovery.recover()
            XCTAssertEqual(result.verifiedRecords.map(\.sequence), [0], mutation.name)
            XCTAssertEqual(result.verifiedPrefixNextSequence, 1, mutation.name)
            XCTAssertEqual(result.boundarySequence, mutation.hasVisibleGap ? 1 : nil, mutation.name)
            XCTAssertEqual(result.boundaryReason, mutation.expectedReason, mutation.name)
            XCTAssertEqual(recovery.emittedBoundaryDiagnosticCount, 1, mutation.name)
            XCTAssertLessThanOrEqual(io.largestSingleReadCount, OmiLaunchCaptureFormat.readerBodyBufferByteCount, mutation.name)
        }
    }

    func testUntrustworthyHeaderMakesNoSequenceClaim() throws {
        struct Mutation {
            let name: String
            let mutate: (inout Data, Int) -> Void
        }
        let mutations: [Mutation] = [
            Mutation(name: "magic") { data, offset in data[offset] ^= 0x01 },
            Mutation(name: "version") { data, offset in data[offset + 8] ^= 0x01 },
            Mutation(name: "generation") { data, offset in data[offset + 10] ^= 0x01 },
            Mutation(name: "sequence") { data, offset in data[offset + 26] ^= 0x01 },
            Mutation(name: "declared-length") { data, offset in data[offset + 42] = 0xFF; data[offset + 43] = 0xFF },
            Mutation(name: "acquisition-time") { data, offset in data[offset + 34] ^= 0x01 },
        ]

        for mutation in mutations {
            let caseRoot = self.rootURL.appendingPathComponent(mutation.name, isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = UUID()
            let writer = OmiLaunchCaptureWriter(rootURL: caseRoot, generationID: generation, clock: MockObserverClock(), io: io)
            XCTAssertEqual(writer.append(Data("first".utf8)), .retained(sequence: 0, retriedPending: false), mutation.name)
            XCTAssertEqual(writer.append(Data("second".utf8)), .retained(sequence: 1, retriedPending: false), mutation.name)
            let firstRecordByteCount = OmiLaunchCaptureFormat.headerByteCount
                + Data("first".utf8).count
                + OmiLaunchCaptureFormat.recordTagByteCount
            let fileURL = writer.fileURL
            var bytes = try Data(contentsOf: fileURL)
            mutation.mutate(&bytes, firstRecordByteCount)
            try bytes.write(to: fileURL)

            let result = OmiLaunchCaptureRecovery(rootURL: caseRoot, generationID: generation, io: io).recover()
            XCTAssertEqual(result.verifiedRecords.map(\.sequence), [0], mutation.name)
            XCTAssertEqual(result.verifiedPrefixNextSequence, 1, mutation.name)
            XCTAssertNil(result.boundarySequence, mutation.name)
        }
    }

    func testChecksumValidOversizeDeclaredLengthStopsBeforeBodyRead() throws {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("first".utf8)), .retained(sequence: 0, retriedPending: false))

        let hostileHeader = OmiLaunchCaptureHeader(
            generationID: generation,
            sequence: 1,
            acquiredAtUnixMicros: 1,
            declaredPayloadBytes: OmiLaunchCaptureFormat.maximumPayloadBytes + 1
        ).encoded()
        var bytes = try Data(contentsOf: writer.fileURL)
        bytes.append(hostileHeader)
        try bytes.write(to: writer.fileURL)

        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io)
        let result = recovery.recover()
        XCTAssertEqual(result.verifiedRecords.map(\.sequence), [0])
        XCTAssertEqual(result.verifiedPrefixNextSequence, 1)
        XCTAssertNil(result.boundarySequence)
        XCTAssertEqual(result.boundaryReason, .declaredLengthExceeded)
        XCTAssertEqual(recovery.emittedBoundaryDiagnosticCount, 1)
        XCTAssertLessThanOrEqual(io.largestSingleReadCount, OmiLaunchCaptureFormat.readerBodyBufferByteCount)
    }

    func testChecksumValidGenerationAndSequenceMismatchesAreVisibleGaps() throws {
        struct Mismatch {
            let name: String
            let header: (UUID) -> OmiLaunchCaptureHeader
            let reason: OmiLaunchCaptureBoundaryReason
            let sequence: UInt64
        }
        let mismatches: [Mismatch] = [
            Mismatch(
                name: "generation",
                header: { _ in OmiLaunchCaptureHeader(generationID: UUID(), sequence: 1, acquiredAtUnixMicros: 1, declaredPayloadBytes: 0) },
                reason: .generationMismatch,
                sequence: 1
            ),
            Mismatch(
                name: "sequence",
                header: { generation in OmiLaunchCaptureHeader(generationID: generation, sequence: 2, acquiredAtUnixMicros: 1, declaredPayloadBytes: 0) },
                reason: .sequenceMismatch,
                sequence: 2
            ),
        ]

        for mismatch in mismatches {
            let caseRoot = self.rootURL.appendingPathComponent(mismatch.name, isDirectory: true)
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = UUID()
            let writer = OmiLaunchCaptureWriter(rootURL: caseRoot, generationID: generation, clock: MockObserverClock(), io: io)
            XCTAssertEqual(writer.append(Data("first".utf8)), .retained(sequence: 0, retriedPending: false), mismatch.name)

            var bytes = try Data(contentsOf: writer.fileURL)
            bytes.append(mismatch.header(generation).encoded())
            try bytes.write(to: writer.fileURL)

            let recovery = OmiLaunchCaptureRecovery(rootURL: caseRoot, generationID: generation, io: io)
            let result = recovery.recover()
            XCTAssertEqual(result.verifiedRecords.map(\.sequence), [0], mismatch.name)
            XCTAssertEqual(result.boundarySequence, mismatch.sequence, mismatch.name)
            XCTAssertEqual(result.boundaryReason, mismatch.reason, mismatch.name)
            XCTAssertEqual(recovery.emittedBoundaryDiagnosticCount, 1, mismatch.name)
        }
    }

    func testReadFailureReportsTypedBoundary() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        XCTAssertEqual(writer.append(Data("record".utf8)), .retained(sequence: 0, retriedPending: false))
        io.failNext(.read)

        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io)
        let result = recovery.recover()
        XCTAssertTrue(result.verifiedRecords.isEmpty)
        XCTAssertNil(result.boundarySequence)
        XCTAssertEqual(result.boundaryReason, .readFailed)
        XCTAssertEqual(recovery.emittedBoundaryDiagnosticCount, 1)
    }

    func testQuarantineFailureRetainsEvidenceInPlace() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 2, afterBytes: 0)
        _ = writer.append(Data("payload".utf8))
        io.clearFaults()
        io.failNext(.move)

        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io)
        let result = recovery.recover()
        XCTAssertEqual(result.quarantineDisposition, .retainedInPlace)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.fileURL.path))
        XCTAssertEqual(recovery.emittedBoundaryDiagnosticCount, 1)
    }

    func testBoundaryMovesWholeGenerationToQuarantine() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 2, afterBytes: 0)
        _ = writer.append(Data("payload".utf8))
        io.clearFaults()

        let recovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io)
        let result = recovery.recover()
        let quarantineURL = self.rootURL
            .appendingPathComponent(OmiLaunchCaptureFormat.quarantineDirectoryName, isDirectory: true)
            .appendingPathComponent("\(writer.fileURL.deletingPathExtension().lastPathComponent)-boundary-0.\(OmiLaunchCaptureFormat.fileExtension)")
        XCTAssertEqual(result.quarantineDisposition, .moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
    }

    private func writer(generation: UUID, io: FaultInjectingOmiLaunchCaptureIO) -> OmiLaunchCaptureWriter {
        OmiLaunchCaptureWriter(rootURL: self.rootURL, generationID: generation, clock: MockObserverClock(), io: io)
    }
}
