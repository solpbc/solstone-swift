// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation

nonisolated enum OmiAudioChunkFormat {
    static let sampleLimit = 4_800_000
    static let chunkDurationSeconds: TimeInterval = 300
    static let sampleRate: Double = 16_000
    static let channelCount: AVAudioChannelCount = 1
    static let minChunkDurationSeconds: TimeInterval = 0.1

    static var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channelCount, AVEncoderBitRateKey: 32_000]
    }

    static func makeBuffer(_ samples: ArraySlice<Int16>) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, samples.count <= Int(UInt32.max),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: channelCount, interleaved: false)
        else { return nil }
        let count = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count), let channel = buffer.int16ChannelData?[0] else { return nil }
        samples.withUnsafeBufferPointer { if let base = $0.baseAddress { channel.update(from: base, count: samples.count) } }
        buffer.frameLength = count
        return buffer
    }
}
