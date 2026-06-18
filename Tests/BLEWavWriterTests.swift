// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import Foundation
import XCTest

nonisolated final class BLEWavWriterTests: XCTestCase {
    func testWavDataWritesCanonicalPCM16Header() {
        let data = BLEWavWriter.wavData(pcm16: [1, -1, 32_767, -32_768])

        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(Self.uint32LE(data, at: 4), 44)
        XCTAssertEqual(String(decoding: data[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: data[12..<16], as: UTF8.self), "fmt ")
        XCTAssertEqual(Self.uint32LE(data, at: 16), 16)
        XCTAssertEqual(Self.uint16LE(data, at: 20), 1)
        XCTAssertEqual(Self.uint16LE(data, at: 22), 1)
        XCTAssertEqual(Self.uint32LE(data, at: 24), 16_000)
        XCTAssertEqual(Self.uint16LE(data, at: 34), 16)
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertEqual(Self.uint32LE(data, at: 40), 8)
        XCTAssertEqual(data.count, 44 + 8)
    }

    private static func uint16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
