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
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
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
