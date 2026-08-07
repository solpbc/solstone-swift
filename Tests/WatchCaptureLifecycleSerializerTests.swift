// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

@testable import solstone_swift
import XCTest

private actor WatchCaptureLifecycleSerializerHoldGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isWaitingForResume = false

    func suspend() async {
        self.isWaitingForResume = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        self.isWaitingForResume = false
    }

    func waiting() -> Bool { self.isWaitingForResume }

    func resume() {
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
private final class WatchCaptureLifecycleSerializerSettleObservation {
    var didSettle = false
}

@MainActor
private final class WatchCaptureLifecycleSerializerStub {
    typealias Intent = WatchCaptureLifecycleSerializer.Intent
    typealias AdmissionDecision = WatchCaptureLifecycleSerializer.AdmissionDecision

    var admissions: [Intent] = []
    var calls: [Intent] = []
    var inFlightCount = 0
    var maximumInFlightCount = 0
    var decision: @MainActor @Sendable (Intent) -> AdmissionDecision = { _ in .enqueue }
    var onExecute: (@MainActor @Sendable (Intent) async -> Void)?

    func admit(_ intent: Intent) -> AdmissionDecision {
        self.admissions.append(intent)
        return self.decision(intent)
    }

    func execute(_ intent: Intent) async {
        self.calls.append(intent)
        self.inFlightCount += 1
        self.maximumInFlightCount = max(self.maximumInFlightCount, self.inFlightCount)
        if let onExecute = self.onExecute {
            await onExecute(intent)
        }
        self.inFlightCount -= 1
    }
}

@MainActor
final class WatchCaptureLifecycleSerializerTests: XCTestCase {
    private typealias Intent = WatchCaptureLifecycleSerializer.Intent

    func testIdleStartThenStopRemovesStartAndExecutesStop() async {
        let stub = WatchCaptureLifecycleSerializerStub()
        let serializer = self.makeSerializer(stub)

        serializer.submit(.start)
        serializer.submit(.stop)
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.stop])
    }

    func testFinalStopRemovesLaterStartBehindPendingStop() async {
        let gate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .start {
                await gate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.start)
        await self.waitForGate(gate)
        serializer.submit(.stop)
        serializer.submit(.start)
        serializer.submit(.stop)
        await gate.resume()
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.start, .stop])
    }

    func testStopDropsPendingStartBehindReconcile() async {
        let gate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .reconcile {
                await gate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.reconcile)
        serializer.submit(.start)
        serializer.submit(.stop)
        await self.waitForGate(gate)
        await gate.resume()
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.reconcile, .stop])
    }

    func testDuplicateStartCoalescesWhileExecutorIsSuspended() async {
        let gate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .start {
                await gate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.start)
        await self.waitForGate(gate)
        serializer.submit(.start)
        await gate.resume()
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.start])
        XCTAssertEqual(stub.maximumInFlightCount, 1)
    }

    func testGateActuallySuspendsExecutorUntilResumed() async {
        let gate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { _ in await gate.suspend() }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.start)
        await self.waitForGate(gate)

        let gateIsWaiting = await gate.waiting()
        XCTAssertTrue(gateIsWaiting)
        XCTAssertEqual(stub.inFlightCount, 1)
        await gate.resume()
        await serializer.settled()
    }

    func testQueuedStopIsBarrierForLaterStart() async {
        let gate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .start, stub.calls.count == 1 {
                await gate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.start)
        await self.waitForGate(gate)
        serializer.submit(.stop)
        serializer.submit(.start)
        await gate.resume()
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.start, .stop, .start])
    }

    func testStartWaitsForReconcileExecutorToReturn() async {
        let gate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .reconcile {
                await gate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.reconcile)
        await self.waitForGate(gate)
        serializer.submit(.start)
        XCTAssertEqual(stub.calls, [.reconcile])
        await gate.resume()
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.reconcile, .start])
    }

    func testDuplicateStopAndReconcileCoalesce() async {
        let stub = WatchCaptureLifecycleSerializerStub()
        let serializer = self.makeSerializer(stub)

        serializer.submit(.stop)
        serializer.submit(.stop)
        serializer.submit(.reconcile)
        serializer.submit(.reconcile)
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.stop, .reconcile])
    }

    func testAdmissionRunsWhileCurrentExecutorIsSuspended() async {
        let gate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .start {
                await gate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.start)
        await self.waitForGate(gate)
        serializer.submit(.stop)

        XCTAssertEqual(stub.admissions, [.start, .stop])
        XCTAssertEqual(stub.calls, [.start])
        await gate.resume()
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.start, .stop])
    }

    func testSettledWaitsForInflightExecutorAndEmptyQueue() async {
        let firstGate = WatchCaptureLifecycleSerializerHoldGate()
        let secondGate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .start {
                await firstGate.suspend()
            } else if intent == .rollover {
                await secondGate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)
        let observation = WatchCaptureLifecycleSerializerSettleObservation()
        let didSettle = self.expectation(description: "serializer settled")

        serializer.submit(.start)
        await self.waitForGate(firstGate)
        serializer.submit(.rollover)
        Task { @MainActor in
            await serializer.settled()
            observation.didSettle = true
            didSettle.fulfill()
        }
        await Task.yield()
        XCTAssertFalse(observation.didSettle)
        await firstGate.resume()
        await self.waitForGate(secondGate)
        XCTAssertFalse(observation.didSettle)
        await secondGate.resume()
        await self.fulfillment(of: [didSettle], timeout: 1)
    }

    func testReentrantSubmitEnqueuesWithoutDeadlock() async {
        let stub = WatchCaptureLifecycleSerializerStub()
        let serializer = self.makeSerializer(stub)
        stub.onExecute = { [weak serializer] intent in
            if intent == .start {
                serializer?.submit(.rollover)
            }
        }

        serializer.submit(.start)
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.start, .rollover])
        XCTAssertEqual(stub.maximumInFlightCount, 1)
    }

    func testExecutorCallsNeverOverlap() async {
        let firstGate = WatchCaptureLifecycleSerializerHoldGate()
        let secondGate = WatchCaptureLifecycleSerializerHoldGate()
        let stub = WatchCaptureLifecycleSerializerStub()
        stub.onExecute = { intent in
            if intent == .start {
                await firstGate.suspend()
            } else if intent == .rollover {
                await secondGate.suspend()
            }
        }
        let serializer = self.makeSerializer(stub)

        serializer.submit(.start)
        await self.waitForGate(firstGate)
        serializer.submit(.rollover)
        await firstGate.resume()
        await self.waitForGate(secondGate)
        XCTAssertEqual(stub.maximumInFlightCount, 1)
        await secondGate.resume()
        await serializer.settled()

        XCTAssertEqual(stub.calls, [.start, .rollover])
        XCTAssertEqual(stub.maximumInFlightCount, 1)
    }

    private func makeSerializer(_ stub: WatchCaptureLifecycleSerializerStub) -> WatchCaptureLifecycleSerializer {
        let serializer = WatchCaptureLifecycleSerializer()
        serializer.configure(
            owner: stub,
            admission: { stub, intent in stub.admit(intent) },
            executor: { stub, intent in await stub.execute(intent) }
        )
        return serializer
    }

    private func waitForGate(_ gate: WatchCaptureLifecycleSerializerHoldGate) async {
        for _ in 0 ..< 100 {
            if await gate.waiting() {
                return
            }
            await Task.yield()
        }
        XCTFail("executor did not reach the hold gate")
    }
}
