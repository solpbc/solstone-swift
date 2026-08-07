// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

@MainActor
final class WatchAudioRecorderTerminalForwarderTests: XCTestCase {
    func testForwarderFinishPreservesBoundSource() async {
        let expectation = self.expectation(description: "finish forwarded")
        let sink = ForwarderSink(expectation: expectation)
        let source = WatchCaptureSourceToken(sessionID: "finish-session")
        let forwarder = WatchAudioRecorderTerminalForwarder(source: source, sink: sink)

        forwarder.deliverDidFinish(successfully: false)
        await self.fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(sink.finishEvents.count, 1)
        XCTAssertEqual(sink.finishEvents.first?.successfully, false)
        XCTAssertEqual(sink.finishEvents.first?.source, source)
    }

    func testForwarderEncodeErrorPreservesBoundSource() async {
        let expectation = self.expectation(description: "encode error forwarded")
        let sink = ForwarderSink(expectation: expectation)
        let source = WatchCaptureSourceToken(sessionID: "encode-session")
        let forwarder = WatchAudioRecorderTerminalForwarder(source: source, sink: sink)

        forwarder.deliverEncodeError(nil)
        await self.fulfillment(of: [expectation], timeout: 1)

        XCTAssertEqual(sink.encodeSources, [source])
    }
}

@MainActor
private final class ForwarderSink: WatchAudioRecorderEventSink {
    private let expectation: XCTestExpectation
    var finishEvents: [(successfully: Bool, source: WatchCaptureSourceToken)] = []
    var encodeSources: [WatchCaptureSourceToken] = []

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    func audioRecorderDidFinish(successfully: Bool, source: WatchCaptureSourceToken) {
        self.finishEvents.append((successfully, source))
        self.expectation.fulfill()
    }

    func audioRecorderEncodeError(_ error: (any Error)?, source: WatchCaptureSourceToken) {
        self.encodeSources.append(source)
        self.expectation.fulfill()
    }
}
