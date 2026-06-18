// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import AVFoundation
import Foundation
import Opus

@MainActor
final class BLEOpusAudioDecoder {
    private let opusDecoder: Opus.Decoder

    init() throws {
        guard let format = AVAudioFormat(opusPCMFormat: .int16, sampleRate: 16_000, channels: 1) else {
            throw Opus.Error.badArgument
        }
        self.opusDecoder = try Opus.Decoder(format: format)
    }

    func decode(_ frame: Data) -> [Int16]? {
        guard let buffer = try? self.opusDecoder.decode(frame),
              let channelData = buffer.int16ChannelData
        else {
            return nil
        }

        let sampleCount = Int(buffer.frameLength)
        let channel = channelData[0]
        return (0..<sampleCount).map { channel[$0] }
    }
}
