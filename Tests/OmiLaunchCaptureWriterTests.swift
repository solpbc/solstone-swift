// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchCaptureWriterTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        self.rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmiLaunchCaptureWriterTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.rootURL)
    }

    func testBoundaryPayloadLengthsAreRetained() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let writer = self.writer(io: io)
        let lengths = [0, 1, OmiLaunchCaptureFormat.maximumPayloadBytes - 1, OmiLaunchCaptureFormat.maximumPayloadBytes]

        for (sequence, length) in lengths.enumerated() {
            XCTAssertEqual(writer.append(Data(repeating: UInt8(sequence), count: length)), .retained(sequence: UInt64(sequence), retriedPending: false))
        }

        let rejectedIO = FaultInjectingOmiLaunchCaptureIO()
        let rejectedWriter = self.writer(io: rejectedIO)
        XCTAssertEqual(rejectedIO.performedIOCallCount, 0)
        XCTAssertEqual(rejectedWriter.append(Data(repeating: 0, count: OmiLaunchCaptureFormat.maximumPayloadBytes + 1)), .notRetained(.oversizeActualLength))
        XCTAssertEqual(rejectedIO.performedIOCallCount, 0)
    }

    func testManyAppendsSurviveReopenInExactSequenceWithAcquisitionTimes() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let clock = MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000))
        let writer = OmiLaunchCaptureWriter(rootURL: self.rootURL, generationID: generation, clock: clock, io: io)
        let count = 2_000

        for sequence in 0..<count {
            let payload = Data(repeating: UInt8(sequence % Int(UInt8.max)), count: OmiLaunchCaptureFormat.maximumPayloadBytes)
            XCTAssertEqual(writer.append(payload), .retained(sequence: UInt64(sequence), retriedPending: false))
            clock.advance(by: 0.001)
        }
        XCTAssertLessThanOrEqual(writer.peakCaptureResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)

        let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertNil(result.boundaryReason)
        XCTAssertEqual(result.verifiedPrefixNextSequence, UInt64(count))
        XCTAssertEqual(result.verifiedPrefixEndOffset, count * (OmiLaunchCaptureFormat.headerByteCount + OmiLaunchCaptureFormat.maximumPayloadBytes + OmiLaunchCaptureFormat.recordTagByteCount))
    }

    func testPendingRejectionDoesNotOvertakeOriginalReservation() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        let pendingPayload = Data(repeating: 0x70, count: OmiLaunchCaptureFormat.maximumPayloadBytes)
        let nextPayload = Data(repeating: 0x71, count: OmiLaunchCaptureFormat.maximumPayloadBytes)
        io.failBarrier(onCall: 2)
        XCTAssertEqual(writer.append(pendingPayload), .visibleGap(sequence: 0, .commitBarrierFailed))

        io.failWrite(onCall: 2, afterBytes: 0)
        XCTAssertEqual(
            writer.append(nextPayload),
            .rejected(.pendingSlotOccupied(pendingSequence: 0, retryFailure: .payloadWriteFailed))
        )
        XCTAssertEqual(writer.peakCaptureResidentPayloadBytes, pendingPayload.count + nextPayload.count)
        XCTAssertLessThanOrEqual(writer.peakCaptureResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)
        io.clearFaults()
        XCTAssertEqual(writer.append(nextPayload), .retained(sequence: 1, retriedPending: true))
        XCTAssertEqual(writer.captureResidentPayloadBytes, 0)

        let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertEqual(result.verifiedPrefixNextSequence, 2)
    }

    func testAppendsResumeAfterInjectedFaultIsRemoved() {
        let openIO = FaultInjectingOmiLaunchCaptureIO()
        let openGeneration = UUID()
        let openWriter = self.writer(generation: openGeneration, io: openIO)
        openIO.failNext(.open)
        XCTAssertEqual(openWriter.append(Data("open".utf8)), .notRetained(.openFailed))
        XCTAssertEqual(openWriter.captureResidentPayloadBytes, 0)
        openIO.clearFaults()
        XCTAssertEqual(openWriter.append(Data("open".utf8)), .retained(sequence: 0, retriedPending: false))
        XCTAssertNil(OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: openGeneration, io: openIO).recover().boundaryReason)

        let writeIO = FaultInjectingOmiLaunchCaptureIO()
        let writeGeneration = UUID()
        let writeWriter = self.writer(generation: writeGeneration, io: writeIO)
        writeIO.failWrite(onCall: 2, afterBytes: 0)
        XCTAssertEqual(writeWriter.append(Data("write".utf8)), .visibleGap(sequence: 0, .payloadWriteFailed))
        XCTAssertLessThanOrEqual(writeWriter.peakCaptureResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)
        writeIO.clearFaults()
        XCTAssertEqual(writeWriter.append(Data("next".utf8)), .retained(sequence: 1, retriedPending: true))
        XCTAssertEqual(writeWriter.captureResidentPayloadBytes, 0)
        XCTAssertNil(OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: writeGeneration, io: writeIO).recover().boundaryReason)

        let barrierIO = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let barrierWriter = self.writer(generation: generation, io: barrierIO)
        barrierIO.failBarrier(onCall: 2)
        XCTAssertEqual(barrierWriter.append(Data("barrier".utf8)), .visibleGap(sequence: 0, .commitBarrierFailed))
        barrierIO.clearFaults()
        XCTAssertEqual(barrierWriter.append(Data("next".utf8)), .retained(sequence: 1, retriedPending: true))
        XCTAssertEqual(barrierWriter.captureResidentPayloadBytes, 0)
        XCTAssertLessThanOrEqual(barrierWriter.peakCaptureResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)
        XCTAssertNil(OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: barrierIO).recover().boundaryReason)

        let moveIO = FaultInjectingOmiLaunchCaptureIO()
        let moveGeneration = UUID()
        let moveWriter = self.writer(generation: moveGeneration, io: moveIO)
        moveIO.failWrite(onCall: 2, afterBytes: 0)
        XCTAssertEqual(moveWriter.append(Data("move".utf8)), .visibleGap(sequence: 0, .payloadWriteFailed))
        moveIO.clearFaults()
        moveIO.failNext(.move)
        let moveRecovery = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: moveGeneration, io: moveIO).recover()
        XCTAssertEqual(moveRecovery.boundarySequence, 0)
        XCTAssertLessThanOrEqual(moveWriter.peakCaptureResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes)
    }

    func testPreReservationFailureLeavesWriterUsableAndMakesNoClaim() {
        struct Failure {
            let name: String
            let outcome: OmiLaunchCaptureNotRetainedReason
            let inject: (FaultInjectingOmiLaunchCaptureIO) -> Void
        }
        let failures: [Failure] = [
            Failure(name: "header-write", outcome: .headerWriteFailed) { io in
                io.failWrite(onCall: 1, afterBytes: OmiLaunchCaptureFormat.headerByteCount - 1)
            },
            Failure(name: "reservation-barrier", outcome: .reservationBarrierFailed) { io in
                io.failBarrier(onCall: 1)
            },
        ]

        for failure in failures {
            let io = FaultInjectingOmiLaunchCaptureIO()
            let generation = UUID()
            let writer = self.writer(generation: generation, io: io)
            failure.inject(io)
            XCTAssertEqual(writer.append(Data("fault".utf8)), .notRetained(failure.outcome), failure.name)
            XCTAssertEqual(writer.captureResidentPayloadBytes, 0, failure.name)
            XCTAssertLessThanOrEqual(writer.peakCaptureResidentPayloadBytes, OmiLaunchCaptureFormat.maximumResidentPayloadBytes, failure.name)
            io.clearFaults()
            XCTAssertEqual(writer.append(Data("retry".utf8)), .retained(sequence: 0, retriedPending: false), failure.name)

            let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
            XCTAssertNil(result.boundaryReason, failure.name)
            XCTAssertNil(result.boundarySequence, failure.name)
            XCTAssertEqual(result.verifiedPrefixNextSequence, 1, failure.name)
        }
    }

    func testFailedPreReservationCleanupBlocksWithoutDestroyingCommittedEvidence() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let writer = self.writer(generation: generation, io: io)
        let committedPayload = Data("committed".utf8)
        XCTAssertEqual(writer.append(committedPayload), .retained(sequence: 0, retriedPending: false))
        let committedEnd = OmiLaunchCaptureFormat.headerByteCount
            + committedPayload.count
            + OmiLaunchCaptureFormat.recordTagByteCount

        io.failWrite(onCall: 1, afterBytes: OmiLaunchCaptureFormat.headerByteCount - 1)
        io.failNext(.truncate)
        XCTAssertEqual(writer.append(Data("fault".utf8)), .notRetained(.headerWriteFailed))
        XCTAssertEqual(writer.captureResidentPayloadBytes, 0)
        XCTAssertEqual(
            writer.append(Data("blocked".utf8)),
            .rejected(.recoveryBoundary(reason: .preReservationCleanupFailed, offset: committedEnd))
        )

        io.clearFaults()
        let result = OmiLaunchCaptureRecovery(rootURL: self.rootURL, generationID: generation, io: io).recover()
        XCTAssertEqual(result.verifiedPrefixNextSequence, 1)
        XCTAssertEqual(result.boundaryReason, .incompleteHeader)
        XCTAssertNil(result.boundarySequence)
    }

    func testWriterBlocksAfterRealRecoveryBoundary() {
        let io = FaultInjectingOmiLaunchCaptureIO()
        let generation = UUID()
        let interruptedWriter = self.writer(generation: generation, io: io)
        io.failWrite(onCall: 2, afterBytes: 0)
        XCTAssertEqual(interruptedWriter.append(Data("gap".utf8)), .visibleGap(sequence: 0, .payloadWriteFailed))
        io.clearFaults()

        let blockedWriter = self.writer(generation: generation, io: io)
        XCTAssertEqual(
            blockedWriter.append(Data("blocked".utf8)),
            .rejected(.recoveryBoundary(reason: .incompleteReservedRecord, offset: 0))
        )

        let nextGenerationWriter = self.writer(generation: UUID(), io: io)
        XCTAssertEqual(nextGenerationWriter.append(Data("fresh".utf8)), .retained(sequence: 0, retriedPending: false))
    }

    private func writer(
        generation: UUID = UUID(),
        io: FaultInjectingOmiLaunchCaptureIO
    ) -> OmiLaunchCaptureWriter {
        OmiLaunchCaptureWriter(
            rootURL: self.rootURL,
            generationID: generation,
            clock: MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000)),
            io: io
        )
    }
}
