// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import AVFoundation
import XCTest

@MainActor
final class WatchAudioRecorderTerminalRetentionTests: XCTestCase {
    func testDelayedFinishReleasesPairAndPreservesBoundSource() async throws {
        let clock = MockObserverClock()
        let expectation = self.expectation(description: "finish forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "A")
        let pair = try self.retirePair(retention: retention, sink: sink, source: source)

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        XCTAssertNotNil(pair.recorder)
        XCTAssertNotNil(pair.forwarder)

        pair.finish(successfully: false)
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })

        XCTAssertEqual(sink.finishEvents.count, 1)
        XCTAssertEqual(sink.finishEvents.first?.0, false)
        XCTAssertEqual(sink.finishEvents.first?.1, source)
    }

    func testDelayedEncodeErrorReleasesPairAndPreservesBoundSource() async throws {
        let clock = MockObserverClock()
        let expectation = self.expectation(description: "encode forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "A")
        let pair = try self.retirePair(retention: retention, sink: sink, source: source)

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        pair.encodeError()
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })

        XCTAssertEqual(sink.encodeSources, [source])
    }

    func testSuccessfulFinishStillReleasesPair() async throws {
        let clock = MockObserverClock()
        let expectation = self.expectation(description: "successful finish forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let pair = try self.retirePair(
            retention: retention,
            sink: sink,
            source: WatchCaptureSourceToken(sessionID: "A")
        )

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        pair.finish(successfully: true)
        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { pair.recorder == nil && pair.forwarder == nil })

        XCTAssertEqual(sink.finishEvents.first?.0, true)
    }

    func testExpiryRetainsUntilFiveSecondsThenReleasesBothPairs() async throws {
        let clock = MockObserverClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let first = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))
        let second = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "B"))

        await self.drain(until: { clock.pendingSleeperCount == 2 })
        clock.advance(by: 4.999)
        await self.settle()
        XCTAssertNotNil(first.recorder)
        XCTAssertNotNil(first.forwarder)
        XCTAssertNotNil(second.recorder)
        XCTAssertNotNil(second.forwarder)

        clock.advance(by: 0.001)
        await self.drain(until: {
            first.recorder == nil && first.forwarder == nil && second.recorder == nil && second.forwarder == nil
        })
    }

    func testThirdRetirementEvictsOldestPair() async throws {
        let clock = MockObserverClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let first = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "A"))
        let second = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "B"))
        let third = try self.retirePair(retention: retention, sink: nil, source: WatchCaptureSourceToken(sessionID: "C"))

        await self.drain(until: { first.recorder == nil && first.forwarder == nil })
        XCTAssertNotNil(second.recorder)
        XCTAssertNotNil(second.forwarder)
        XCTAssertNotNil(third.recorder)
        XCTAssertNotNil(third.forwarder)
    }

    func testEnrollOverCurrentRetiresIncumbentAndKeepsNewPairCurrent() async throws {
        let clock = MockObserverClock()
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let incumbent = RetiredPairFixture()
        let current = RetiredPairFixture()

        try autoreleasepool {
            let recorder = try self.makeRecorder()
            incumbent.recorder = recorder
            retention.enroll(recorder: recorder, source: WatchCaptureSourceToken(sessionID: "A"), sink: nil)
            incumbent.forwarder = recorder.delegate as? WatchAudioRecorderTerminalForwarder

            let replacement = try self.makeRecorder()
            current.recorder = replacement
            retention.enroll(recorder: replacement, source: WatchCaptureSourceToken(sessionID: "B"), sink: nil)
            current.forwarder = replacement.delegate as? WatchAudioRecorderTerminalForwarder
        }

        await self.drain(until: { clock.pendingSleeperCount == 1 })

        XCTAssertNotNil(incumbent.recorder)
        XCTAssertNotNil(incumbent.forwarder)
        XCTAssertNotNil(current.recorder)
        XCTAssertNotNil(current.forwarder)
        XCTAssertEqual(retention.currentURL(), current.recorder?.url)
    }

    func testCallbackBeforeExpiryForwardsAfterExpiryAdvance() async throws {
        let clock = MockObserverClock()
        let expectation = self.expectation(description: "finish forwarded after clock advance")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let source = WatchCaptureSourceToken(sessionID: "A")
        let pair = try self.retirePair(retention: retention, sink: sink, source: source)

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        pair.finish(successfully: false)
        clock.advance(by: 5)
        await self.fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(sink.finishEvents.count, 1)
        XCTAssertEqual(sink.finishEvents.first?.0, false)
        XCTAssertEqual(sink.finishEvents.first?.1, source)
    }

    func testDuplicateCallbacksReleaseIdempotently() async throws {
        let clock = MockObserverClock()
        let expectation = self.expectation(description: "two finish callbacks forwarded")
        expectation.expectedFulfillmentCount = 2
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let pair = try self.retirePair(retention: retention, sink: sink, source: WatchCaptureSourceToken(sessionID: "A"))

        await self.drain(until: { clock.pendingSleeperCount == 1 })
        // This is deliberately not a lifetime probe: retain the forwarder so the
        // second manually-invoked duplicate callback can enter after the first
        // releases retention's strong pair.
        let recorder = try XCTUnwrap(pair.recorder)
        let forwarder = try XCTUnwrap(pair.forwarder)
        forwarder.audioRecorderDidFinishRecording(recorder, successfully: false)
        forwarder.audioRecorderDidFinishRecording(recorder, successfully: false)
        await self.fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(sink.finishEvents.count, 2)
    }

    func testSynchronousFinishDuringStopReleasesRetiredPair() async throws {
        let clock = MockObserverClock()
        let expectation = self.expectation(description: "synchronous finish forwarded")
        let sink = RetentionSink(expectation: expectation)
        let retention = WatchAudioRecorderTerminalRetention(clock: clock)
        let fixture = RetiredPairFixture()

        try autoreleasepool {
            let recorder = try SynchronousFinishAudioRecorder(
                url: self.makeRecorderURL,
                settings: self.recorderSettings
            )
            fixture.recorder = recorder
            retention.enroll(
                recorder: recorder,
                source: WatchCaptureSourceToken(sessionID: "A"),
                sink: sink
            )
            fixture.forwarder = recorder.delegate as? WatchAudioRecorderTerminalForwarder
            _ = retention.stopCurrent()
        }

        await self.fulfillment(of: [expectation], timeout: 1)
        await self.drain(until: { fixture.recorder == nil && fixture.forwarder == nil })
        XCTAssertEqual(sink.finishEvents.count, 1)
    }

    private func retirePair(
        retention: WatchAudioRecorderTerminalRetention,
        sink: RetentionSink?,
        source: WatchCaptureSourceToken
    ) throws -> RetiredPairFixture {
        let fixture = RetiredPairFixture()
        try autoreleasepool {
            let recorder = try self.makeRecorder()
            fixture.recorder = recorder
            retention.enroll(recorder: recorder, source: source, sink: sink)
            fixture.forwarder = recorder.delegate as? WatchAudioRecorderTerminalForwarder
            XCTAssertNotNil(fixture.forwarder)
            _ = retention.stopCurrent()
        }
        return fixture
    }

    private func makeRecorder() throws -> AVAudioRecorder {
        try AVAudioRecorder(url: self.makeRecorderURL, settings: self.recorderSettings)
    }

    private var makeRecorderURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchAudioRecorderTerminalRetentionTests-\(UUID().uuidString).m4a")
    }

    private var recorderSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
    }

    private func drain(until predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for test convergence")
    }

    private func settle() async {
        for _ in 0..<200 {
            await Task.yield()
        }
    }
}

