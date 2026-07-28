// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import SPLTunnel
import XCTest

nonisolated final class SolstoneSwiftAppForegroundRevalidationTests: XCTestCase {
    @MainActor
    func testRevalidateThenRequestDrainWaitsForRealProbeBeforeDrainAndSkipsAfterFailure() async {
        TunnelProbeURLProtocol.reset()
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let controller = ForegroundProbeController()
        TunnelProbeURLProtocol.asyncHandler = { request in
            try await controller.handle(request)
        }
        let transport = MockCFTunnelTransport()
        let manager = self.makeManager(transport: transport, probeSession: session)
        manager.forceConnected(port: 8080, via: .lan)
        var drainCount = 0

        let task = Task { @MainActor in
            await SolstoneSwiftApp.revalidateThenRequestDrain(tunnelManager: manager) {
                drainCount += 1
            }
        }
        await controller.waitForStartedCount(1)

        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(drainCount, 0)
        await controller.release(.failure)
        await task.value

        XCTAssertEqual(transport.disconnectCallCount, 1)
        XCTAssertEqual(drainCount, 0)
        manager.cancelReconnect()
        await manager.disconnect()
    }

    @MainActor
    func testRevalidateThenRequestDrainRequestsDrainAfterHealthyProbe() async throws {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = self.makeManager(transport: transport, probeSession: session)
        manager.forceConnected(port: 8080, via: .lan)
        var drainCount = 0

        await SolstoneSwiftApp.revalidateThenRequestDrain(tunnelManager: manager) {
            drainCount += 1
        }

        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 1)
        XCTAssertEqual(transport.disconnectCallCount, 0)
        XCTAssertEqual(drainCount, 1)
        await manager.disconnect()
    }

    @MainActor
    func testRevalidateThenRequestDrainDoesNothingWhenTunnelIsNotConnected() async {
        TunnelProbeURLProtocol.reset()
        TunnelProbeURLProtocol.handler = { request in
            XCTFail("unexpected foreground probe: \(String(describing: request.url))")
            throw URLError(.cancelled)
        }
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let transport = MockCFTunnelTransport()
        let manager = self.makeManager(transport: transport, probeSession: session)
        var drainCount = 0

        await SolstoneSwiftApp.revalidateThenRequestDrain(tunnelManager: manager) {
            drainCount += 1
        }

        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 0)
        XCTAssertEqual(transport.disconnectCallCount, 0)
        XCTAssertEqual(drainCount, 0)
    }

    @MainActor
    func testActiveInactiveActiveWhileProbeInFlightDoesNotDrainStaleEpoch() async {
        TunnelProbeURLProtocol.reset()
        let session = Self.probeSession()
        defer {
            session.invalidateAndCancel()
            TunnelProbeURLProtocol.reset()
        }
        let controller = ForegroundProbeController()
        TunnelProbeURLProtocol.asyncHandler = { request in
            try await controller.handle(request)
        }
        let transport = MockCFTunnelTransport()
        let manager = self.makeManager(transport: transport, probeSession: session)
        manager.forceConnected(port: 8080, via: .lan)
        var drainCount = 0

        let firstActive = Task { @MainActor in
            await SolstoneSwiftApp.revalidateThenRequestDrain(tunnelManager: manager) {
                drainCount += 1
            }
        }
        await controller.waitForStartedCount(1)
        XCTAssertEqual(drainCount, 0)

        let secondActive = Task { @MainActor in
            await SolstoneSwiftApp.revalidateThenRequestDrain(tunnelManager: manager) {
                drainCount += 1
            }
        }
        await controller.waitForStartedCount(2)
        XCTAssertEqual(TunnelProbeURLProtocol.capturedRequests.count, 2)
        XCTAssertEqual(drainCount, 0)

        await controller.release(.failure)
        let didDisconnect = await Self.waitUntil {
            transport.disconnectCallCount == 1
        }
        XCTAssertTrue(didDisconnect)
        await controller.release(.success(statusCode: 200))
        await firstActive.value
        await secondActive.value

        XCTAssertEqual(transport.disconnectCallCount, 1)
        XCTAssertEqual(drainCount, 0)
        manager.cancelReconnect()
        await manager.disconnect()
    }

    @MainActor
    private func makeManager(
        transport: MockCFTunnelTransport,
        probeSession: URLSession
    ) -> TunnelManager {
        TunnelManager(
            transport: transport,
            loadPairing: { nil },
            savePairing: { _ in },
            deletePairing: {},
            probeSession: probeSession,
            probeWatchdogPolicy: ProbeWatchdogPolicy(
                healthyInterval: .seconds(15),
                silentFailureLimit: 2,
                activeInboundFailureLimit: 6
            ),
            random: { _ in 1.0 }
        )
    }

    private static func probeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TunnelProbeURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @MainActor
    private static func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
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

private actor ForegroundProbeController {
    enum Release: Sendable {
        case success(statusCode: Int)
        case failure
    }

    private struct StartedWaiter {
        let target: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var startedCount = 0
    private var startedWaiters: [StartedWaiter] = []
    private var queuedReleases: [Release] = []
    private var releaseWaiters: [CheckedContinuation<Release, Never>] = []

    func handle(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        self.startedCount += 1
        self.resumeStartedWaiters()

        let release = await self.nextRelease()
        switch release {
        case .success(let statusCode):
            return (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                Data("ok".utf8)
            )
        case .failure:
            throw URLError(.timedOut)
        }
    }

    func waitForStartedCount(_ target: Int) async {
        if self.startedCount >= target {
            return
        }
        await withCheckedContinuation { continuation in
            self.startedWaiters.append(StartedWaiter(target: target, continuation: continuation))
        }
    }

    func release(_ release: Release) {
        if !self.releaseWaiters.isEmpty {
            let waiter = self.releaseWaiters.removeFirst()
            waiter.resume(returning: release)
            return
        }
        self.queuedReleases.append(release)
    }

    private func nextRelease() async -> Release {
        if !self.queuedReleases.isEmpty {
            return self.queuedReleases.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    private func resumeStartedWaiters() {
        var remaining: [StartedWaiter] = []
        for waiter in self.startedWaiters {
            if self.startedCount >= waiter.target {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        self.startedWaiters = remaining
    }
}
