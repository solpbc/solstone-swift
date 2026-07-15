// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@testable import SPLTunnel
import XCTest

nonisolated final class MultiplexerConformanceTests: XCTestCase {
    func testComposedOpenDataDeliversInitialPayloadWithoutWindowGrant() async throws {
        let sink = CapturingMuxSink()
        let mux = Multiplexer(sink: { data in try sink.send(data) }, role: .listener)
        let streamTask = Self.nextIncomingStreamTask(mux)
        let payload = Data(repeating: 0x41, count: MuxConstants.windowGrantThreshold)

        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: 1,
            flags: FrameFlags.open.rawValue | FrameFlags.data.rawValue,
            payload: payload
        )))

        let maybeStream = await streamTask.value
        let stream = try XCTUnwrap(maybeStream)
        let inbound = await stream.inbound
        var iterator = inbound.makeAsyncIterator()
        let firstChunk = try await iterator.next()
        XCTAssertEqual(firstChunk, payload)
        XCTAssertFalse(sink.frames.contains { $0.flags == FrameFlags.window.rawValue })
    }

    func testComposedOpenDataCloseDeliversPayloadThenEOF() async throws {
        let mux = Multiplexer(sink: { _ in }, role: .listener)
        let streamTask = Self.nextIncomingStreamTask(mux)
        let payload = Data("hello".utf8)

        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: 1,
            flags: FrameFlags.open.rawValue | FrameFlags.data.rawValue | FrameFlags.close.rawValue,
            payload: payload
        )))

        let maybeStream = await streamTask.value
        let stream = try XCTUnwrap(maybeStream)
        let inbound = await stream.inbound
        var iterator = inbound.makeAsyncIterator()
        let firstChunk = try await iterator.next()
        let secondChunk = try await iterator.next()
        XCTAssertEqual(firstChunk, payload)
        XCTAssertNil(secondChunk)
        let state = await stream.state
        XCTAssertEqual(state, .halfClosedRemote)
    }

    func testKnownNonzeroPingPongIsolatesTargetStream() async throws {
        let sink = CapturingMuxSink()
        let mux = Multiplexer(sink: { data in try sink.send(data) }, role: .dialer)
        let stream1 = try await mux.openStream()
        let stream3 = try await mux.openStream()
        let nonce = Data(repeating: 0x7a, count: 8)

        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: 1,
            flags: FrameFlags.ping.rawValue,
            payload: nonce
        )))
        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: 3,
            flags: FrameFlags.pong.rawValue,
            payload: nonce
        )))

        XCTAssertTrue(Self.hasReset(in: sink, streamID: 1, reason: .protocolError))
        XCTAssertTrue(Self.hasReset(in: sink, streamID: 3, reason: .protocolError))
        let stream1State = await stream1.state
        let stream3State = await stream3.state
        XCTAssertEqual(stream1State, .resetLocal)
        XCTAssertEqual(stream3State, .resetLocal)
    }

    func testKnownInvalidFlagCombinationIsolatesOnlyTargetStream() async throws {
        let sink = CapturingMuxSink()
        let mux = Multiplexer(sink: { data in try sink.send(data) }, role: .dialer)
        let stream1 = try await mux.openStream()
        let stream3 = try await mux.openStream()

        try await mux.feedInbound(makeRawFrameBytes(streamID: 1, flags: 0x0a))

        XCTAssertTrue(Self.hasReset(in: sink, streamID: 1, reason: .protocolError))
        let stream1State = await stream1.state
        XCTAssertEqual(stream1State, .resetLocal)

        let payload = Data("sibling".utf8)
        try await stream3.write(payload)
        let didWriteSibling = await Self.waitUntil {
            sink.frames.contains {
                $0.streamID == 3 &&
                    $0.flags == FrameFlags.data.rawValue &&
                    $0.payload == payload
            }
        }
        XCTAssertTrue(didWriteSibling)
    }

    func testUnknownNonzeroViolationsEmitSingleProtocolResetWithoutThrowing() async throws {
        let sink = CapturingMuxSink()
        let mux = Multiplexer(sink: { data in try sink.send(data) }, role: .dialer)
        let nonce = Data(repeating: 0x12, count: 8)

        try await mux.feedInbound(try encodeFrame(buildData(streamID: 99, payload: Data("x".utf8))))
        try await mux.feedInbound(try encodeFrame(buildWindow(streamID: 101, credit: 1)))
        try await mux.feedInbound(try encodeFrame(Frame(streamID: 103, flags: FrameFlags.ping.rawValue, payload: nonce)))
        try await mux.feedInbound(try encodeFrame(Frame(streamID: 105, flags: FrameFlags.pong.rawValue, payload: nonce)))
        try await mux.feedInbound(makeRawFrameBytes(streamID: 107, flags: 0x0a))

        for id in [UInt32(99), 101, 103, 105, 107] {
            XCTAssertEqual(Self.resetCount(in: sink, streamID: id, reason: .protocolError), 1, "streamID=\(id)")
        }
    }

    func testUnknownLateCloseAndResetAreSilent() async throws {
        let sink = CapturingMuxSink()
        let mux = Multiplexer(sink: { data in try sink.send(data) }, role: .dialer)

        try await mux.feedInbound(try encodeFrame(buildClose(streamID: 99)))
        try await mux.feedInbound(try encodeFrame(buildReset(streamID: 101, reason: .cancel)))

        XCTAssertTrue(sink.frames.isEmpty)
    }

    func testSendCreditCapAcceptsInt32MaxAndRejectsOverflowWithoutMutation() async {
        let stream = MuxStream(id: 1, sink: { _ in }, onTerminal: { _ in })
        let grantToBoundary = UInt32(Int(Int32.max) - Int(MuxConstants.initialCredit))

        let accepted = await stream.grantSendCredit(grantToBoundary)
        XCTAssertEqual(accepted, .accepted)

        let exceeded = await stream.grantSendCredit(1)
        XCTAssertEqual(exceeded, .flowControlExceeded)

        let zeroAfterRejectedOverflow = await stream.grantSendCredit(0)
        XCTAssertEqual(zeroAfterRejectedOverflow, .accepted)
    }

    func testDuplicateInboundOpenResetsWithoutClobberingLiveStream() async throws {
        let sink = CapturingMuxSink()
        let mux = Multiplexer(sink: { data in try sink.send(data) }, role: .listener)
        let streamTask = Self.nextIncomingStreamTask(mux)

        try await mux.feedInbound(try encodeFrame(buildOpen(streamID: 1)))
        let maybeStream = await streamTask.value
        let stream = try XCTUnwrap(maybeStream)

        try await mux.feedInbound(try encodeFrame(buildOpen(streamID: 1)))
        XCTAssertTrue(Self.hasReset(in: sink, streamID: 1, reason: .protocolError))

        try await mux.feedInbound(try encodeFrame(buildClose(streamID: 1)))
        let streamState = await stream.state
        XCTAssertEqual(streamState, .halfClosedRemote)
    }

    func testInboundOpenInitialPayloadOverWindowResetsBeforeYield() async throws {
        let sink = CapturingMuxSink()
        let mux = Multiplexer(sink: { data in try sink.send(data) }, role: .listener)
        let didYield = OSAllocatedUnfairLock(initialState: false)
        let streamTask = Task {
            var iterator = mux.incomingStreams.makeAsyncIterator()
            if await iterator.next() != nil {
                didYield.withLock {
                    $0 = true
                }
            }
        }
        defer { streamTask.cancel() }

        try await mux.feedInbound(try encodeFrame(Frame(
            streamID: 1,
            flags: FrameFlags.open.rawValue | FrameFlags.data.rawValue,
            payload: Data(repeating: 0x55, count: Int(MuxConstants.initialCredit) + 1)
        )))

        let didReset = await Self.waitUntil {
            Self.hasReset(in: sink, streamID: 1, reason: .flowControlError)
        }
        XCTAssertTrue(didReset)

        let exposedStream = await Self.waitUntil({
            didYield.withLock { $0 }
        }, timeout: .milliseconds(100))
        XCTAssertFalse(exposedStream)
    }

    private static func nextIncomingStreamTask(_ mux: Multiplexer) -> Task<MuxStream?, Never> {
        Task {
            var iterator = mux.incomingStreams.makeAsyncIterator()
            return await iterator.next()
        }
    }

    private static func hasReset(in sink: CapturingMuxSink, streamID: UInt32, reason: ResetReason) -> Bool {
        resetCount(in: sink, streamID: streamID, reason: reason) > 0
    }

    private static func resetCount(in sink: CapturingMuxSink, streamID: UInt32, reason: ResetReason) -> Int {
        sink.frames.filter { frame in
            guard frame.streamID == streamID, frame.flags == FrameFlags.reset.rawValue else {
                return false
            }
            return parseResetReason(from: frame.payload).reason == reason
        }.count
    }

    private static func waitUntil(
        _ condition: () -> Bool,
        timeout: Duration = .seconds(1),
        interval: Duration = .milliseconds(20)
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }
}
