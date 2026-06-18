// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class BLEAudioMarkerTests: XCTestCase {
    func testMarkersParseEpochAndDoNotAffectFrameAssembly() {
        var reassembler = BLEAudioReassembler()
        let firstEpoch: UInt32 = 1_700_000_000
        let secondEpoch: UInt32 = 1_700_000_123

        _ = reassembler.ingest(Self.packet(0, index: 0, payload: Data("he".utf8)))
        let firstMarker = reassembler.ingest(Self.packet(1, index: 0xFF, payload: Self.epochPayload(firstEpoch)))
        _ = reassembler.ingest(Self.packet(2, index: 1, payload: Data("llo".utf8)))
        let secondMarker = reassembler.ingest(Self.packet(3, index: 0xFF, payload: Self.epochPayload(secondEpoch)))
        let output = reassembler.ingest(Self.packet(4, index: 0, payload: Data("next".utf8)))

        XCTAssertEqual(firstMarker.markers, [BLEAudioMarker.audio(epoch: firstEpoch)])
        XCTAssertEqual(secondMarker.markers, [BLEAudioMarker.audio(epoch: secondEpoch)])
        XCTAssertEqual(output.completedFrames, [Data("hello".utf8)])
        XCTAssertEqual(reassembler.markers, 2)
        XCTAssertEqual(reassembler.lastMarkerEpoch, secondEpoch)
        XCTAssertEqual(reassembler.gaps, 0)
        XCTAssertEqual(reassembler.outOfOrder, 0)
    }

    func testNoMarkersIsNotAnError() {
        var reassembler = BLEAudioReassembler()

        _ = reassembler.ingest(Self.packet(0, index: 0, payload: Data("a".utf8)))
        let output = reassembler.ingest(Self.packet(1, index: 0, payload: Data("b".utf8)))

        XCTAssertEqual(output.completedFrames, [Data("a".utf8)])
        XCTAssertEqual(reassembler.markers, 0)
        XCTAssertNil(reassembler.lastMarkerEpoch)
        XCTAssertEqual(reassembler.malformed, 0)
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

    private static func epochPayload(_ epoch: UInt32) -> Data {
        Data([
            UInt8(epoch & 0x000000FF),
            UInt8((epoch >> 8) & 0x000000FF),
            UInt8((epoch >> 16) & 0x000000FF),
            UInt8((epoch >> 24) & 0x000000FF)
        ])
    }
}
