// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

#if DEBUG
import CoreAudioTypes
import CoreMedia
import Foundation
import os

nonisolated private let screencastMicProbeLog = Logger(subsystem: "app.solstone.swift", category: "screencast-mic-probe")

/// What one microphone buffer held, by sample value. It keeps counts and a peak, never audio.
nonisolated struct ScreencastMicBufferReading: Equatable, Sendable {
    let sampleCount: Int
    let nonZeroCount: Int
    /// Largest magnitude on a 0...1 scale, or nil when the format isn't one this reads by sample.
    let peak: Double?

    var isExactZero: Bool {
        self.sampleCount > 0 && self.nonZeroCount == 0
    }

    static func read(bytes: UnsafeRawBufferPointer, format: AudioStreamBasicDescription) -> ScreencastMicBufferReading {
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        switch (isFloat, format.mBitsPerChannel) {
        case (true, 32):
            return self.scan(bytes, isBigEndian: isBigEndian, as: UInt32.self) { Double(abs(Float(bitPattern: $0))) }
        case (false, 16):
            return self.scan(bytes, isBigEndian: isBigEndian, as: UInt16.self) { Double(Int16(bitPattern: $0).magnitude) / 32768 }
        case (false, 32):
            return self.scan(bytes, isBigEndian: isBigEndian, as: UInt32.self) { Double(Int32(bitPattern: $0).magnitude) / 2147483648 }
        default:
            let nonZero = bytes.reduce(0) { $0 + ($1 == 0 ? 0 : 1) }
            return ScreencastMicBufferReading(sampleCount: bytes.count, nonZeroCount: nonZero, peak: nil)
        }
    }

    static func read(_ sampleBuffer: CMSampleBuffer) -> ScreencastMicBufferReading? {
        guard let format = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return nil }
        return try? sampleBuffer.withAudioBufferList { list, _ in
            var sampleCount = 0
            var nonZeroCount = 0
            var peak: Double?
            for buffer in list {
                let bytes = UnsafeRawBufferPointer(start: buffer.mData, count: Int(buffer.mDataByteSize))
                let reading = self.read(bytes: bytes, format: format)
                sampleCount += reading.sampleCount
                nonZeroCount += reading.nonZeroCount
                if let bufferPeak = reading.peak {
                    peak = max(peak ?? 0, bufferPeak)
                }
            }
            return ScreencastMicBufferReading(sampleCount: sampleCount, nonZeroCount: nonZeroCount, peak: peak)
        }
    }

    private static func scan<Word: FixedWidthInteger>(
        _ bytes: UnsafeRawBufferPointer,
        isBigEndian: Bool,
        as _: Word.Type,
        magnitude: (Word) -> Double
    ) -> ScreencastMicBufferReading {
        let wordSize = MemoryLayout<Word>.size
        let count = bytes.count / wordSize
        var nonZeroCount = 0
        var peak = 0.0
        for index in 0..<count {
            let raw = bytes.loadUnaligned(fromByteOffset: index * wordSize, as: Word.self)
            let value = magnitude(isBigEndian ? Word(bigEndian: raw) : Word(littleEndian: raw))
            if value > 0 {
                nonZeroCount += 1
                peak = max(peak, value)
            }
        }
        return ScreencastMicBufferReading(sampleCount: count, nonZeroCount: nonZeroCount, peak: peak)
    }
}

/// Debug-build measurement of what ReplayKit delivers on the microphone channel.
///
/// One line per buffer says when it arrived and whether every sample was exactly zero. A once-a-second
/// tick runs off its own timer, so a stretch with no microphone buffers reads as ticks with `mic=0`
/// rather than as a gap that could equally mean this process stopped. A build that can't emit these
/// lines is not a build that can answer the question: read `lifecycle event=started` before trusting it.
nonisolated final class ScreencastMicProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.solstone.swift.broadcast.mic-probe")
    private var timer: DispatchSourceTimer?
    private var sequence = 0
    private var lastMicArrival: TimeInterval?
    private var micSinceTick = 0
    private var micZeroSinceTick = 0
    private var micUnreadableSinceTick = 0
    private var appSinceTick = 0
    private var videoSinceTick = 0

    func broadcastStarted() {
        self.queue.async {
            let info = Bundle.main.infoDictionary
            let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = info?["CFBundleVersion"] as? String ?? "unknown"
            screencastMicProbeLog.notice("mic-probe lifecycle event=started version=\(version, privacy: .public) build=\(build, privacy: .public)")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func lifecycle(_ event: String) {
        self.queue.async {
            screencastMicProbeLog.notice("mic-probe lifecycle event=\(event, privacy: .public)")
        }
    }

    func broadcastFinished() {
        self.queue.sync {
            self.timer?.cancel()
            self.timer = nil
            self.tick()
            screencastMicProbeLog.notice("mic-probe lifecycle event=finished")
        }
    }

    func record(_ sampleBuffer: CMSampleBuffer, kind: MobileSegmentScreencastSampleKind) {
        let arrival = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        self.queue.async {
            switch kind {
            case .audioMic:
                self.recordMic(sampleBuffer, arrival: arrival)
            case .audioApp:
                self.appSinceTick += 1
            case .video:
                self.videoSinceTick += 1
            case .unknown:
                return
            }
        }
    }

    private func recordMic(_ sampleBuffer: CMSampleBuffer, arrival: TimeInterval) {
        self.sequence += 1
        self.micSinceTick += 1
        let gapMs = self.lastMicArrival.map { (arrival - $0) * 1000 } ?? 0
        self.lastMicArrival = arrival
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        guard let reading = ScreencastMicBufferReading.read(sampleBuffer) else {
            self.micUnreadableSinceTick += 1
            screencastMicProbeLog.notice("mic-probe buffer seq=\(self.sequence, privacy: .public) arrival=\(arrival, format: .fixed(precision: 3), privacy: .public) gap_ms=\(gapMs, format: .fixed(precision: 1), privacy: .public) unreadable")
            return
        }
        if reading.isExactZero {
            self.micZeroSinceTick += 1
        }
        let peak = reading.peak.map { String(format: "%.6f", $0) } ?? "n/a"
        screencastMicProbeLog.notice("mic-probe buffer seq=\(self.sequence, privacy: .public) arrival=\(arrival, format: .fixed(precision: 3), privacy: .public) pts=\(pts, format: .fixed(precision: 3), privacy: .public) gap_ms=\(gapMs, format: .fixed(precision: 1), privacy: .public) samples=\(reading.sampleCount, privacy: .public) nonzero=\(reading.nonZeroCount, privacy: .public) exact_zero=\(reading.isExactZero, privacy: .public) peak=\(peak, privacy: .public)")
    }

    private func tick() {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let age = self.lastMicArrival.map { String(format: "%.3f", now - $0) } ?? "never"
        screencastMicProbeLog.notice("mic-probe tick uptime=\(now, format: .fixed(precision: 3), privacy: .public) mic=\(self.micSinceTick, privacy: .public) mic_zero=\(self.micZeroSinceTick, privacy: .public) mic_unreadable=\(self.micUnreadableSinceTick, privacy: .public) app=\(self.appSinceTick, privacy: .public) video=\(self.videoSinceTick, privacy: .public) last_mic_age_s=\(age, privacy: .public)")
        self.micSinceTick = 0
        self.micZeroSinceTick = 0
        self.micUnreadableSinceTick = 0
        self.appSinceTick = 0
        self.videoSinceTick = 0
    }
}
#endif
