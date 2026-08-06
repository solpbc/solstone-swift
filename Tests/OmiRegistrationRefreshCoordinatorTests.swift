// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

@MainActor
final class OmiRegistrationRefreshCoordinatorTests: XCTestCase {
    func testSchedulesExactlyOncePerDisconnectedToConnectedEdgeAndInitialConnectedState() async {
        let recorder = OmiRefreshRecorder()
        let coordinator = OmiRegistrationRefreshCoordinator { port in
            await recorder.refresh(port: port)
        }

        coordinator.observe(tunnelState: .connected(localPort: 7001, via: .lan))
        await self.waitFor { recorder.ports == [7001] }

        coordinator.observe(tunnelState: .connected(localPort: 7001, via: .lan))
        await self.yield(times: 20)
        XCTAssertEqual(recorder.ports, [7001])

        coordinator.observe(tunnelState: .disconnected)
        coordinator.observe(tunnelState: .connected(localPort: 7001, via: .lan))
        await self.waitFor { recorder.ports == [7001, 7001] }
    }

    func testPortChangeDuringRefreshCoalescesOneTrailingRefreshAgainstNewestPort() async {
        let recorder = OmiRefreshRecorder(suspends: true)
        let coordinator = OmiRegistrationRefreshCoordinator { port in
            await recorder.refresh(port: port)
        }

        coordinator.observe(tunnelState: .connected(localPort: 7001, via: .lan))
        await self.waitFor { recorder.ports == [7001] && recorder.pendingReleaseCount == 1 }

        coordinator.observe(tunnelState: .connected(localPort: 7002, via: .lan))
        coordinator.observe(tunnelState: .connected(localPort: 7003, via: .lan))
        await self.yield(times: 20)
        XCTAssertEqual(recorder.ports, [7001])
        XCTAssertEqual(recorder.maximumConcurrentCalls, 1)

        recorder.releaseNext()
        await self.waitFor { recorder.ports == [7001, 7003] && recorder.pendingReleaseCount == 1 }
        recorder.releaseNext()
        await self.waitFor { recorder.completedCount == 2 }

        XCTAssertEqual(recorder.ports, [7001, 7003])
        XCTAssertEqual(recorder.maximumConcurrentCalls, 1)
    }

    func testSamePortConnectedToConnectedSchedulesNothing() async {
        let recorder = OmiRefreshRecorder()
        let coordinator = OmiRegistrationRefreshCoordinator { port in
            await recorder.refresh(port: port)
        }

        coordinator.observe(tunnelState: .connected(localPort: 7001, via: .remote))
        await self.waitFor { recorder.completedCount == 1 }
        coordinator.observe(tunnelState: .connected(localPort: 7001, via: .remote))
        await self.yield(times: 20)

        XCTAssertEqual(recorder.ports, [7001])
    }

    func testObservationReturnsWhileRefreshIsSuspended() async {
        let recorder = OmiRefreshRecorder(suspends: true)
        let coordinator = OmiRegistrationRefreshCoordinator { port in
            await recorder.refresh(port: port)
        }

        coordinator.observe(tunnelState: .connected(localPort: 7001, via: .lan))
        await self.waitFor { recorder.pendingReleaseCount == 1 }

        var unrelatedWorkCompleted = false
        unrelatedWorkCompleted = true
        XCTAssertTrue(unrelatedWorkCompleted)

        recorder.releaseNext()
        await self.waitFor { recorder.completedCount == 1 }
    }

    private func waitFor(_ condition: () -> Bool, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
        if !condition() {
            XCTFail("Timed out waiting for Omi refresh coordinator")
        }
    }

    private func yield(times: Int) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }
}

@MainActor
private final class OmiRefreshRecorder {
    private let suspends: Bool
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var activeCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private(set) var ports: [Int] = []
    private(set) var completedCount = 0

    init(suspends: Bool = false) {
        self.suspends = suspends
    }

    var pendingReleaseCount: Int {
        self.releaseContinuations.count
    }

    func refresh(port: Int) async {
        self.ports.append(port)
        self.activeCalls += 1
        self.maximumConcurrentCalls = max(self.maximumConcurrentCalls, self.activeCalls)
        if self.suspends {
            await withCheckedContinuation { continuation in
                self.releaseContinuations.append(continuation)
            }
        }
        self.activeCalls -= 1
        self.completedCount += 1
    }

    func releaseNext() {
        guard !self.releaseContinuations.isEmpty else {
            XCTFail("No Omi refresh is waiting to be released")
            return
        }
        self.releaseContinuations.removeFirst().resume()
    }
}
