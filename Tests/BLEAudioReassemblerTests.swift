// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class BLEAudioReassemblerTests: XCTestCase {
    func testSingleFragmentFrameEmitsOnNextStart() {
        var reassembler = BLEAudioReassembler()

        let first = reassembler.ingest(Self.packet(0, index: 0, payload: Data("one".utf8)))
        let second = reassembler.ingest(Self.packet(1, index: 0, payload: Data("two".utf8)))

        XCTAssertTrue(first.completedFrames.isEmpty)
        XCTAssertEqual(second.completedFrames, [Data("one".utf8)])
        XCTAssertEqual(reassembler.packets, 2)
        XCTAssertEqual(reassembler.frames, 1)
        XCTAssertEqual(reassembler.gaps, 0)
        XCTAssertEqual(reassembler.outOfOrder, 0)
    }

    func testMultiFragmentFrameUsesIncrementingPacketNumbers() {
        var reassembler = BLEAudioReassembler()

        XCTAssertTrue(reassembler.ingest(Self.packet(0, index: 0, payload: Data([0xAA]))).completedFrames.isEmpty)
        XCTAssertTrue(reassembler.ingest(Self.packet(1, index: 1, payload: Data([0xBB, 0xCC]))).completedFrames.isEmpty)
        XCTAssertTrue(reassembler.ingest(Self.packet(2, index: 2, payload: Data([0xDD]))).completedFrames.isEmpty)
        let output = reassembler.ingest(Self.packet(3, index: 0, payload: Data([0xEE])))

        XCTAssertEqual(output.completedFrames, [Data([0xAA, 0xBB, 0xCC, 0xDD])])
        XCTAssertEqual(reassembler.gaps, 0)
        XCTAssertEqual(reassembler.outOfOrder, 0)
        XCTAssertEqual(reassembler.frames, 1)
    }

    func testDroppedPacketCountsGapAndDropsInProgress() {
        var reassembler = BLEAudioReassembler()

        _ = reassembler.ingest(Self.packet(0, index: 0, payload: Data("lost".utf8)))
        let gapOutput = reassembler.ingest(Self.packet(2, index: 0, payload: Data("fresh".utf8)))
        let flushOutput = reassembler.ingest(Self.packet(3, index: 0, payload: Data("next".utf8)))

        XCTAssertTrue(gapOutput.completedFrames.isEmpty)
        XCTAssertEqual(flushOutput.completedFrames, [Data("fresh".utf8)])
        XCTAssertEqual(reassembler.gaps, 1)
        XCTAssertEqual(reassembler.frames, 1)
    }

    func testBackwardOrDuplicatePacketCountsOutOfOrder() {
        var duplicateReassembler = BLEAudioReassembler()
        _ = duplicateReassembler.ingest(Self.packet(5, index: 0, payload: Data("first".utf8)))
        _ = duplicateReassembler.ingest(Self.packet(5, index: 0, payload: Data("duplicate".utf8)))

        var backwardReassembler = BLEAudioReassembler()
        _ = backwardReassembler.ingest(Self.packet(5, index: 0, payload: Data("first".utf8)))
        _ = backwardReassembler.ingest(Self.packet(4, index: 0, payload: Data("back".utf8)))

        XCTAssertGreaterThanOrEqual(duplicateReassembler.outOfOrder, 1)
        XCTAssertGreaterThanOrEqual(backwardReassembler.outOfOrder, 1)
    }

    func testMalformedShortPayloadIsCountedAndIgnored() {
        var reassembler = BLEAudioReassembler()

        let output = reassembler.ingest(Data([0x01, 0x00]))

        XCTAssertEqual(output, BLEReassemblyOutput())
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
