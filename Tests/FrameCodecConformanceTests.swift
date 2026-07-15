// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
@testable import SPLTunnel
import XCTest

nonisolated final class FrameCodecConformanceTests: XCTestCase {
    func testValidateFlagsMatchesCanonicalValidSet() throws {
        let valid: Set<UInt8> = [
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x10, 0x20, 0x40
        ]

        for raw in UInt8(0)...UInt8(0x7f) {
            if raw == 0 {
                XCTAssertThrowsError(try validateFlags(raw), "flags=\(raw)") { error in
                    XCTAssertEqual(error as? FramingError, .noPrimaryFlag)
                }
            } else if valid.contains(raw) {
                XCTAssertNoThrow(try validateFlags(raw), "flags=\(raw)")
            } else {
                XCTAssertThrowsError(try validateFlags(raw), "flags=\(raw)") { error in
                    XCTAssertEqual(error as? FramingError, .invalidFlagCombination)
                }
            }
        }
    }

    func testEncodeFrameStillRejectsInvalidFlagCombinations() {
        let openReset = Frame(
            streamID: 1,
            flags: FrameFlags.open.rawValue | FrameFlags.reset.rawValue,
            payload: Data()
        )
        XCTAssertThrowsError(try encodeFrame(openReset)) { error in
            XCTAssertEqual(error as? FramingError, .invalidFlagCombination)
        }

        let dataReset = Frame(streamID: 1, flags: 0x0a, payload: Data())
        XCTAssertThrowsError(try encodeFrame(dataReset)) { error in
            XCTAssertEqual(error as? FramingError, .invalidFlagCombination)
        }
    }

    func testDecoderDefersValidCombinationJudgmentToDispatch() throws {
        var decoder = FrameDecoder()
        decoder.feed(makeRawFrameBytes(streamID: 1, flags: 0x0a))

        let frame = try XCTUnwrap(try decoder.next())
        XCTAssertEqual(frame, Frame(streamID: 1, flags: 0x0a, payload: Data()))
        XCTAssertNil(try decoder.next())
    }

    func testDecoderStillRejectsReservedBit() {
        var decoder = FrameDecoder()
        decoder.feed(makeRawFrameBytes(streamID: 1, flags: 0x82))

        XCTAssertThrowsError(try decoder.next()) { error in
            XCTAssertEqual(error as? FramingError, .reservedBitsSet)
        }
    }

    func testParseResetReasonToleratesEmptyLongAndUnknownPayloads() {
        let empty = parseResetReason(from: Data())
        XCTAssertEqual(empty.reason, .unspecified)
        XCTAssertEqual(empty.rawByte, 0x00)

        let knownLong = parseResetReason(from: Data([0x05, 0x01]))
        XCTAssertEqual(knownLong.reason, .cancel)
        XCTAssertEqual(knownLong.rawByte, 0x05)

        let unknown = parseResetReason(from: Data([0x7e]))
        XCTAssertEqual(unknown.reason, .unspecified)
        XCTAssertEqual(unknown.rawByte, 0x7e)

        let unknownLong = parseResetReason(from: Data([0x00, 0x00, 0x00, 0x01]))
        XCTAssertEqual(unknownLong.reason, .unspecified)
        XCTAssertEqual(unknownLong.rawByte, 0x00)
    }
}
