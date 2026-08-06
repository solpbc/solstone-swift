// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class OmiAudioCodecInfoTests: XCTestCase {
    func testCodecLabels() {
        XCTAssertEqual(OmiAudioCodecInfo.label(for: 0), "pcm16 16 kHz mono")
        XCTAssertEqual(OmiAudioCodecInfo.label(for: 1), "pcm16 8 kHz mono")
        XCTAssertEqual(OmiAudioCodecInfo.label(for: 10), "µ-law 16 kHz mono")
        XCTAssertEqual(OmiAudioCodecInfo.label(for: 11), "µ-law 8 kHz mono")
        XCTAssertEqual(OmiAudioCodecInfo.label(for: 20), "opus 16 kHz mono")
        XCTAssertEqual(OmiAudioCodecInfo.label(for: 21), "opus 16 kHz mono (fs320)")
        XCTAssertTrue(OmiAudioCodecInfo.label(for: 99).contains("unknown"))
    }
}
