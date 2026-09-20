// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import Foundation

enum MobileSegmentTestFixtures {
    static func writeReadableAudio(at url: URL, seconds: TimeInterval, sampleRate: Double = 16_000) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        let writeURL: URL
        let isPart = url.pathExtension == "part"
        if isPart {
            writeURL = url.deletingPathExtension()
            try? FileManager.default.removeItem(at: writeURL)
        } else {
            writeURL = url
        }
        let file = try AVAudioFile(forWriting: writeURL, settings: settings)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frameCount = AVAudioFrameCount((sampleRate * seconds).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        try file.write(from: buffer)
        if isPart {
            try FileManager.default.moveItem(at: writeURL, to: url)
        }
    }

    static func writeFtypOnlyAudio(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ftypBytes: [UInt8] = [
            0x00, 0x00, 0x00, 0x18, // size: 24
            0x66, 0x74, 0x79, 0x70, // 'ftyp'
            0x6D, 0x70, 0x34, 0x32, // 'mp42'
            0x00, 0x00, 0x00, 0x00, // minor version
            0x69, 0x73, 0x6F, 0x6D, // compatible: 'isom'
            0x6D, 0x70, 0x34, 0x32, // compatible: 'mp42'
        ]
        try Data(ftypBytes).write(to: url, options: .atomic)
    }

    static func writeUnreadableRegularAudio(at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unreadable-audio-content".utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
    }

    @MainActor
    static func setAudioModificationDate(at url: URL, offset: TimeInterval, clock: any ObserverClock) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: clock.now().addingTimeInterval(offset)],
            ofItemAtPath: url.path
        )
    }
}
