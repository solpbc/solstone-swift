// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

@MainActor
final class OmiLaunchCaptureLeaseTests: XCTestCase {
    private var rootURL: URL!

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
        XCTAssertEqual(restarted.lease(), .lease(first))
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

    private func writer(generation: UUID, io: FaultInjectingOmiLaunchCaptureIO) -> OmiLaunchCaptureWriter {
        OmiLaunchCaptureWriter(
            rootURL: self.rootURL,
            generationID: generation,
            clock: MockObserverClock(now: Date(timeIntervalSince1970: 1_800_000_000)),
            io: io
        )
    }
}
