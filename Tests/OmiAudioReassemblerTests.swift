// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class OmiAudioReassemblerTests: XCTestCase {
    func testSingleFragmentFrameEmitsOnNextStart() {
        var reassembler = OmiAudioReassembler()

        let first = reassembler.ingest(Self.packet(0, index: 0, payload: Data("one".utf8)), acquiredAt: .distantPast)
        let second = reassembler.ingest(Self.packet(1, index: 0, payload: Data("two".utf8)), acquiredAt: .distantFuture)

        XCTAssertTrue(first.completedFrames.isEmpty)
        XCTAssertEqual(second.completedFrames.map(\.data), [Data("one".utf8)])
        XCTAssertEqual(reassembler.packets, 2)
        XCTAssertEqual(reassembler.frames, 1)
        XCTAssertEqual(reassembler.gaps, 0)
        XCTAssertEqual(reassembler.outOfOrder, 0)
    }

    func testMultiFragmentFrameUsesIncrementingPacketNumbers() {
        var reassembler = OmiAudioReassembler()

        XCTAssertTrue(reassembler.ingest(Self.packet(0, index: 0, payload: Data([0xAA])), acquiredAt: .distantPast).completedFrames.isEmpty)
        XCTAssertTrue(reassembler.ingest(Self.packet(1, index: 1, payload: Data([0xBB, 0xCC])), acquiredAt: .distantPast).completedFrames.isEmpty)
        XCTAssertTrue(reassembler.ingest(Self.packet(2, index: 2, payload: Data([0xDD])), acquiredAt: .distantPast).completedFrames.isEmpty)
        let output = reassembler.ingest(Self.packet(3, index: 0, payload: Data([0xEE])), acquiredAt: .distantFuture)

        XCTAssertEqual(output.completedFrames.map(\.data), [Data([0xAA, 0xBB, 0xCC, 0xDD])])
        XCTAssertEqual(reassembler.gaps, 0)
        XCTAssertEqual(reassembler.outOfOrder, 0)
        XCTAssertEqual(reassembler.frames, 1)
    }

    func testDroppedPacketCountsGapAndDropsInProgress() {
        var reassembler = OmiAudioReassembler()

        _ = reassembler.ingest(Self.packet(0, index: 0, payload: Data("lost".utf8)), acquiredAt: .distantPast)
        let gapOutput = reassembler.ingest(Self.packet(2, index: 0, payload: Data("fresh".utf8)), acquiredAt: .distantPast)
        let flushOutput = reassembler.ingest(Self.packet(3, index: 0, payload: Data("next".utf8)), acquiredAt: .distantFuture)

        XCTAssertTrue(gapOutput.completedFrames.isEmpty)
        XCTAssertEqual(flushOutput.completedFrames.map(\.data), [Data("fresh".utf8)])
        XCTAssertEqual(reassembler.gaps, 1)
        XCTAssertEqual(reassembler.frames, 1)
    }

    func testBackwardOrDuplicatePacketCountsOutOfOrder() {
        var duplicateReassembler = OmiAudioReassembler()
        _ = duplicateReassembler.ingest(Self.packet(5, index: 0, payload: Data("first".utf8)), acquiredAt: .distantPast)
        _ = duplicateReassembler.ingest(Self.packet(5, index: 0, payload: Data("duplicate".utf8)), acquiredAt: .distantFuture)

        var backwardReassembler = OmiAudioReassembler()
        _ = backwardReassembler.ingest(Self.packet(5, index: 0, payload: Data("first".utf8)), acquiredAt: .distantPast)
        _ = backwardReassembler.ingest(Self.packet(4, index: 0, payload: Data("back".utf8)), acquiredAt: .distantFuture)

        XCTAssertGreaterThanOrEqual(duplicateReassembler.outOfOrder, 1)
        XCTAssertGreaterThanOrEqual(backwardReassembler.outOfOrder, 1)
    }

    func testMalformedShortPayloadIsCountedAndIgnored() {
        var reassembler = OmiAudioReassembler()

        let output = reassembler.ingest(Data([0x01, 0x00]), acquiredAt: .distantPast)

        XCTAssertEqual(output, OmiReassemblyOutput())
        XCTAssertEqual(reassembler.malformed, 1)
        XCTAssertEqual(reassembler.packets, 0)
    }

    private static func packet(_ packetNumber: UInt16, index: UInt8, payload: Data) -> Data {
        var data = Data([
            UInt8(packetNumber & 0x00FF),
            UInt8(packetNumber >> 8),
            index
        ])
        data.append(payload)
        return data
    }
}
