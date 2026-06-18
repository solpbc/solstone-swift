// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class BLESDFileReassemblerTests: XCTestCase {
    func testLengthPrefixedFramesRetainTruncatedTail() {
        var reassembler = BLESDFileReassembler()
        let firstFrame = Data([0x10, 0x11])
        let secondFrame = Data([0x20, 0x21, 0x22])
        let trailingFrame = Data([0x30, 0x31, 0x32, 0x33])

        var firstChunk = Self.stream([
            Self.unit(firstFrame),
            Self.unit(secondFrame)
        ])
        firstChunk.append(UInt8(trailingFrame.count))
        firstChunk.append(trailingFrame.prefix(2))

        let firstOutput = reassembler.ingest(firstChunk)
        let secondOutput = reassembler.ingest(Data(trailingFrame.dropFirst(2)))

        XCTAssertEqual(firstOutput.completedFrames, [firstFrame, secondFrame])
        XCTAssertTrue(firstOutput.markers.isEmpty)
        XCTAssertEqual(secondOutput.completedFrames, [trailingFrame])
        XCTAssertTrue(secondOutput.markers.isEmpty)
    }

    func testMarkerParsesLittleEndianEpochBetweenFrames() {
        var reassembler = BLESDFileReassembler()
        let epoch: UInt32 = 1_700_000_123
        let firstFrame = Data([0xAA, 0xBB])
        let secondFrame = Data([0xCC])

        let output = reassembler.ingest(Self.stream([
            Self.unit(firstFrame),
            Self.marker(epoch: epoch),
            Self.unit(secondFrame)
        ]))

        XCTAssertEqual(output.completedFrames, [firstFrame, secondFrame])
        XCTAssertEqual(output.markers, [.audio(epoch: epoch)])
    }

    func testZeroPaddingIsSkipped() {
        var reassembler = BLESDFileReassembler()
        let frame = Data([0x44, 0x55])

        let output = reassembler.ingest(Self.stream([
            Data([0x00, 0x00]),
            Self.unit(frame),
            Data([0x00])
        ]))

        XCTAssertEqual(output.completedFrames, [frame])
        XCTAssertTrue(output.markers.isEmpty)
    }

    private static func unit(_ payload: Data) -> Data {
        var data = Data([UInt8(payload.count)])
        data.append(payload)
        return data
    }

    private static func stream(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { result, unit in
            result.append(unit)
        }
    }

    private static func marker(epoch: UInt32) -> Data {
        Data([
            0xFF,
            UInt8(epoch & 0x000000FF),
            UInt8((epoch >> 8) & 0x000000FF),
            UInt8((epoch >> 16) & 0x000000FF),
            UInt8((epoch >> 24) & 0x000000FF)
        ])
    }
}
