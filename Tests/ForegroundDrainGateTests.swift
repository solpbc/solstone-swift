// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

nonisolated final class ForegroundDrainGateTests: XCTestCase {
    @MainActor
    func testSingleRequestDrivesOnce() async {
        let counters = ForegroundDrainCountersBox()
        let gate = ForegroundDrainGate(drive: {
            counters.driveCount += 1
        })

        await gate.requestDrain()

        XCTAssertEqual(counters.driveCount, 1)
    }

    @MainActor
    func testTriggersDuringFlightCoalesceToOneFollowUp() async {
        let drive = ControlledForegroundDrainDrive()
        let gate = ForegroundDrainGate(drive: {
            await drive.run()
        })

        let first = Task {
            await gate.requestDrain()
        }
        await self.drain(until: {
            drive.driveCount == 1 && drive.pendingReleaseCount == 1
        })

        let second = Task {
            await gate.requestDrain()
        }
        let third = Task {
            await gate.requestDrain()
        }
        await self.yield(times: 20)
        XCTAssertEqual(drive.driveCount, 1)

        drive.releaseNext()
        await self.drain(until: {
            drive.driveCount == 2 && drive.pendingReleaseCount == 1
        })
        XCTAssertEqual(drive.driveCount, 2)

        drive.releaseNext()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(drive.driveCount, 2)
    }

    @MainActor
    func testManyTriggersDuringSameFlightStillOneFollowUp() async {
        let drive = ControlledForegroundDrainDrive()
        let gate = ForegroundDrainGate(drive: {
            await drive.run()
        })

        let first = Task {
            await gate.requestDrain()
        }
        await self.drain(until: {
            drive.driveCount == 1 && drive.pendingReleaseCount == 1
        })

        let followers = (0..<5).map { _ in
            Task {
                await gate.requestDrain()
            }
        }
        await self.yield(times: 20)
        XCTAssertEqual(drive.driveCount, 1)

        drive.releaseNext()
        await self.drain(until: {
            drive.driveCount == 2 && drive.pendingReleaseCount == 1
        })
        XCTAssertEqual(drive.driveCount, 2)

        drive.releaseNext()
        await first.value
        for follower in followers {
            await follower.value
        }

        XCTAssertEqual(drive.driveCount, 2)
    }

    @MainActor
    func testSequentialRequestsDriveIndependently() async {
        let counters = ForegroundDrainCountersBox()
        let gate = ForegroundDrainGate(drive: {
            counters.driveCount += 1
        })

        await gate.requestDrain()
        await gate.requestDrain()

        XCTAssertEqual(counters.driveCount, 2)
    }

    @MainActor
    private func drain(until condition: () -> Bool, maxYields: Int = 10_000) async {
        var yields = 0
        while !condition() && yields < maxYields {
            await Task.yield()
            yields += 1
        }
        if !condition() {
            XCTFail("Timed out waiting for foreground drain condition")
        }
    }

    @MainActor
    private func yield(times: Int) async {
        for _ in 0..<times {
            await Task.yield()
        }
    }
}

@MainActor
private final class ForegroundDrainCountersBox {
    var driveCount = 0
}

@MainActor
private final class ControlledForegroundDrainDrive {
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var driveCount = 0

    var pendingReleaseCount: Int {
        self.releaseContinuations.count
    }

    func run() async {
        self.driveCount += 1
        await withCheckedContinuation { continuation in
            self.releaseContinuations.append(continuation)
        }
    }

    func releaseNext() {
        guard !self.releaseContinuations.isEmpty else {
            XCTFail("No foreground drain pass is waiting to be released")
            return
        }
        self.releaseContinuations.removeFirst().resume()
    }
}
