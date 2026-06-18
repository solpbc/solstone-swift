// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation

nonisolated enum BLEWavWriter {
    static func wavData(pcm16 samples: [Int16], sampleRate: Int = 16_000, channels: Int = 1) -> Data {
        let bytesPerSample = 2
        let dataLength = samples.count * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataLength)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        data.appendUInt32LE(UInt32(36 + dataLength))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.appendASCII("fmt ")
        data.appendUInt32LE(16)
        data.appendUInt16LE(1)
        data.appendUInt16LE(UInt16(channels))
        data.appendUInt32LE(UInt32(sampleRate))
        data.appendUInt32LE(UInt32(byteRate))
        data.appendUInt16LE(UInt16(blockAlign))
        data.appendUInt16LE(16)
        data.appendASCII("data")
        data.appendUInt32LE(UInt32(dataLength))
        for sample in samples {
            data.appendInt16LE(sample)
        }
        return data
    }
}

private extension Data {
    nonisolated mutating func appendASCII(_ string: String) {
        self.append(contentsOf: string.utf8)
    }

    nonisolated mutating func appendUInt16LE(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            self.append(contentsOf: bytes)
        }
    }

    nonisolated mutating func appendUInt32LE(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            self.append(contentsOf: bytes)
        }
    }

    nonisolated mutating func appendInt16LE(_ value: Int16) {
        self.appendUInt16LE(UInt16(bitPattern: value))
    }
}
