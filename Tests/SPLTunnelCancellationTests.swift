// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import Network
import os
@testable import SPLTunnel
import XCTest

nonisolated final class SPLTunnelCancellationTests: XCTestCase {
    func testAcceptorCancelResolvesSuspendedWaiter() async {
        let acceptor = OneShotConnectionAcceptor()
        let outcome = OSAllocatedUnfairLock(initialState: WaitOutcome?.none)
        let started = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            started.withLock { $0 = true }
            do {
                _ = try await withTaskCancellationHandler {
                    try await acceptor.wait()
                } onCancel: {
                    acceptor.cancel()
                }
                outcome.withLock { $0 = .returned }
            } catch InnerTLSError.closed {
                outcome.withLock { $0 = .closed }
            } catch {
                outcome.withLock { $0 = .other }
            }
        }

        let didStart = await Self.waitUntil { started.withLock { $0 } }
        XCTAssertTrue(didStart)
        task.cancel()

        let didFinish = await Self.waitUntil { outcome.withLock { $0 != nil } }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(outcome.withLock { $0 }, .closed)
    }

    func testAcceptorCompleteAfterCancelCancelsLateConnection() async throws {
        let pair = try await Self.makeConnectionPair()
        defer {
            pair.client.cancel()
            pair.server.cancel()
            pair.listener.cancel()
        }

        let acceptor = OneShotConnectionAcceptor()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        pair.server.stateUpdateHandler = { state in
            if case .cancelled = state {
                cancelled.withLock { $0 = true }
            }
        }

        acceptor.cancel()
        acceptor.complete(pair.server)

        let didCancel = await Self.waitUntil { cancelled.withLock { $0 } }
        XCTAssertTrue(didCancel)
    }

    func testAcceptorCancelAfterCompleteCancelsStoredConnection() async throws {
        let pair = try await Self.makeConnectionPair()
        defer {
            pair.client.cancel()
            pair.server.cancel()
            pair.listener.cancel()
        }

        let acceptor = OneShotConnectionAcceptor()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        pair.server.stateUpdateHandler = { state in
            if case .cancelled = state {
                cancelled.withLock { $0 = true }
            }
        }

        acceptor.complete(pair.server)
        acceptor.cancel()

        let didCancel = await Self.waitUntil { cancelled.withLock { $0 } }
        XCTAssertTrue(didCancel)
    }

    func testConnectionReadyWaiterResolvesWhenConnectionIsCancelled() async {
        let port = NWEndpoint.Port(rawValue: 65_000)!
        let connection = NWConnection(host: "198.51.100.1", port: port, using: .tcp)
        let waiter = startAndReturnReadyWaiter(connection)
        let outcome = OSAllocatedUnfairLock(initialState: WaitOutcome?.none)
        let started = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            started.withLock { $0 = true }
            do {
                try await withTaskCancellationHandler {
                    try await waiter.wait()
                } onCancel: {
                    connection.cancel()
                }
                outcome.withLock { $0 = .returned }
            } catch InnerTLSError.closed {
                outcome.withLock { $0 = .closed }
            } catch {
                outcome.withLock { $0 = .other }
            }
        }

        let didStart = await Self.waitUntil { started.withLock { $0 } }
        XCTAssertTrue(didStart)
        task.cancel()

        let didFinish = await Self.waitUntil { outcome.withLock { $0 != nil } }
        XCTAssertTrue(didFinish)
        XCTAssertEqual(outcome.withLock { $0 }, .closed)
    }

    func testLoopbackReceiveCancelCancelsConnectionAndResolves() async throws {
        let pair = try await Self.makeConnectionPair()
        defer {
            pair.client.cancel()
            pair.server.cancel()
            pair.listener.cancel()
        }

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        pair.server.stateUpdateHandler = { state in
            if case .cancelled = state {
                cancelled.withLock { $0 = true }
            }
        }
        let outcome = OSAllocatedUnfairLock(initialState: WaitOutcome?.none)
        let started = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            started.withLock { $0 = true }
            do {
                _ = try await LoopbackProxy.receive(from: pair.server)
                outcome.withLock { $0 = .returned }
            } catch {
                outcome.withLock { $0 = .other }
            }
        }

        let didStart = await Self.waitUntil { started.withLock { $0 } }
        XCTAssertTrue(didStart)
        task.cancel()

        let didFinish = await Self.waitUntil { outcome.withLock { $0 != nil } }
        XCTAssertTrue(didFinish)
        XCTAssertNotNil(outcome.withLock { $0 })
        let didCancel = await Self.waitUntil { cancelled.withLock { $0 } }
        XCTAssertTrue(didCancel)
    }

    func testLoopbackSendCancelResolvesPendingSend() async throws {
        let pair = try await Self.makeConnectionPair()
        defer {
            pair.client.cancel()
            pair.server.cancel()
            pair.listener.cancel()
        }

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        pair.client.stateUpdateHandler = { state in
            if case .cancelled = state {
                cancelled.withLock { $0 = true }
            }
        }
        let outcome = OSAllocatedUnfairLock(initialState: WaitOutcome?.none)
        let started = OSAllocatedUnfairLock(initialState: false)
        let payload = Data(repeating: 0x41, count: 64 * 1024 * 1024)
        let task = Task {
            started.withLock { $0 = true }
            do {
                try await LoopbackProxy.send(payload, to: pair.client)
                outcome.withLock { $0 = .returned }
            } catch {
                outcome.withLock { $0 = .other }
            }
        }

        let didStart = await Self.waitUntil { started.withLock { $0 } }
        XCTAssertTrue(didStart)
        task.cancel()

        let didFinish = await Self.waitUntil { outcome.withLock { $0 != nil } }
        XCTAssertTrue(didFinish)
        XCTAssertNotNil(outcome.withLock { $0 })
        let didCancel = await Self.waitUntil { cancelled.withLock { $0 } }
        XCTAssertTrue(didCancel)
    }

    func testInboundCloseAfterLocalCloseRemovesTerminalStream() async throws {
        let mux = Multiplexer(sink: { _ in }, role: .listener)
        let streamTask = Task {
            var iterator = mux.incomingStreams.makeAsyncIterator()
            return await iterator.next()
        }

        try await mux.feedInbound(try encodeFrame(buildOpen(streamID: 1)))
        let maybeStream = await streamTask.value
        let stream = try XCTUnwrap(maybeStream)
        var streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamCount, 1)

        try await stream.close()
        var streamState = await stream.state
        streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamState, .halfClosedLocal)
        XCTAssertEqual(streamCount, 1)

        try await mux.feedInbound(try encodeFrame(buildClose(streamID: 1)))
        streamState = await stream.state
        streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamState, .closed)
        XCTAssertEqual(streamCount, 0)
    }

    func testInboundCloseOnOpenStreamHalfClosesWithoutRemoving() async throws {
        let mux = Multiplexer(sink: { _ in }, role: .listener)
        let streamTask = Task {
            var iterator = mux.incomingStreams.makeAsyncIterator()
            return await iterator.next()
        }

        try await mux.feedInbound(try encodeFrame(buildOpen(streamID: 1)))
        let maybeStream = await streamTask.value
        let stream = try XCTUnwrap(maybeStream)

        try await mux.feedInbound(try encodeFrame(buildClose(streamID: 1)))

        let streamState = await stream.state
        let streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamState, .halfClosedRemote)
        XCTAssertEqual(streamCount, 1)
    }

    func testLocalResetRemovesTerminalStream() async throws {
        let mux = Multiplexer(sink: { _ in }, role: .dialer)
        let stream = try await mux.openStream()
        var streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamCount, 1)

        await stream.reset(reason: .normal)

        let streamState = await stream.state
        streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamState, .resetLocal)
        XCTAssertEqual(streamCount, 0)
    }

    func testManyShortTerminalStreamsDoNotAccumulate() async throws {
        let mux = Multiplexer(sink: { _ in }, role: .dialer)

        for _ in 0..<(MuxConstants.maxConcurrentStreams + 16) {
            let stream = try await mux.openStream()
            await stream.reset(reason: .normal)
            let streamCount = await mux.streamCountForTesting()
            XCTAssertEqual(streamCount, 0)
        }
    }

    func testTearDownStillClearsStreams() async throws {
        let mux = Multiplexer(sink: { _ in }, role: .dialer)
        _ = try await mux.openStream()
        _ = try await mux.openStream()
        var streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamCount, 2)

        await mux.tearDown(reason: .normalShutdown)

        streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamCount, 0)
    }

    func testActiveStreamLimitStillCountsActiveStreamsOnly() async throws {
        let mux = Multiplexer(sink: { _ in }, role: .dialer)
        var streams: [MuxStream] = []
        for _ in 0..<MuxConstants.maxConcurrentStreams {
            streams.append(try await mux.openStream())
        }

        do {
            _ = try await mux.openStream()
            XCTFail("expected stream limit")
        } catch MuxError.streamLimitExceeded {
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        await streams[0].reset(reason: .normal)
        _ = try await mux.openStream()
        let streamCount = await mux.streamCountForTesting()
        XCTAssertEqual(streamCount, MuxConstants.maxConcurrentStreams)
    }

    private static func makeConnectionPair() async throws -> ConnectionPair {
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = LoopbackListenerReady()
        let acceptor = OneShotConnectionAcceptor()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    ready.complete(.success(port))
                }
            case .failed(let error):
                ready.complete(.failure(error))
            case .cancelled, .setup, .waiting:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { connection in
            acceptor.complete(connection)
        }
        listener.start(queue: .global(qos: .utility))

        let port = try await ready.wait()
        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let clientWaiter = startAndReturnReadyWaiter(client)
        let server = try await acceptor.wait()
        let serverWaiter = startAndReturnReadyWaiter(server)
        try await clientWaiter.wait()
        try await serverWaiter.wait()
        return ConnectionPair(listener: listener, client: client, server: server)
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

private enum WaitOutcome: Sendable, Equatable {
    case returned
    case closed
    case other
}

private struct ConnectionPair: @unchecked Sendable {
    let listener: NWListener
    let client: NWConnection
    let server: NWConnection
}

private final class LoopbackListenerReady: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<NWEndpoint.Port, Error>?
    private var result: Result<NWEndpoint.Port, Error>?

    func wait() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, Error>) in
            let result: Result<NWEndpoint.Port, Error>? = lock.withLock {
                if let result = self.result {
                    return result
                }
                self.continuation = continuation
                return nil
            }

            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func complete(_ result: Result<NWEndpoint.Port, Error>) {
        let continuation = lock.withLock {
            guard self.result == nil else {
                return nil as CheckedContinuation<NWEndpoint.Port, Error>?
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}