@MainActor
private final class RetentionSink: WatchAudioRecorderEventSink {
    private let expectation: XCTestExpectation?
    var finishEvents: [(Bool, WatchCaptureSourceToken)] = []
    var encodeSources: [WatchCaptureSourceToken] = []

    init(expectation: XCTestExpectation?) {
        self.expectation = expectation
    }

    func audioRecorderDidFinish(successfully: Bool, source: WatchCaptureSourceToken) {
        self.finishEvents.append((successfully, source))
        self.expectation?.fulfill()
    }

    func audioRecorderEncodeError(_ error: (any Error)?, source: WatchCaptureSourceToken) {
        self.encodeSources.append(source)
        self.expectation?.fulfill()
    }
}

@MainActor
private final class RetiredPairFixture {
    weak var recorder: AVAudioRecorder?
    weak var forwarder: WatchAudioRecorderTerminalForwarder?

    func finish(successfully: Bool) {
        guard let recorder, let forwarder else { return }
        forwarder.audioRecorderDidFinishRecording(recorder, successfully: successfully)
    }

    func encodeError() {
        guard let recorder, let forwarder else { return }
        forwarder.audioRecorderEncodeErrorDidOccur(recorder, error: nil)
    }
}

@MainActor
private final class SynchronousFinishAudioRecorder: AVAudioRecorder {
    override func stop() {
        self.delegate?.audioRecorderDidFinishRecording?(self, successfully: false)
    }
}
