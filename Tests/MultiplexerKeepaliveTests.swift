// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@testable import SPLTunnel
import XCTest

nonisolated final class MultiplexerKeepaliveTests: XCTestCase {
    func testBusyTicksStaySilentAndDoNotEmitKeepaliveLost() async throws {
        let (mux, captured) = makeMux()
        let lossProbe = KeepaliveLossProbe(stream: mux.keepaliveLost)
        defer { lossProbe.cancel() }

        let t0 = ContinuousClock.now
        for index in 1...6 {
            let now = t0 + .milliseconds(Int64(index * 500))
            await mux.setLastInboundActivityForTesting(t0 + .milliseconds(Int64(index * 500 - 100)))
            try await mux.performKeepaliveTickForTesting(now: now, idleThreshold: .seconds(2), missedLimit: 3)
        }

        XCTAssertEqual(try pingFrames(in: captured).count, 0)
        let observedLoss = await lossProbe.observed()
        XCTAssertFalse(observedLoss)
    }

    func testIdleTicksEscalateAfterBudget() async throws {
        let (mux, captured) = makeMux()
        let lossProbe = KeepaliveLossProbe(stream: mux.keepaliveLost)
        defer { lossProbe.cancel() }

        let t0 = ContinuousClock.now
        await mux.setLastInboundActivityForTesting(t0)

        try await tick(mux, at: t0, milliseconds: 500)
        try await tick(mux, at: t0, milliseconds: 1_000)
        try await tick(mux, at: t0, milliseconds: 1_500)
        XCTAssertEqual(try pingFrames(in: captured).count, 0)
        let observedLossAfterBusyTicks = await lossProbe.observed()
        XCTAssertFalse(observedLossAfterBusyTicks)

        try await tick(mux, at: t0, milliseconds: 2_000)
        XCTAssertEqual(try pingFrames(in: captured).count, 1)
        try await tick(mux, at: t0, milliseconds: 2_500)
        XCTAssertEqual(try pingFrames(in: captured).count, 2)
        try await tick(mux, at: t0, milliseconds: 3_000)
        XCTAssertEqual(try pingFrames(in: captured).count, 3)
        let observedLossBeforeLimit = await lossProbe.observed()
        XCTAssertFalse(observedLossBeforeLimit)

        try await tick(mux, at: t0, milliseconds: 3_500)
        XCTAssertEqual(try pingFrames(in: captured).count, 3)
        let observedLossAtLimit = await lossProbe.observed(timeout: .seconds(1))
        XCTAssertTrue(observedLossAtLimit)
    }

    func testEscalationCountsConsecutiveUnansweredIdleTicks() async throws {
        let (mux, captured) = makeMux()
        let lossProbe = KeepaliveLossProbe(stream: mux.keepaliveLost)
        defer { lossProbe.cancel() }

        let t0 = ContinuousClock.now
        await mux.setLastInboundActivityForTesting(t0)

        try await mux.performKeepaliveTickForTesting(
            now: t0 + .milliseconds(1),
            idleThreshold: .milliseconds(1),
            missedLimit: 3
        )
        try await mux.performKeepaliveTickForTesting(
            now: t0 + .milliseconds(2),
            idleThreshold: .milliseconds(1),
            missedLimit: 3
        )
        try await mux.performKeepaliveTickForTesting(
            now: t0 + .milliseconds(3),
            idleThreshold: .milliseconds(1),
            missedLimit: 3
        )
        XCTAssertEqual(try pingFrames(in: captured).count, 3)
        let observedLossBeforeLimit = await lossProbe.observed()
        XCTAssertFalse(observedLossBeforeLimit)

        try await mux.performKeepaliveTickForTesting(
            now: t0 + .milliseconds(4),
            idleThreshold: .milliseconds(1),
            missedLimit: 3
        )
        XCTAssertEqual(try pingFrames(in: captured).count, 3)
        let observedLossAtLimit = await lossProbe.observed(timeout: .seconds(1))
        XCTAssertTrue(observedLossAtLimit)
    }

    func testPongResetsPendingPingAndMakesNextTickBusy() async throws {
        let (mux, captured) = makeMux()
        let lossProbe = KeepaliveLossProbe(stream: mux.keepaliveLost)
        defer { lossProbe.cancel() }

        let t0 = ContinuousClock.now
        await mux.setLastInboundActivityForTesting(t0)
        try await tick(mux, at: t0, milliseconds: 2_000)

        let firstPing = try XCTUnwrap(try pingFrames(in: captured).first)
        let nonce = try parseControlNonce(from: firstPing.payload)
        try await mux.feedInbound(try encodeFrame(buildPong(nonce: nonce)))
        let pingCountAfterPong = try pingFrames(in: captured).count

        // Feeding the pong uses the real dispatch stamp, so use real now for this BUSY tick.
        try await mux.performKeepaliveTickForTesting(
            now: ContinuousClock.now,
            idleThreshold: .seconds(2),
            missedLimit: 3
        )

        XCTAssertEqual(try pingFrames(in: captured).count, pingCountAfterPong)
        let observedLoss = await lossProbe.observed()
        XCTAssertFalse(observedLoss)
    }

    private func makeMux() -> (mux: Multiplexer, captured: OSAllocatedUnfairLock<[Data]>) {
        let captured = OSAllocatedUnfairLock(initialState: [Data]())
        let mux = Multiplexer(sink: { data in
            captured.withLock {
                $0.append(data)
            }
        })
        return (mux, captured)
    }

    private func tick(_ mux: Multiplexer, at t0: ContinuousClock.Instant, milliseconds: Int64) async throws {
        try await mux.performKeepaliveTickForTesting(
            now: t0 + .milliseconds(milliseconds),
            idleThreshold: .seconds(2),
            missedLimit: 3
        )
    }

    private func pingFrames(in captured: OSAllocatedUnfairLock<[Data]>) throws -> [Frame] {
        try decodedFrames(from: captured.withLock { $0 }).filter { frame in
            frame.flags & FrameFlags.ping.rawValue != 0
        }
    }

    private func decodedFrames(from chunks: [Data]) throws -> [Frame] {
        var decoder = FrameDecoder()
        for chunk in chunks {
            decoder.feed(chunk)
        }

        var frames: [Frame] = []
        while let frame = try decoder.next() {
            frames.append(frame)
        }
        return frames
    }
}

private final class KeepaliveLossProbe: @unchecked Sendable {
    private let didObserve: OSAllocatedUnfairLock<Bool>
    private let task: Task<Void, Never>

    init(stream: AsyncStream<Void>) {
        let didObserve = OSAllocatedUnfairLock(initialState: false)
        self.didObserve = didObserve
        task = Task { [didObserve] in
            var iterator = stream.makeAsyncIterator()
            if await iterator.next() != nil {
                didObserve.withLock {
                    $0 = true
                }
            }
        }
    }

    deinit {
        cancel()
    }

    func cancel() {
        task.cancel()
    }

    func observed(timeout: Duration = .milliseconds(100)) async -> Bool {
        if didObserve.withLock({ $0 }) {
            return true
        }

        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            if didObserve.withLock({ $0 }) {
                return true
            }
        }

        return didObserve.withLock { $0 }
    }
}
