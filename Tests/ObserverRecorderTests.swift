// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import os
import XCTest

nonisolated final class ObserverRecorderTests: XCTestCase {
    func testValidatedTapFormatRejectsZeroSampleRate() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 0, channels: 1, interleaved: false)

        XCTAssertNil(LiveObserverRecorder.validatedTapFormat(format))
    }

    func testValidatedTapFormatRejectsZeroChannels() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 0, interleaved: false)

        XCTAssertNil(LiveObserverRecorder.validatedTapFormat(format))
    }

    func testValidatedTapFormatAcceptsValidFormat() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)

        let validated = LiveObserverRecorder.validatedTapFormat(format)

        XCTAssertNotNil(validated)
        XCTAssertEqual(validated?.sampleRate, 48_000)
        XCTAssertEqual(validated?.channelCount, 1)
    }

    func testTapWriterAccumulatesDurationOffMainActor() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("chunk.m4a")
        let settings = ObserverRecorderTestSupport.aacSettings()
        let writer = ObserverTapWriter()
        // Hand the file to the box in a nested scope so the box holds the only strong ref;
        // finalizeAndReset then releases it and AVAudioFile flushes to disk.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            _ = writer.swap(to: file, url: url)
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buffer.frameLength = 1600

        // Synchronous, no await — compiles ONLY because write is nonisolated.
        writer.write(buffer)
        writer.write(buffer)

        let chunk = writer.finalizeAndReset()
        XCTAssertNotNil(chunk)
        XCTAssertEqual(chunk?.duration ?? 0, 0.2, accuracy: 0.0001) // 2 * 1600/16000
        XCTAssertEqual(chunk?.url, url)

        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 0)
        let fileSeconds = try ObserverRecorderTestSupport.fileDurationSeconds(url)
        XCTAssertEqual(fileSeconds, 0.2, accuracy: 0.03)
    }

    func testAVAudioFileWriteOf48kBufferInto16kFileStretchesDuration() throws {
        let url = try ObserverRecorderTestSupport.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var phase = 0.0
        let buffer = ObserverRecorderTestSupport.sineBuffer(
            sampleRate: 48_000,
            channels: 1,
            frames: 48_000,
            hertz: 1_000,
            phase: &phase
        )
        do {
            let file = try AVAudioFile(forWriting: url, settings: ObserverRecorderTestSupport.aacSettings())
            try file.write(from: buffer)
        } catch {
            return XCTFail(
                "unconverted 48 kHz write into 16 kHz file threw (\(error)). Stop and report — do not catch and write the source buffer."
            )
        }
        let seconds = try ObserverRecorderTestSupport.fileDurationSeconds(url)
        XCTAssertEqual(seconds, 3.0, accuracy: 0.45, "platform must still produce the 3× lie so the writer fix is the thing that removes it")
        XCTAssertFalse((0.85...1.15).contains(seconds), "unconverted write already yields ~1 s; this AC cannot certify conversion")
    }

    func testTapWriterResamples48kMonoTo16kFileDurationAndPitch() throws {
        let (writer, url) = try ObserverRecorderTestSupport.openWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var phase = 0.0
        writer.write(
            ObserverRecorderTestSupport.sineBuffer(
                sampleRate: 48_000,
                channels: 1,
                frames: 48_000,
                hertz: 1_000,
                phase: &phase
            )
        )
        let chunk = writer.finalizeAndReset()
        XCTAssertEqual(chunk?.duration ?? 0, 1.0, accuracy: 0.001)
        try ObserverRecorderTestSupport.assertConvertedFile(url, wallClock: 1.0, expectedHz: 1_000)
    }

    func testTapWriterResamplesProductionCadence48kTap() throws {
        let (writer, url) = try ObserverRecorderTestSupport.openWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var phase = 0.0
        for _ in 0..<46 {
            writer.write(
                ObserverRecorderTestSupport.sineBuffer(
                    sampleRate: 48_000,
                    channels: 1,
                    frames: 1_024,
                    hertz: 1_000,
                    phase: &phase
                )
            )
        }
        writer.write(
            ObserverRecorderTestSupport.sineBuffer(
                sampleRate: 48_000,
                channels: 1,
                frames: 896,
                hertz: 1_000,
                phase: &phase
            )
        )
        let chunk = writer.finalizeAndReset()
        XCTAssertEqual(chunk?.duration ?? 0, 1.0, accuracy: 0.001)
        try ObserverRecorderTestSupport.assertConvertedFile(url, wallClock: 1.0, expectedHz: 1_000)
    }

    func testTapWriterDownmixes48kStereoTo16kMono() throws {
        let (writer, url) = try ObserverRecorderTestSupport.openWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var phase = 0.0
        writer.write(
            ObserverRecorderTestSupport.sineBuffer(
                sampleRate: 48_000,
                channels: 2,
                frames: 48_000,
                hertz: 1_000,
                phase: &phase
            )
        )
        let chunk = writer.finalizeAndReset()
        XCTAssertEqual(chunk?.duration ?? 0, 1.0, accuracy: 0.001)
        try ObserverRecorderTestSupport.assertConvertedFile(url, wallClock: 1.0, expectedHz: 1_000)
    }

    func testTapWriterDownmixes16kStereoToMono() throws {
        let url = try ObserverRecorderTestSupport.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var phase = 0.0
        let buffer = ObserverRecorderTestSupport.sineBuffer(
            sampleRate: 16_000,
            channels: 2,
            frames: 16_000,
            hertz: 1_000,
            phase: &phase
        )
        do {
            let file = try AVAudioFile(forWriting: url, settings: ObserverRecorderTestSupport.aacSettings())
            try file.write(from: buffer)
        } catch {
            return XCTFail(
                "unconverted 16 kHz stereo write threw (\(error)). Stop and report — do not certify via today's catch."
            )
        }
        do {
            let control = try ObserverRecorderTestSupport.fileDurationSeconds(url)
            if (0.85...1.15).contains(control) {
                return XCTFail(
                    "unconverted 16 kHz stereo write already yields ~1 s (\(control)). Stop and report — this AC cannot certify a downmix."
                )
            }
        } catch {
            return XCTFail(
                "unconverted 16 kHz stereo write threw (\(error)). Stop and report — do not certify via today's catch."
            )
        }

        let (writer, out) = try ObserverRecorderTestSupport.openWriter()
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
        var writePhase = 0.0
        writer.write(
            ObserverRecorderTestSupport.sineBuffer(
                sampleRate: 16_000,
                channels: 2,
                frames: 16_000,
                hertz: 1_000,
                phase: &writePhase
            )
        )
        let chunk = writer.finalizeAndReset()
        XCTAssertEqual(chunk?.duration ?? 0, 1.0, accuracy: 0.001)
        try ObserverRecorderTestSupport.assertConvertedFile(out, wallClock: 1.0, expectedHz: 1_000)
    }

    func testTapWriterHandlesMidChunkRateChange() throws {
        let (writer, url) = try ObserverRecorderTestSupport.openWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var phase48 = 0.0
        var phase8 = 0.0
        writer.write(
            ObserverRecorderTestSupport.sineBuffer(
                sampleRate: 48_000,
                channels: 1,
                frames: 48_000,
                hertz: 1_000,
                phase: &phase48
            )
        )
        writer.write(
            ObserverRecorderTestSupport.sineBuffer(
                sampleRate: 8_000,
                channels: 1,
                frames: 8_000,
                hertz: 400,
                phase: &phase8
            )
        )
        let chunk = writer.finalizeAndReset()
        XCTAssertEqual(chunk?.duration ?? 0, 2.0, accuracy: 0.001)
        let seconds = try ObserverRecorderTestSupport.fileDurationSeconds(url)
        XCTAssertEqual(seconds, 2.0, accuracy: 0.30)
        let samples = try ObserverRecorderTestSupport.decodedSamples(url)
        let first = ObserverRecorderTestSupport.dominantHertz(samples: Array(samples.prefix(samples.count / 2)), sampleRate: 16_000)
        let second = ObserverRecorderTestSupport.dominantHertz(samples: Array(samples.suffix(samples.count / 2)), sampleRate: 16_000)
        XCTAssertEqual(first, 1_000, accuracy: 120)
        XCTAssertEqual(second, 400, accuracy: 80)
    }

    func testTapWriterSkipsBufferWhenConversionFails() throws {
        let url = try ObserverRecorderTestSupport.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var phase = 0.0
        let buffer = ObserverRecorderTestSupport.sineBuffer(
            sampleRate: 48_000,
            channels: 1,
            frames: 48_000,
            hertz: 1_000,
            phase: &phase
        )
        do {
            let control = try AVAudioFile(forWriting: url, settings: ObserverRecorderTestSupport.aacSettings())
            try control.write(from: buffer)
        } catch {
            return XCTFail(
                "control unconverted write threw (\(error)). Stop and report — do not certify fail-closed on a format write already rejects."
            )
        }
        let grown = try ObserverRecorderTestSupport.fileDurationSeconds(url)
        XCTAssertGreaterThan(grown, 1.5)

        let (writer, out) = try ObserverRecorderTestSupport.openWriter()
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }
        writer.convertOverride = { source, _ in
            _ = source
            return nil
        }
        var failPhase = 0.0
        writer.write(
            ObserverRecorderTestSupport.sineBuffer(
                sampleRate: 48_000,
                channels: 1,
                frames: 48_000,
                hertz: 1_000,
                phase: &failPhase
            )
        )
        let chunk = writer.finalizeAndReset()
        XCTAssertEqual(chunk?.duration ?? 0, 0, accuracy: 0.0001)
        if let written = try? AVAudioFile(forReading: out) {
            XCTAssertEqual(written.length, 0)
        }
    }

    @MainActor
    func testEnsureActiveRecordSessionActivatesFromColdCategory() throws {
        let spy = SpyAudioSession(category: .soloAmbient)

        let didActivate = try ObserverAudioActivator.ensureActiveRecordSession(spy)

        XCTAssertTrue(didActivate)
        XCTAssertEqual(spy.setCategoryCalls, [.record])
        XCTAssertEqual(spy.setActiveCalls, [true])
    }

    @MainActor
    func testEnsureActiveRecordSessionReusesActivePlayAndRecordSession() throws {
        let spy = SpyAudioSession(category: .playAndRecord)

        let didActivate = try ObserverAudioActivator.ensureActiveRecordSession(spy)

        XCTAssertFalse(didActivate)
        XCTAssertTrue(spy.setCategoryCalls.isEmpty)
        XCTAssertEqual(spy.setActiveCalls, [true])
    }

    @MainActor
    func testEnsureActiveRecordSessionReusesRecordSession() throws {
        let spy = SpyAudioSession(category: .record)

        let didActivate = try ObserverAudioActivator.ensureActiveRecordSession(spy)

        XCTAssertFalse(didActivate)
        XCTAssertTrue(spy.setCategoryCalls.isEmpty)
        XCTAssertEqual(spy.setActiveCalls, [true])
    }

    @MainActor
    func testStopDoesNotDeactivateSessionItDidNotActivate() async {
        let spy = SpyAudioSession(category: .playAndRecord)
        let recorder = LiveObserverRecorder(session: spy)

        _ = try? await recorder.stop()

        XCTAssertFalse(spy.setActiveCalls.contains(false))
    }

    @MainActor
    func testEngineConfigurationChangeObserverEmitsFault() async {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let recorder = LiveObserverRecorder(
            engine: engine,
            session: SpyAudioSession(category: .record),
            notificationCenter: center
        )
        let faults = OSAllocatedUnfairLock<[ObserverEngineFault]>(initialState: [])
        recorder.onEngineFault = { fault in
            faults.withLock { $0.append(fault) }
        }

        recorder.installEngineFaultObservers()
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        try? await Task.sleep(for: .milliseconds(40))

        let received = faults.withLock { $0 }
        XCTAssertEqual(received.count, 1)
        guard case .configurationChange? = received.first else {
            return XCTFail("Expected configuration-change fault")
        }
    }

    @MainActor
    func testMediaServicesResetObserverEmitsFaultWithoutObjectFilter() async {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let recorder = LiveObserverRecorder(
            engine: engine,
            session: SpyAudioSession(category: .record),
            notificationCenter: center
        )
        let faults = OSAllocatedUnfairLock<[ObserverEngineFault]>(initialState: [])
        recorder.onEngineFault = { fault in
            faults.withLock { $0.append(fault) }
        }

        recorder.installEngineFaultObservers()
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(40))

        let received = faults.withLock { $0 }
        XCTAssertEqual(received.count, 1)
        guard case .mediaServicesReset? = received.first else {
            return XCTFail("Expected media-services-reset fault")
        }
    }
}

