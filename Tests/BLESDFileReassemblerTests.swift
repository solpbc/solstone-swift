// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class BLESDFileReassemblerTests: XCTestCase {
    func testBlockReturnsRecordsBeforeTrailingPadding() {
        let reassembler = BLESDFileReassembler()
        let frames = [
            Data([0xB8, 0x11, 0x12, 0x13]),
            Data([0xB8, 0x21, 0x22]),
            Data([0xB8, 0x31, 0x32, 0x33, 0x34])
        ]

        var block = frames.reduce(into: Data()) { result, frame in
            result.append(Self.record(frame))
        }
        block.append(Data(repeating: 0, count: 440 - block.count))

        XCTAssertEqual(reassembler.ingest(block), frames)
    }

    func testOverflowingRecordStopsAfterPriorCompleteFrames() {
        let reassembler = BLESDFileReassembler()
        let frames = [
            Self.opusPayload(byte: 0x41, count: 200),
            Self.opusPayload(byte: 0x51, count: 200),
            Self.opusPayload(byte: 0x61, count: 31)
        ]
        var block = frames.reduce(into: Data()) { result, frame in
            result.append(Self.record(frame))
        }
        block.append(10)
        block.append(Data([0xB8, 0x71, 0x72, 0x73, 0x74]))

        XCTAssertEqual(block.count, 440)
        XCTAssertEqual(reassembler.ingest(block), frames)
    }

    func testZeroLengthStopsParsingMidBlock() {
        let reassembler = BLESDFileReassembler()
        let firstFrame = Data([0xB8, 0x61, 0x62])
        let ignoredFrame = Data([0xB8, 0x71, 0x72])
        var block = Self.record(firstFrame)
        block.append(0)
        block.append(Self.record(ignoredFrame))
        block.append(Data(repeating: 0, count: 440 - block.count))

        XCTAssertEqual(reassembler.ingest(block), [firstFrame])
    }

    func testShortFinalBlockReturnsCompleteRecordsBeforeTruncatedTail() {
        let reassembler = BLESDFileReassembler()
        let firstFrame = Data([0xB8, 0x81, 0x82, 0x83])
        let secondFrame = Data([0xB8, 0x91])
        var block = Self.record(firstFrame)
        block.append(Self.record(secondFrame))
        block.append(5)
        block.append(Data([0xB8, 0xA1]))

        XCTAssertLessThan(block.count, 440)
        XCTAssertEqual(reassembler.ingest(block), [firstFrame, secondFrame])
    }

    private static func record(_ opus: Data) -> Data {
        var data = Data([UInt8(opus.count)])
        data.append(opus)
        return data
    }

    private static func opusPayload(byte: UInt8, count: Int) -> Data {
        var data = Data([0xB8])
        data.append(Data(repeating: byte, count: count - 1))
        return data
    }
}
