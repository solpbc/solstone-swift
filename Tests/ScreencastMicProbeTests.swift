// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import CoreAudioTypes
import XCTest
@testable import solstone_swift

final class ScreencastMicProbeTests: XCTestCase {
    private func format(bits: UInt32, flags: AudioFormatFlags) -> AudioStreamBasicDescription {
        var description = AudioStreamBasicDescription()
        description.mFormatID = kAudioFormatLinearPCM
        description.mFormatFlags = flags
        description.mBitsPerChannel = bits
        return description
    }

    private func read<Word>(_ words: [Word], _ format: AudioStreamBasicDescription) -> ScreencastMicBufferReading {
        words.withUnsafeBytes { ScreencastMicBufferReading.read(bytes: $0, format: format) }
    }

    func testAllZeroIntegerSamplesAreExactZero() {
        let reading = self.read([Int16](repeating: 0, count: 1024), self.format(bits: 16, flags: kAudioFormatFlagIsSignedInteger))
        XCTAssertEqual(reading.sampleCount, 1024)
        XCTAssertTrue(reading.isExactZero)
    }

    func testOneLowBitInAQuietRoomIsNotExactZero() {
        var samples = [Int16](repeating: 0, count: 1024)
        samples[512] = -1
        let reading = self.read(samples, self.format(bits: 16, flags: kAudioFormatFlagIsSignedInteger))
        XCTAssertEqual(reading.nonZeroCount, 1)
        XCTAssertFalse(reading.isExactZero)
        XCTAssertEqual(reading.peak ?? 0, 1.0 / 32768, accuracy: 1e-9)
    }

    func testFloatNegativeZeroIsExactZeroAndASubnormalIsNot() {
        let floatFormat = self.format(bits: 32, flags: kAudioFormatFlagIsFloat)
        XCTAssertTrue(self.read([Float(-0.0), Float(0.0)], floatFormat).isExactZero)
        XCTAssertFalse(self.read([Float.leastNonzeroMagnitude, Float(0.0)], floatFormat).isExactZero)
    }

    func testBigEndianSamplesReadByTheirValue() {
        let flags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian
        let reading = self.read([Int16(16384).bigEndian], self.format(bits: 16, flags: flags))
        XCTAssertEqual(reading.peak ?? 0, 0.5, accuracy: 1e-9)
    }

    func testAnEmptyBufferIsNotExactZero() {
        let reading = self.read([Int16](), self.format(bits: 16, flags: kAudioFormatFlagIsSignedInteger))
        XCTAssertFalse(reading.isExactZero)
    }

    func testAnUnreadFormatStillTellsZeroBytesFromNonZero() {
        let oddFormat = self.format(bits: 24, flags: kAudioFormatFlagIsSignedInteger)
        XCTAssertTrue(self.read([UInt8](repeating: 0, count: 6), oddFormat).isExactZero)
        let reading = self.read([UInt8(0), 1, 0], oddFormat)
        XCTAssertFalse(reading.isExactZero)
        XCTAssertNil(reading.peak)
    }
}
#endif
