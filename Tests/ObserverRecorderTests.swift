// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
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

    @MainActor
    func testEnsureActiveRecordSessionActivatesFromColdCategory() throws {
        let spy = SpyAudioSession(category: .soloAmbient)

        let didActivate = try ObserverAudioActivator.ensureActiveRecordSession(spy)

        XCTAssertTrue(didActivate)
        XCTAssertEqual(spy.setCategoryCalls, [.record])
        XCTAssertEqual(spy.setActiveCalls, [true])
    }

    @MainActor
    func testEnsureActiveRecordSessionReusesActiveVoiceSession() throws {
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