@MainActor
private final class SpyAudioSession: ObserverAudioSession {
    var categoryValue: AVAudioSession.Category
    private(set) var setCategoryCalls: [AVAudioSession.Category] = []
    private(set) var setActiveCalls: [Bool] = []

    init(category: AVAudioSession.Category) {
        self.categoryValue = category
    }

    var category: AVAudioSession.Category {
        self.categoryValue
    }

    func setCategory(
        _ category: AVAudioSession.Category,
        mode _: AVAudioSession.Mode,
        options _: AVAudioSession.CategoryOptions
    ) throws {
        self.setCategoryCalls.append(category)
        self.categoryValue = category
    }

    func setActive(_ active: Bool, options _: AVAudioSession.SetActiveOptions) throws {
        self.setActiveCalls.append(active)
    }
}

private enum ObserverRecorderTestSupport {
    static func aacSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    static func makeTempURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chunk.m4a")
    }

    static func openWriter() throws -> (ObserverTapWriter, URL) {
        let url = try makeTempURL()
        let writer = ObserverTapWriter()
        do {
            let file = try AVAudioFile(forWriting: url, settings: aacSettings())
            _ = writer.swap(to: file, url: url)
        }
        return (writer, url)
    }

    static func sineBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        hertz: Double,
        phase: inout Double
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let step = 2.0 * Double.pi * hertz / sampleRate
        for frame in 0..<Int(frames) {
            let sample = Float(sin(phase)) * 0.5
            phase += step
            for channel in 0..<Int(channels) {
                buffer.floatChannelData?[channel][frame] = sample
            }
        }
        return buffer
    }

    static func fileDurationSeconds(_ url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        XCTAssertEqual(rate, 16_000, accuracy: 0.1)
        return Double(file.length) / rate
    }

    static func decodedSamples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let count = Int(buffer.frameLength)
        guard let channel = buffer.floatChannelData?[0], count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: count))
    }

    static func dominantHertz(samples: [Float], sampleRate: Double) -> Double {
        var crossings = 0
        for index in 1..<samples.count {
            if samples[index - 1] <= 0, samples[index] > 0 {
                crossings += 1
            }
        }
        let seconds = Double(samples.count) / sampleRate
        guard seconds > 0 else { return 0 }
        return Double(crossings) / seconds
    }

    static func assertConvertedFile(_ url: URL, wallClock: TimeInterval, expectedHz: Double) throws {
        let seconds = try fileDurationSeconds(url)
        XCTAssertEqual(seconds, wallClock, accuracy: wallClock * 0.15)
        XCTAssertFalse(
            (wallClock * 2.55...wallClock * 3.45).contains(seconds),
            "file duration \(seconds) is the 3× lie, not a resample"
        )
        let samples = try decodedSamples(url)
        let peak = samples.map { abs($0) }.max() ?? 0
        XCTAssertGreaterThan(peak, 0.05, "decoded file is silence")
        let hz = dominantHertz(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(hz, expectedHz, accuracy: 120)
        XCTAssertFalse((250...450).contains(hz), "peak \(hz) Hz is the truncate signature (~333 Hz), not resampled 1 kHz")
    }
}
