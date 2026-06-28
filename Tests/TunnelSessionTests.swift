// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@testable import SPLTunnel
import XCTest

nonisolated final class TunnelSessionTests: XCTestCase {
    func testRelayAwaitingBrokerCanHoldThenConnectAtSessionLayer() async throws {
        let relay = URL(string: "wss://relay.example.com")!
        let fakeTLS = FakeTLS()
        let gate = ConnectorGate()
        let session = TunnelSession(pairing: Self.fixturePairing()) { endpoint, _, onAwaitingBroker in
            switch endpoint {
            case .lan:
                throw SessionError.unreachable
            case .relay:
                await onAwaitingBroker(endpoint.connectedVia)
                try await gate.wait()
                return fakeTLS
            }
        }
        let observedStates = OSAllocatedUnfairLock(initialState: [TunnelState]())
        let stateTask = Task {
            for await state in session.stateUpdates {
                observedStates.withLock { $0.append(state) }
            }
        }
        defer { stateTask.cancel() }

        let connectTask = Task {
            try await session.connect(endpoints: [
                .lan(host: "127.0.0.1", port: 8676, scope: ""),
                .relay(endpoint: relay, instanceID: "instance-123", deviceToken: "device-token")
            ])
        }

        let didAwaitBroker = await Self.waitUntil {
            observedStates.withLock { states in
                states.contains(.awaitingBroker(via: .relay(endpoint: relay)))
            }
        }
        XCTAssertTrue(didAwaitBroker)

        let didFailWhileHeld = await Self.waitUntil({
            observedStates.withLock { states in
                states.contains { state in
                    if case .failed = state { return true }
                    return false
                }
            }
        }, timeout: .milliseconds(200))
        XCTAssertFalse(didFailWhileHeld)

        await gate.resume()
        let via = try await connectTask.value
        XCTAssertEqual(via, .relay(endpoint: relay))

        let didConnect = await Self.waitUntil {
            observedStates.withLock { states in
                states.contains(.connected(via: .relay(endpoint: relay)))
            }
        }
        XCTAssertTrue(didConnect)

        await session.disconnect()
    }

    // NOTE: defaultTLSConnector's concrete RelayWSTransport + InnerTLS path has no cheap fake-relay harness here; the held-wait contract is covered behaviorally by this injected-connector session test plus RaceCoordinatorTests.

    func testPumpEndPublishesTerminalFailureAndDoesNotReconnect() async throws {
        let fakeTLS = FakeTLS()
        let connectCount = OSAllocatedUnfairLock(initialState: 0)
        let session = TunnelSession(pairing: Self.fixturePairing()) { _, _, _ in
            connectCount.withLock { $0 += 1 }
            return fakeTLS
        }
        let observedStates = OSAllocatedUnfairLock(initialState: [TunnelState]())
        let stateTask = Task {
            for await state in session.stateUpdates {
                observedStates.withLock { $0.append(state) }
            }
        }
        defer { stateTask.cancel() }

        let via = try await session.connect(endpoints: [.lan(host: "127.0.0.1", port: 8676, scope: "")])
        XCTAssertEqual(via, .lanDirect(host: "127.0.0.1", port: 8676))
        let didConnect = await Self.waitUntil {
            observedStates.withLock { states in
                states.contains { state in
                    if case .connected = state { return true }
                    return false
                }
            }
        }
        XCTAssertTrue(didConnect)

        fakeTLS.finishInbound()

        let didPublishFailure = await Self.waitUntil {
            observedStates.withLock { states in
                states.contains(.failed(.transportFailed("inbound closed")))
            }
        }
        XCTAssertTrue(didPublishFailure)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(connectCount.withLock { $0 }, 1)

        await session.disconnect()
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

    private static func fixturePairing() -> StoredPairing {
        StoredPairing(
            instanceID: "instance-123",
            homeLabel: "sol",
            relayEndpoint: "wss://relay.example.com",
            fingerprint: "sha256:\(String(repeating: "a", count: 64))",
            clientCertPEM: "cert",
            clientKeyPEM: "key",
            caChainPEM: "ca",
            relayEnrollment: .enrolled(deviceToken: "device-token", expiresAt: nil),
            localEndpoints: [LocalEndpoint(host: "127.0.0.1", port: 8676, scope: "")],
            pairedAt: Date(timeIntervalSince1970: 1_776_144_000)
        )
    }
}

private final class FakeTLS: TunnelTLSIO, @unchecked Sendable {
    nonisolated let inbound: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation

    init() {
        let inbound = AsyncThrowingStream<Data, Error>.makeStream()
        self.inbound = inbound.stream
        self.inboundContinuation = inbound.continuation
    }

    func send(_: Data) async throws {}

    func close() async {
        inboundContinuation.finish()
    }

    func finishInbound() {
        inboundContinuation.finish()
    }
}

private actor ConnectorGate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var isOpen = false

    func wait() async throws {
        if isOpen {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        guard !isOpen else {
            return
        }
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
