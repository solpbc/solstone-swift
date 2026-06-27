// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Foundation
import os
@testable import SPLTunnel
import XCTest

nonisolated final class TunnelSessionTests: XCTestCase {
    func testPumpEndPublishesTerminalFailureAndDoesNotReconnect() async throws {
        let fakeTLS = FakeTLS()
        let connectCount = OSAllocatedUnfairLock(initialState: 0)
        let session = TunnelSession(pairing: Self.fixturePairing()) { _, _ in
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
            relayEnrollment: .enrolled(deviceToken: "device-token"),
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
