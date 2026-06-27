// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest
import os

nonisolated final class CFTunnelTransportTests: XCTestCase {
    @MainActor
    func testMissingPairingSurfacesCleanErrorAndStage() async {
        let transport = CFTunnelTransport(loadPairing: { nil })
        let stages = OSAllocatedUnfairLock(initialState: [TransportStage]())

        do {
            _ = try await transport.connect(
                candidates: [],
                onDisconnect: { _ in },
                onStageChange: { stage in stages.withLock { $0.append(stage) } }
            )
            XCTFail("expected missing pairing")
        } catch {
            XCTAssertEqual(error as? CFTunnelTransportError, .missingPairing)
        }

        XCTAssertEqual(stages.withLock { $0 }, [.preparingCandidates, .failed("missing pairing")])
    }

    @MainActor
    func testDisconnectClearsConnectionMode() async {
        let transport = CFTunnelTransport(loadPairing: { nil })

        await transport.disconnect()

        XCTAssertNil(transport.connectionMode)
    }

    @MainActor
    func testConnectionModeUpdatesFollowSessionStream() async {
        let transport = CFTunnelTransport(loadPairing: { nil })
        let stream = AsyncStream<ConnectionMode?>.makeStream()

        transport.observeConnectionModeUpdates(stream.stream)
        stream.continuation.yield(.plDirect)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(transport.connectionMode, .plDirect)

        stream.continuation.yield(.plViaSpl)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(transport.connectionMode, .plViaSpl)

        stream.continuation.finish()
        await transport.disconnect()
    }

    @MainActor
    func testFailedSessionStateRoutesToOnDisconnectError() async throws {
        let fakeSession = FakeTunnelSession()
        let transport = CFTunnelTransport(
            loadPairing: { Self.fixturePairing() },
            makeSession: { _ in fakeSession }
        )
        let events = OSAllocatedUnfairLock(initialState: [DisconnectEvent]())

        _ = try await transport.connect(
            candidates: [.lan(host: "127.0.0.1", port: 8676, scope: "")],
            onDisconnect: { error in
                events.withLock { $0.append(DisconnectEvent(error)) }
            },
            onStageChange: { _ in }
        )

        await fakeSession.pushFailed(.transportFailed("pump ended"))

        let didReceiveFailure = await Self.waitUntil {
            events.withLock { $0.contains(.failure(.transportFailed("pump ended"))) }
        }
        XCTAssertTrue(didReceiveFailure)
        await transport.disconnect()
    }

    @MainActor
    func testDisconnectedSessionStateRoutesToCleanOnDisconnect() async throws {
        let fakeSession = FakeTunnelSession()
        let transport = CFTunnelTransport(
            loadPairing: { Self.fixturePairing() },
            makeSession: { _ in fakeSession }
        )
        let events = OSAllocatedUnfairLock(initialState: [DisconnectEvent]())

        _ = try await transport.connect(
            candidates: [.lan(host: "127.0.0.1", port: 8676, scope: "")],
            onDisconnect: { error in
                events.withLock { $0.append(DisconnectEvent(error)) }
            },
            onStageChange: { _ in }
        )

        await fakeSession.pushDisconnected()

        let didReceiveCleanDisconnect = await Self.waitUntil {
            events.withLock { $0.contains(.clean) }
        }
        XCTAssertTrue(didReceiveCleanDisconnect)
        await transport.disconnect()
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

private enum DisconnectEvent: Equatable, Sendable {
    case clean
    case failure(SessionError)
    case other(String)

    init(_ error: Error?) {
        if let sessionError = error as? SessionError {
            self = .failure(sessionError)
        } else if let error {
            self = .other(String(describing: error))
        } else {
            self = .clean
        }
    }
}
